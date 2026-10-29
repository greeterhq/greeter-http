# Proposal

## Why

`greeter-http` currently exposes nothing: the `greeter-core` domain exists but is
not reachable over HTTP, and there is no record of how often each guest has been
greeted. We want to serve the core use case on AWS Lambda + API Gateway and keep a
per-guest greeting count in DynamoDB, with safe behavior under the at-least-once
delivery that Lambda/API Gateway imply (retries must not double-count).

## What Changes

- Add an HTTP endpoint `POST /greetings` that greets a guest and returns a running
  per-guest greeting count.
- Compose the installed `greeter-core` use case (`GreetingService#greet`) with a new
  local `GreetingCounter` port; never modify, subclass, or reopen the core gem.
- Persist a per-guest counter in DynamoDB and increment it atomically.
- Require a client-supplied `Idempotency-Key` header and make the endpoint
  idempotent: a replayed key returns the original result (hybrid replay-with-
  fingerprint); the same key with a different request body is rejected.
- Deduplicate across all idempotency keys for a configurable TTL window (default 24h)
  using per-key dedupe items with DynamoDB TTL.
- Deliver the service as a thin AWS Lambda handler adapter over a Rack application,
  with `app.rb` as the single composition root.
- Provision infrastructure as AWS SAM (`infra/template.yaml`): a Ruby 3.3 Lambda
  behind an HTTP API route (`POST /greetings`) with route-level throttling; a
  DynamoDB table in on-demand (pay-per-request) mode with point-in-time recovery
  (PITR) and server-side encryption (SSE); a least-privilege IAM policy limited to
  reading and conditionally writing that one table; X-Ray tracing; 14-day CloudWatch
  log retention; and CloudWatch alarms on 5xx rate and p95 latency.
- Encrypt at rest with one customer-managed KMS key (CMK) covering the Lambda
  environment variables, both log groups, and the paging SNS topic; the key policy
  grants the CloudWatch Logs and CloudWatch service principals the operations they
  need.
- Monitor the live endpoint with a CloudWatch Synthetics canary that runs the same
  liveness + correctness checks as `bin/smoke` on a schedule, plus a paging SNS
  topic fed by three alarms (5xx rate, p95 latency, canary success).
- Deliver continuously via GitHub Actions: CI validates (lint, functional, perf,
  security/IaC, OpenSpec gate) and publishes a versioned SAM build artifact on `v*`
  tags; CD deploys that exact artifact (build-once, deploy-the-same-bytes) to dev,
  then to prod behind a manual-approval gate. Deploy auth is GitHub OIDC assuming a
  dedicated IAM deploy role — no long-lived AWS keys.
- Gate each deploy with a post-deploy smoke check (`bin/smoke`) and a performance
  benchmark (`perf/http_bench.rb`). Smoke and the canary assert liveness +
  correctness only; the latency SLO is owned by the p95 CloudWatch metric alarm and
  the perf benchmark, not by a synthetic serial-sample probe.

## Capabilities

### New Capabilities
- `greeting-counter`: Greet a guest over HTTP, return a per-guest greeting count,
  and guarantee idempotent, non-double-counting behavior under client retries.

### Modified Capabilities
<!-- None. greeter-core is an external dependency and is not modified. -->

## Impact

- **New code** (hexagonal layout in `lib/greeter_http/`):
  - `application/greet_and_count` — composes core + the counter port.
  - `ports/greeting_counter` — abstract port local to this service.
  - `adapters/` — DynamoDB counter adapter, Rack app, Lambda handler, presenter, clock.
  - `app.rb` — composition root wiring all collaborators.
- **Dependencies**: `greeter-core` (compose only), `aws-sdk-dynamodb`, `rack`;
  `rack-test`, `rspec`, `cucumber` for tests. All already present in the Gemfile.
- **AWS / infrastructure** (`infra/template.yaml`, AWS SAM):
  - DynamoDB table (counter items + TTL'd dedupe items), on-demand capacity, PITR,
    SSE, and TTL enabled on the `expires_at` attribute.
  - Ruby 3.3 Lambda function with X-Ray active tracing and a 14-day CloudWatch log
    retention.
  - HTTP API with a single `POST /greetings` route and route-level throttling.
  - IAM execution role scoped to least privilege on that one table: `GetItem` plus
    the transactional conditional write (`TransactWriteItems`) the optimistic-lock
    counter uses — not a blanket table policy.
  - CloudWatch alarms on the HTTP API 5xx rate and p95 latency.
  - A customer-managed KMS CMK (env vars, log groups, SNS topic), a paging SNS
    topic, and a CloudWatch Synthetics canary with its own execution role and a
    30-day-lifecycle artifacts bucket.
  - The canary name and the API access-log group name are **stack-scoped**
    (derived from `AWS::StackName`) so the dev and prod stacks coexist in one
    account/region without colliding on those account-global names.
- **CI/CD** (`.github/workflows/ci.yml`, `.github/workflows/cd.yml`):
  - GitHub OIDC trust (`trust.json`) to a dedicated IAM **deploy role**
    (`infra/cd-deploy-policy.json`), scoped to this repo's `dev`/`prod` environment
    subjects. No long-lived AWS credentials.
  - The **deploy role is deliberately broader than the Lambda execution role**: it
    creates the entire stack (CloudFormation, S3, KMS, Synthetics, Logs, API
    Gateway, SNS, and `greeter-http-*` IAM roles). A few statements use
    `Resource: "*"` where the service exposes no resource-level ARN on its create
    actions; the rationale is recorded in `infra/cd-deploy-policy.md` and the policy
    passes the repo's `bin/iam-check` gate. This is separate from — and does not
    weaken — the Lambda execution role's tight single-table + single-key scope.
  - `bin/smoke` (post-deploy liveness + correctness) and `perf/http_bench.rb`
    (latency SLO + regression gate).
- **Contract**: new public HTTP API (`POST /greetings`) with defined status codes
  (201/200/400/422/409/503) and JSON bodies.
- **No change** to `greeter-core`; `vendor/greeter-core-api.md` documents the composed surface.
