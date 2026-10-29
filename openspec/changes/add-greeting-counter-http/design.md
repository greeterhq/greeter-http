# Design

## Context

See proposal.md (Why) for motivation and specs/greeting-counter for the behavior
contract. Key constraints that shape this design:

- **greeter-core is frozen.** The installed `greeter-core 0.1.2` exposes
  `Greeter::Core::Domain::GreetingService#greet(raw_name) -> Greeting` (built with
  an injected `clock:`), the `Greeting`/`GuestName` value objects, `InvalidGuestName`,
  and the abstract `Ports::Clock` / `Ports::GreetingPresenter`. The core has no
  concept of counting or persistence. It must not be reopened, subclassed, or
  vendored — compose only. See `vendor/greeter-core-api.md`.
- **Hexagonal layout** (per workspace architecture rules): `application/` use cases,
  `ports/` abstract interfaces, `adapters/` all I/O, `app.rb` the only composition
  root. Collaborators injected by keyword. Ruby 3.3, `frozen_string_literal`,
  RuboCop clean.
- **Delivery target** is AWS Lambda + API Gateway, which deliver at least once, so
  retries are expected and must not double-count.

## Goals / Non-Goals

**Goals:**
- Keep all counting/idempotency logic in this service; the core stays a pure
  dependency composed by one application use case.
- Guarantee the counter is never transiently wrong, including across a crash in the
  middle of a write.
- Make the HTTP behavior testable in-process (no AWS) via Rack.

**Non-Goals:**
- No change to `greeter-core` (if a core change were needed, stop).
- No multi-region, no analytics/streaming, no auth/rate-limiting beyond the
  idempotency-key contract.
- Infrastructure is provisioned via AWS SAM (`infra/template.yaml`) and is in scope:
  the DynamoDB table (on-demand, PITR, SSE, TTL on `expires_at`), the Ruby 3.3 Lambda
  (X-Ray tracing, 14-day log retention), the HTTP API `POST /greetings` route with
  throttling, a least-privilege IAM role (GetItem + PutItem + UpdateItem on that one
  table — a TransactWriteItems is authorized by its underlying Put/Update actions,
  not by TransactWriteItems), and CloudWatch alarms (5xx rate, p95 latency). The application code stays
  decoupled from provisioning; the template references the handler and table name.

## Decisions

### D1. Compose, not decorate — `GreetAndCount` application service

`application/greet_and_count` orchestrates two collaborators and returns its own
result type (e.g. `GreetedGuest(guest_name:, count:, replayed:)`):

1. `greeting = greeting_service.greet(raw_name)` — the core use case. Raises
   `Greeter::Core::Domain::InvalidGuestName` on bad input, which propagates.
2. `result = greeting_counter.increment(guest: greeting.guest_name, idempotency_key:, fingerprint:)`

The core's `GreetingService` returns a bare `Greeting` and its interface has no
count, so there is nothing to decorate — a "decorator" would have to change the
return shape, which is composition in disguise and would tempt a lie about the
frozen `Greeting` value. Composition keeps the core pristine and the count entirely
in this service's port + adapter.

**Alternative considered:** decorate the core use case. Rejected — mismatched
interface/return type; violates the compose-only rule in spirit.

### D2. `GreetingCounter` port speaks the service's language

`ports/greeting_counter` is an abstract port local to this service:

```
#increment(guest:, idempotency_key:, fingerprint:) -> Result
  Result = { count: Integer, replayed: Boolean }
  raises GreetingCounter::KeyReused     (same key, different fingerprint)
  raises GreetingCounter::Unavailable   (transient store failure)
```

No DynamoDB vocabulary leaks through the port — transactions, TTL, and condition
expressions stay behind the adapter. This lets `GreetAndCount` and the Rack layer be
tested against an in-memory fake counter.

### D3. DynamoDB single table, two item types

One table, partition key `PK`, sort key `SK`, TTL attribute `expires_at`.

```
COUNTER item (one per guest, never expires)
  PK = "GUEST#<GuestName#display>"
  SK = "COUNTER"
  count       : Number
  updated_at  : String (ISO-8601)

DEDUPE item (one per idempotency key, TTL'd)
  PK = "GUEST#<GuestName#display>"
  SK = "IKEY#<idempotency-key>"
  fingerprint    : String   (sha256 of normalized request)
  count_snapshot : Number   (the count THIS request produced)
  greeted_at     : String (ISO-8601)
  created_at     : String (ISO-8601)
  expires_at     : Number  (epoch seconds = created_at + TTL window)
```

- **Partition key uses the normalized `GuestName#display`** ("Alice Bonsu"), so
  names differing only by case/whitespace share a counter — consistent with the
  spec requirement. Core performs this normalization.
- Counter and its dedupe keys share a partition, so one transaction can touch both,
  and a guest's data is co-located.
- **TTL only on dedupe items** (`expires_at`); the counter never expires.
- `expires_at` is epoch seconds because DynamoDB TTL requires that format.

### D4. Fingerprint over the normalized request

`fingerprint = sha256(GuestName.new(raw_name).display)`. Fingerprinting the
*normalized* name (not raw input) keeps "same request" consistent with "same guest",
so " alice " vs "alice" under one key is a replay, not a `409`. If the request body
grows beyond the name, the fingerprint extends to cover the normalized whole.

### D5. Hybrid replay-with-fingerprint

A repeat of a known key branches on the stored fingerprint:
- **match** → replay: return `count_snapshot`, `200 OK`, do not increment.
- **differ** → `KeyReused` → `409`.
A first success returns `201 Created`. Replays return `200 OK` with an identical
body (the snapshot makes them byte-identical and deterministic to test).

**Alternative considered:** report every replay as `409`, or re-read current count
instead of snapshotting. Rejected — `409` on a benign retry breaks naive clients;
re-reading makes replay responses drift with unrelated traffic and non-deterministic
to test.

### D6. Write path — optimistic lock in one `TransactWriteItems` (Option 1)

The two facts (key recorded, count incremented) must land atomically. The adapter:

1. `GetItem` the counter (absent → current = 0).
2. `new = current + 1`.
3. `TransactWriteItems` with two actions, all-or-nothing:
   - `Put` dedupe item `{ fingerprint, count_snapshot: new, ... , expires_at }`
     condition `attribute_not_exists(SK)`.
   - `Update` counter `SET #count = :new`
     condition `#count = :current` (or `attribute_not_exists(#count)` when current = 0).
4. Interpret a `TransactionCanceledException` by cancellation reason:
   - **dedupe condition failed** → key already seen → `GetItem` the dedupe item;
     fingerprint match → replay (`200`, `count_snapshot`); differ → `KeyReused`.
   - **counter condition failed** → a concurrent writer moved the count →
     re-read and retry from step 1 (bounded retries).
   - **throttling / capacity** → `Unavailable`.

This keeps the counter correct at all times. Alternatives — atomic `ADD` then
compensate on replay (over-counts transiently; compensation lost on crash), or
stamp-then-increment (under-counts and strands a dedupe marker on crash) — were
rejected: both have a window where a crash leaves the two facts disagreeing. One
atomic commit removes the window entirely.

### D7. Thin Lambda handler over a Rack app

- `adapters/rack_app` owns routing (`POST /greetings`), JSON parse, header
  extraction (`Idempotency-Key`), presentation ("Hello, <name>!"), and error → status
  mapping. Presentation lives here because core's `GreetingPresenter` is abstract and
  `GreetingService` returns a raw `Greeting`.
- `adapters/lambda_handler` is a one-way translator: API Gateway event → Rack env →
  response → API Gateway response shape. No business logic.
- `rack-test` drives the Rack app in-process for behavior checks; Cucumber scenarios
  (tagged `@requirement-greeting-counter`) exercise the same Rack app. Each OpenSpec
  scenario maps to exactly one Cucumber scenario.

### D8. Error → HTTP mapping (boundary in the Rack/application layer)

| Cause | Status | Retryable |
| --- | --- | --- |
| `InvalidGuestName` | 422 | no |
| missing `Idempotency-Key` | 400 | no |
| `GreetingCounter::KeyReused` | 409 | no |
| `GreetingCounter::Unavailable` (transient store) | 503 (+ `Retry-After`) | yes |
| unexpected error | 500 | no |

Transient store failures are mapped to `503`, never collapsed into `500`, so clients
know to retry (ideally with the same key).

### D9. Configuration via the composition root

`app.rb` is the only place real adapters are constructed and wired: table name,
DynamoDB client, a system clock implementing `Ports::Clock`, and the **TTL window
(default 24h), injected not hard-coded** so it is tunable per environment. Tests wire
fakes (in-memory counter, `Greeter::Core::Testing::FixedClock`) through the same
keyword-argument seams.

### D10. Deploy identity — GitHub OIDC + a dedicated deploy role, distinct from the execution role

CI/CD authenticates to AWS with GitHub OIDC (`trust.json`) assuming a dedicated IAM
role (`infra/cd-deploy-policy.json`) — no long-lived keys. The trust policy matches
this repo's `dev`/`prod` **environment** subjects in GitHub's immutable numeric-ID
subject format (`repo:<org>@<id>/<repo>@<id>:environment:<env>`); a plain
`repo:owner/name:*` pattern would not match tokens minted in that format.

There are **two different roles with two different scopes, on purpose**:

- The **Lambda execution role** (D-elsewhere / template) is tight: `GetItem` +
  `PutItem` + `UpdateItem` on the one table, `Decrypt` on the one CMK. Unchanged.
- The **deploy role** is necessarily broad — it creates the *entire* stack:
  CloudFormation, the SAM managed bootstrap bucket, KMS, Synthetics, CloudWatch
  Logs (including the vended-logs delivery for API access logging), API Gateway v2,
  SNS, DynamoDB, and `greeter-http-*` IAM roles (with `PassRole` scoped to that name
  prefix). A few statements use `Resource: "*"` where the AWS API has no
  resource-level ARN on the relevant create/tag action, or target an **AWS-owned**
  ARN named explicitly (the `Serverless-2016-10-31` transform; the
  `aws-synthetics-library-<region>` runtime bucket). The per-statement rationale is
  in `infra/cd-deploy-policy.md`, and the policy passes the repo's `bin/iam-check`
  least-privilege gate. Broadening the deploy role does not touch the execution
  role's scope.

This policy was proven by iterated real deploys, not derived on paper: the first
prod deploy also surfaced that two account-global physical names collided with dev
(see D13).

### D11. Monitoring — canary + alarms are liveness/correctness; latency lives in the metric alarm

A CloudWatch Synthetics canary runs the same two assertions as `bin/smoke` against
the live endpoint every 5 minutes — valid greeting returns 2xx with an incrementing
count, and a malformed body returns `400` — and pages via the SNS topic on failure.

Neither the canary nor `bin/smoke` asserts latency. A synthetic pass/fail probe over
a handful of serial calls measures per-call TLS/connection-setup noise and swings too
much run-to-run to gate on; it is the wrong instrument for a percentile SLO. The p95
latency SLO is owned by (a) `HttpLatencyP95Alarm`, a CloudWatch metric alarm over the
API's real request stream, and (b) `perf/http_bench.rb`, which measures steady-state
p95 under concurrent load with cold start excluded and regression-checks it against a
baseline. Keeping latency in exactly those two places — and out of the liveness
probes — avoids a flaky gate that pages on probe noise rather than real regressions.

### D12. One customer-managed CMK for env vars, logs, and the paging topic

A single CMK encrypts the Lambda environment variables, both log groups, and the SNS
topic. The key policy grants the account root admin, the `logs.<region>` service
principal encrypt/describe (without which log delivery to an encrypted group silently
fails), and the `cloudwatch` service principal decrypt/generate-data-key (so alarms
can publish to the encrypted topic). Note a consequence for deploy permissions: with
CMK-encrypted Lambda env vars, CloudFormation makes Lambda call `kms:Encrypt`,
`GenerateDataKey`, and `CreateGrant` as the *deploying* principal — so the deploy
role (D10) carries those KMS data-plane actions, not only control-plane ones.

### D13. Stack-scoped physical names for account-global resources

The Synthetics canary `Name` and the API access-log group `LogGroupName` are
account/region-global identifiers. Hardcoding them (`greeter-http-health`,
`/aws/apigateway/greeter-http-access`) let dev deploy first but made the prod
`CreateChangeSet` fail its `ResourceExistenceCheck` — the names were already taken by
dev in the same account/region. Both are now derived from `AWS::StackName`
(`!Ref AWS::StackName` for the canary — within the 21-char cap; `${AWS::StackName}-access`
for the log group), so dev and prod coexist. Renaming forces replacement of those two
resources on dev's next deploy; both are monitoring plumbing with no stored data, so
replacement is safe.

## Risks / Trade-offs

- **Optimistic-lock retries under contention** → bounded retry with exponential
  backoff and full jitter so concurrent writers de-synchronize; concurrency per guest
  is low for a greeting service, so contention is rare. A single hot counter item is
  still a per-partition write bottleneck, so under genuinely heavy concurrent writes
  to one guest the retries will eventually exhaust. **Next step if that becomes real:
  write-sharding** — split a guest's counter across N shard items
  (`SK = "COUNTER#<shard>"`), increment a random shard per write, and sum the shards
  on read — trading a hot single item for a scatter-read. Deferred until the write
  rate justifies it; the `GreetingCounter` port means it is an adapter-only change.
- **Extra `GetItem` before the transaction** (to compute the exact snapshot) → one
  cheap read per write; acceptable at this scale and the price of an always-correct
  counter.
- **DynamoDB TTL deletion is not instant** (background, can lag up to ~48h) → treated
  as fail-safe: a slightly-past-window key may still dedupe, which only strengthens
  the no-double-count guarantee; TTL is not relied on for precise expiry timing.
- **`last-write` fingerprint only guards reuse, not malicious collision** → sha256
  makes accidental collision negligible; this is not a security boundary.
- **Store coupling to DynamoDB semantics** → isolated behind `GreetingCounter`; a
  different store would be a new adapter, no change to application or ports.
- **Canary artifacts bucket blocks stack deletion when non-empty** → the canary
  writes run artifacts to `CanaryArtifactsBucket`, and CloudFormation cannot delete a
  non-empty bucket, so a stack teardown can land in `DELETE_FAILED`. Mitigated by the
  bucket's 30-day expiration lifecycle rule; a teardown while artifacts are still
  present needs the bucket emptied first (or `delete-stack --retain-resources` then a
  manual bucket cleanup). Not relied on for correctness — it only affects teardown.

## Migration Plan

Greenfield capability — no existing data or behavior to migrate. Deployment requires
a DynamoDB table with `PK`/`SK` keys and TTL enabled on `expires_at` before the
Lambda is wired to a live route. Rollback is removal of the route/function; the table
can be left in place (idempotency records self-expire via TTL).
