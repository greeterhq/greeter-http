# greeter-http

[![CI](https://github.com/greeterhq/greeter-http/actions/workflows/ci.yml/badge.svg)](https://github.com/greeterhq/greeter-http/actions/workflows/ci.yml)

Exposes the [`greeter-core`](https://rubygems.org/gems/greeter-core) domain over
HTTP on AWS Lambda + API Gateway, and keeps a per-guest greeting count in
DynamoDB. Greeting the same guest increments a counter; retries are safe
(idempotent) and never double-count.

## What it does

A single endpoint, `POST /greetings`, greets a named guest and returns how many
times that guest has been greeted:

```
POST /greetings
Content-Type: application/json
Idempotency-Key: 7f3a-1c2b-91c

{ "name": "alice bonsu" }
```

```json
{
  "guest_name": "Alice Bonsu",
  "greeting": "Hello, Alice Bonsu!",
  "count": 1,
  "greeted_at": "2024-06-01T09:00:00Z"
}
```

Guest names are normalized by the domain (trimmed, titlecased), so
`"  alice bonsu "` and `"Alice Bonsu"` are the same guest and share one count.

### Idempotency

Every request must carry a client-supplied `Idempotency-Key` header.

- A **new** key greets the guest and increments the count — `201 Created`.
- Replaying the **same** key with the **same** body returns the original result
  without incrementing — `200 OK`, identical body.
- Reusing a key with a **different** body is rejected — `409 Conflict`.
- Keys are remembered for a bounded window (default 24h) and deduplicated across
  all keys in that window, not just the most recent one.

### Status codes

| Status | When |
| --- | --- |
| `201 Created` | first successful greeting for a key |
| `200 OK` | replay of a previously seen key + body |
| `400 Bad Request` | missing `Idempotency-Key`, or malformed JSON |
| `422 Unprocessable Entity` | invalid name (empty, too long, control chars) |
| `409 Conflict` | key reused with a different request |
| `503 Service Unavailable` | transient storage failure (retryable; sends `Retry-After`) |
| `500 Internal Server Error` | unexpected error |

## Architecture

Hexagonal, composing `greeter-core` without modifying it:

```
lib/greeter_http/
  application/   use cases (GreetAndCount) composing Greeter::Core
  ports/         abstract interfaces (GreetingCounter)
  adapters/      all I/O: Lambda handler, Rack app, DynamoDB, clock, presenter
  app.rb         the ONLY composition root (wires everything)
lib/lambda_function.rb   AWS Lambda entry point (handler)
infra/template.yaml      AWS SAM: Lambda, HTTP API, DynamoDB, IAM, alarms
```

The Lambda handler is a thin translator (API Gateway event <-> Rack); all HTTP
logic lives in the Rack app, and all business logic in `GreetAndCount`.

### Persistence

One DynamoDB table (on-demand, PITR + SSE), two item types sharing a guest
partition:

- **counter** item (`SK = "COUNTER"`) — the running count, never expires.
- **dedupe** item (`SK = "IKEY#<key>"`) — idempotency record with the request
  fingerprint and a TTL on `expires_at`.

Writes use a single optimistic-lock `TransactWriteItems` so the count is always
exact, even under concurrent requests and retries.

## Requirements

- Ruby 3.3.x (pinned to 3.3.13 locally via `.ruby-version`; CI uses the latest
  3.3.x). The `Gemfile`
  deliberately carries no `ruby` directive so the Lambda `ruby3.3` managed
  runtime (currently a 3.3.x patch) is accepted at deploy time.
- Bundler
- For deploy / local build + invoke: the [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install.html)
  (a recent version — `ruby3.3` support requires newer than 1.1xx) and Docker
- For the integration suite: Docker + DynamoDB Local (optional)

## Setup

```bash
bundle install
```

Smoke-check that the app loads:

```bash
bundle exec ruby -Ilib -e "require 'greeter_http'; puts 'ok'"
```

## Running the test suite

The behavior is fully exercised in-process (no AWS needed): unit specs, a Rack
app driven by `rack-test`, and Cucumber features that drive the Lambda handler
with built API Gateway events.

```bash
bundle exec rspec        # unit + adapter + contract specs
bundle exec cucumber     # end-to-end acceptance features
bundle exec rubocop      # lint
```

### Optional: integration specs against DynamoDB Local

These are tagged `:integration` and skipped unless `DYNAMODB_ENDPOINT` is set.
This is the most reliable way to exercise the full DynamoDB happy path locally:
it drives the real `DynamoDbGreetingCounter` against DynamoDB Local, with no
Lambda-container credential plumbing in the way.

```bash
# Start DynamoDB Local with -sharedDb (entrypoint is `java`, so the jar and
# flags come after the image name). The suite creates and tears down its own
# table per run, so no manual table setup is needed here.
docker run --rm -d --name ddb-local -p 8000:8000 \
  amazon/dynamodb-local -jar DynamoDBLocal.jar -inMemory -sharedDb

DYNAMODB_ENDPOINT=http://localhost:8000 bundle exec rspec spec/integration
```

## Performance benchmarks

`perf/http_bench.rb` has two regimes. The in-process one needs only Ruby; the
deployed one needs a live endpoint and is opt-in.

### In-process (default)

```bash
bundle exec ruby perf/http_bench.rb
```

Measures two paths and prints a `benchmark-ips` throughput report plus p99
latencies:

- **`GreetAndCount#call`** — the pure business logic. **Gated**: fails if p99 >
  **10 ms**, or if p99 is **>20% worse** than the recorded baseline.
- **`LambdaHandler#call`** — the full event→response path. **Reported only**
  (not gated); its in-process tail is too noise-dominated to police fairly.

Sample count is tunable for a quicker local run:

```bash
GREETER_PERF_SAMPLES=10000 bundle exec ruby perf/http_bench.rb
```

### Deployed load test (opt-in)

Set `GREETER_BASE_URL` to also run a Ruby-thread load generator (no k6 needed)
against a real endpoint: 10 virtual users **rate-paced to ~25 req/s** for 60s by
default.

```bash
GREETER_BASE_URL="https://xxxxxxxxxx.execute-api.eu-west-2.amazonaws.com" \
  bundle exec ruby perf/http_bench.rb
```

The generator is **paced to the service's configured capacity** — the HttpApi
stage throttles at `RouteThrottleRate` (25 req/s steady, 50 burst), so the test
drives at that rate to measure latency under sustained rated load rather than
overrunning the throttle. Each request targets a **distinct guest** so writes
spread across DynamoDB partitions (real throughput, not single-item contention).

- **Gated**: fails if steady-state **p95 > 300 ms**, >20% worse than baseline, or
  if any request **hard-fails** (5xx, connection error, or a non-429 4xx).
- **HTTP 429 is not a failure.** Any request throttled above the rate is counted
  **separately as `throttled`** (expected backpressure) and reported, never
  gated — so an accidental overrun shows up honestly instead of as a failure.
- The first request's latency is reported **separately as the client-observed
  cold start** and excluded from the steady-state p95 (so a Lambda cold start
  never skews the gate).
- Tunables: `GREETER_PERF_RATE` (target req/s, default 25 — raise it to test a
  higher capacity), `GREETER_PERF_VUS` (default 10), `GREETER_PERF_DURATION_S`
  (default 60).

### The baseline

The first run writes `perf/baseline.json`; later runs compare against it and
fail on a >20% regression of a gated metric.

> `perf/baseline.json` is **git-ignored on purpose** — it is a per-environment
> measurement (a laptop and a CI runner produce very different numbers, so a
> committed baseline would cause false cross-environment regression failures).
> Each environment records and keeps its own; CI caches it per OS + branch.

In **CI**, the `perf` job runs the in-process regime on every push with a
per-OS/branch cached baseline. The deployed load test is deliberately **not** in
push CI (it needs a live endpoint) — run it manually or in a post-deploy step.

### Cold-start Init Duration (report only)

`perf/cloudwatch_init_duration.rb` fetches the Lambda's authoritative
`Init Duration` from CloudWatch Logs and reports min/mean/max/p95 — a different
figure from the client-observed cold start above (it is just the runtime init
phase). It is a **reporter, not a gate**: it prints and never fails. Needs AWS
credentials and a deployed stack; defaults to the `greeter-dev` profile and
`eu-west-2`:

```bash
STACK=sam-app AWS_PROFILE=greeter-dev AWS_REGION=eu-west-2 \
  bundle exec ruby perf/cloudwatch_init_duration.rb
```

If no cold starts occurred in the window (the function stayed warm), it says so
and exits cleanly — trigger one by deploying, then re-run.

## Building

> **Always build with `--use-container`.** The Ruby bundle (including
> `greeter-core` and native extensions) must be compiled for the Lambda
> `ruby3.3` runtime. `--use-container` runs `bundle install` inside the AWS
> `build-ruby3.3` image so gems land under `vendor/bundle/ruby/3.3.0`. A plain
> `sam build` uses the host Ruby instead; if the host is on a different Ruby
> (this machine's default is a newer line), gems get vendored under the wrong
> ABI directory and the function fails at init with `cannot load such file`.

```bash
sam build --use-container -t infra/template.yaml
```

The build writes `.aws-sam/build/` (artifact + `template.yaml`). Run `sam local`
and `sam deploy` against that **built** template.

## Interacting with the service

### Locally with Rack (recommended for development)

The service is a Rack app with a thin Lambda adapter on top, so for day-to-day
development you can run the Rack app directly — no Lambda, no SAM, no container,
no AWS credentials. This exercises the exact same routing, status codes,
idempotency and JSON the deployed function uses.

```bash
bundle exec rackup          # in-memory counter (default), serves on :9292
```

```bash
curl -i http://127.0.0.1:9292/greetings \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: demo-key-1' \
  -d '{"name":"alice bonsu"}'
```

Backend is chosen by `GREETER_BACKEND`:

- `memory` (default) — in-memory counter, zero external dependencies.
- `dynamodb` — the real DynamoDB adapter against DynamoDB Local (the host
  process reaches it directly on `localhost`, no container networking). Three
  one-time setup steps, then start the server:

  ```bash
  # 1. Start DynamoDB Local WITH -sharedDb. The image's entrypoint is `java`,
  #    so the jar and its flags must come after the image name in this order.
  #    Without -sharedDb, DynamoDB Local keys tables by access-key + region, so
  #    the table you create below and the one the app looks for end up in
  #    different namespaces and every request returns 503.
  docker run --rm -d --name ddb-local -p 8000:8000 \
    amazon/dynamodb-local -jar DynamoDBLocal.jar -inMemory -sharedDb

  # 2. Create the table (partition key PK, sort key SK, on-demand billing).
  #    Any credentials work against DynamoDB Local; these are placeholders.
  AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local AWS_REGION=us-east-1 \
    aws dynamodb create-table --endpoint-url http://localhost:8000 \
      --table-name greeter-http-local --billing-mode PAY_PER_REQUEST \
      --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
      --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE

  # 3. Start the server pointed at it. The startup banner echoes the backend,
  #    table and endpoint so you can confirm the wiring.
  GREETER_BACKEND=dynamodb \
    GREETER_TABLE_NAME=greeter-http-local \
    GREETER_DYNAMODB_ENDPOINT=http://localhost:8000 \
    bundle exec rackup
  ```

  A `503` from a `dynamodb`-backed server almost always means DynamoDB Local
  isn't reachable, was started without `-sharedDb`, or the table is missing.

What `rackup` does NOT cover: the Lambda handler, the packaged artifact, and API
Gateway event translation. Use `sam local` (below) or a deploy to validate those.

### Locally with the SAM CLI

This validates the packaged Lambda artifact and the event→Rack translation —
the closest local mirror of production. Unlike the Rack path, the function runs
inside a Lambda container, so reaching DynamoDB Local takes extra plumbing (all
learned the hard way). Run the steps in order.

**Step 1 — build the artifact** (always `--use-container`, see Building above):

```bash
sam build --use-container -t infra/template.yaml
```

**Step 2 — start DynamoDB Local on a user-defined network, and create the
table.** Two things matter here:

- `-sharedDb` so DynamoDB Local ignores credential/region namespacing (otherwise
  the function and your `aws` CLI see different tables). The image's entrypoint
  is `java`, so the jar and its flags come after the image name.
- A **user-defined** Docker network (`greeter-local`). The default `bridge`
  network has no DNS, so the Lambda container could not resolve the DynamoDB
  Local container by name.

```bash
docker network create greeter-local

docker run --rm -d --name ddb-shared --network greeter-local -p 8000:8000 \
  amazon/dynamodb-local -jar DynamoDBLocal.jar -inMemory -sharedDb

AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local AWS_REGION=us-east-1 \
  aws dynamodb create-table --endpoint-url http://localhost:8000 \
    --table-name greeter-http-local --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
    --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE
```

**Step 3 — create an `env.json`** so the function points at the DynamoDB Local
container (by its name on the shared network). Copy the tracked template:

```bash
cp env.json.example env.json
```

`env.json` is gitignored (it is per-developer local config); `env.json.example`
is the tracked starting point:

```json
{ "GreeterFunction": {
    "GREETER_TABLE_NAME": "greeter-http-local",
    "GREETER_DYNAMODB_ENDPOINT": "http://ddb-shared:8000"
} }
```

`GREETER_DYNAMODB_ENDPOINT` is declared in the template, so SAM's `--env-vars`
passes it through — SAM silently drops env-file keys that are not declared under
the function's `Environment.Variables`.

**Step 4 — run the service.** Pass the BUILT template, the `env.json`, and the
same `--docker-network`. Either serve the HTTP API, or invoke the handler once
with a fixture event:

```bash
# Option A: run the HTTP API on :3000
sam local start-api -t .aws-sam/build/template.yaml \
  --env-vars env.json --docker-network greeter-local

# then, in another terminal:
curl -i http://127.0.0.1:3000/greetings \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: demo-key-1' \
  -d '{"name":"alice bonsu"}'
```

```bash
# Option B: invoke the handler once with a canned event
sam local invoke GreeterFunction -t .aws-sam/build/template.yaml \
  -e spec/fixtures/events/happy_path.json \
  --env-vars env.json --docker-network greeter-local
```

Either way: `201` the first time, `200` (same count) on replay with the same
`Idempotency-Key`; a new key increments the count; the same key with a different
body returns `409`.

If you omit the `--env-vars`/`--docker-network` flags (or skip step 2), the
function can't reach DynamoDB and every request returns `503` — the rest of the
pipeline still runs. The composition root honors `GREETER_DYNAMODB_ENDPOINT`
only for this local path (unset in real AWS, where the SDK resolves the regional
endpoint and task credentials). For a quicker inner loop, the Rack path and the
`:integration` suite both avoid this container plumbing entirely.

### Invoking the handler directly

```bash
sam local invoke GreeterFunction -t .aws-sam/build/template.yaml \
  -e spec/fixtures/events/happy_path.json
```

(Event fixtures used by the tests live in `spec/fixtures/events/`.)

## Deploying

```bash
sam build --use-container -t infra/template.yaml
sam deploy --guided
```

The template provisions a Ruby 3.3 Lambda, an HTTP API (`POST /greetings` with
route throttling), the DynamoDB table (on-demand, PITR, SSE, TTL on
`expires_at`), a least-privilege execution role (`dynamodb:GetItem` +
`dynamodb:PutItem` + `dynamodb:UpdateItem` on that one table — the counter write
is a `TransactWriteItems`, which DynamoDB authorizes by its underlying Put/Update
actions, not by `TransactWriteItems` itself), X-Ray tracing, 14-day log
retention, and CloudWatch alarms on 5xx rate and p95 latency.

`sam deploy` prints the API base URL as the `ApiBaseUrl` output.

### Testing a deployment

The function is wired to `POST /greetings` on the HTTP API's `$default` stage,
so the endpoint is `<ApiBaseUrl>/greetings` (no stage segment in the path). Set a
shell variable to the `ApiBaseUrl` output and exercise the contract:

```bash
BASE="https://xxxxxxxxxx.execute-api.<region>.amazonaws.com"   # the ApiBaseUrl output

# 1. First greeting -> 201, count 1
curl -i "$BASE/greetings" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"name":"alice bonsu"}'

# 2. Idempotent replay: same key + same body -> 200, SAME count (no double-count)
KEY="fixed-key-123"
curl -i "$BASE/greetings" -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" -d '{"name":"carol kay"}'
curl -i "$BASE/greetings" -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" -d '{"name":"carol kay"}'

# 3. New key, same guest -> 201, count incremented
curl -i "$BASE/greetings" -H 'Content-Type: application/json' -H "Idempotency-Key: $(uuidgen)" -d '{"name":"carol kay"}'

# 4. Key reused with a DIFFERENT body -> 409
curl -i "$BASE/greetings" -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" -d '{"name":"different person"}'

# 5. Missing Idempotency-Key -> 400
curl -i "$BASE/greetings" -H 'Content-Type: application/json' -d '{"name":"alice"}'

# 6. Invalid (empty) name -> 422
curl -i "$BASE/greetings" -H 'Content-Type: application/json' -H "Idempotency-Key: $(uuidgen)" -d '{"name":""}'
```

Or run the `@smoke` Cucumber feature against the deployed endpoint (see
[Smoke test against a deployed endpoint](#smoke-test-against-a-deployed-endpoint)).

To confirm it is really persisting to DynamoDB, scan the table (its name is the
`TableName` stack output), where you should see `GUEST#…` counter items and
TTL'd `IKEY#…` dedupe items:

```bash
aws dynamodb scan --table-name <TableName-output> --region <region> --max-items 10
```

Tail the function logs if a call returns an unexpected `5xx`:

```bash
sam logs --stack-name <stack-name> --name GreeterFunction --region <region> --tail
```

### Tearing down

Delete the stack to remove all provisioned resources (Lambda, HTTP API, DynamoDB
table, IAM role, alarms, log group) and avoid ongoing charges:

```bash
sam delete --stack-name <stack-name> --region <region>
```

### Configuration

The function reads two environment variables (set by the SAM template):

| Variable | Meaning | Default |
| --- | --- | --- |
| `GREETER_TABLE_NAME` | DynamoDB table name | (from the stack) |
| `GREETER_IDEMPOTENCY_TTL_SECONDS` | idempotency retention window | `86400` (24h) |

### Smoke test against a deployed endpoint

The `@smoke` Cucumber feature runs against a real endpoint when
`GREETER_BASE_URL` is set, and is skipped otherwise:

```bash
GREETER_BASE_URL="$API_BASE_URL" bundle exec cucumber --tags @smoke
```

## Development notes

- `greeter-core` is a dependency and is never reopened, subclassed, or vendored —
  only composed.
- Specs and features map to the spec in
  `openspec/changes/.../specs/greeting-counter/spec.md`; each OpenSpec scenario
  has one `@requirement-greeting-counter` Cucumber scenario.
- Collaborators are injected via keyword arguments; `app.rb` is the only
  composition root.

### Bumping the OpenSpec CLI version

The `spec-gate` CI job validates the OpenSpec change in `--strict` mode. The CLI
version is **pinned** so the gate is reproducible: a floating `@latest` can add
or tighten rules (e.g. the ">500 character requirement" check added in 1.14.1)
and fail the gate with no change to the repo. The pin lives in one place —
`OPENSPEC_VERSION` in `.github/workflows/ci.yml` — and must stay in sync with the
version installed locally.

OpenSpec is installed as an npm global package (not Homebrew), so bump it with
npm, then re-pin and re-validate:

```bash
# 1. Upgrade (or install a specific version) locally.
npm install --global @fission-ai/openspec@latest   # or @<version>

# 2. Read the version you now have.
openspec --version                                  # e.g. 1.14.1

# 3. Re-validate against the new CLI BEFORE changing CI. Fix any new findings
#    (newer versions may introduce stricter checks).
openspec validate --all --strict --no-interactive

# 4. Set OPENSPEC_VERSION in .github/workflows/ci.yml to that exact version,
#    and commit the workflow change together with any spec fixes from step 3.
```

Keep the local upgrade and the `OPENSPEC_VERSION` bump in the **same commit** so
CI and developer machines never drift apart.

## Cutting a release (maintainers)

Releases are produced by the `release` job in `.github/workflows/ci.yml`. It runs
**only** on version tags and **only** if every other CI job passes (`spec`,
`bdd`, `lint`, `security`, `integration`, `spec-gate`), then builds the Lambda
artifact and creates the GitHub Release.

The service version lives in `lib/greeter_http/version.rb` as
`GreeterHttp::VERSION` (surfaced in the startup banner) and **must match the
release tag** — the release job fails fast if they disagree.

1. Bump `GreeterHttp::VERSION` in `lib/greeter_http/version.rb` to the version
   you intend to tag; commit it.
2. Make sure `main` is green: push and confirm the CI run passes end to end
   (the release job is skipped on non-tag builds — that's expected).
3. Tag with a **`v` prefix** matching the constant, and push the tag:

   ```bash
   git tag v0.1.0        # must equal GreeterHttp::VERSION (0.1.0)
   git push origin v0.1.0
   ```

The tag must start with `v` (e.g. `v0.1.0`). The workflow triggers on
`tags: ["v*"]` and the release job guards on `refs/tags/v`, so a bare `0.1.0`
tag is ignored and produces no release. If the tag and `GreeterHttp::VERSION`
disagree, the release job's "Check VERSION matches the tag" step fails before
building — bump the constant to match and re-tag.

What the release job does on a `v*` tag:

- Asserts `GreeterHttp::VERSION` equals the tag (minus the `v`), failing the
  release before any build if they drift.
- Runs `sam build` on the GitHub Ubuntu runner (its host Ruby is the latest 3.3.x via
  `setup-ruby`, matching the Lambda `ruby3.3` ABI, so a plain `sam build`
  vendors gems correctly — no `--use-container` needed in CI).
- Packages a tarball `greeter-http-v0.1.0.tar.gz` laid out as a ready-to-deploy
  SAM working directory: the build output sits at its conventional
  `.aws-sam/build/` location (function code, vendored gems, and the built
  template), with a `.sha256` checksum alongside.
- Resolves the bundled `greeter-core` version from the lock and records it in the
  release notes, so the `greeter-http`↔`greeter-core` pairing is discoverable
  from the Release without decoding the tag.
- Creates the GitHub Release and attaches both assets.

The release is a pre-built, ready-to-deploy artifact, not a running service — so
you deploy it **without** re-running `sam build`. The tarball unpacks into a
normal SAM working directory (the build output is at `.aws-sam/build/`), so a
bare `sam deploy` finds it:

```bash
tar -xzf greeter-http-v0.1.0.tar.gz
cd greeter-http-v0.1.0
sam deploy --guided
```

`--guided` prompts for stack name, region, and parameters, then saves them to
`samconfig.toml` for subsequent `sam deploy` runs. Leave `DynamoDbEndpoint`
empty (it is a local-only override; see
[Locally with the SAM CLI](#locally-with-the-sam-cli)). You need AWS credentials
and a region configured, and permission to create the Lambda, HTTP API, DynamoDB
table, IAM role, and alarms. The pinned dependency set is in the bundled
`Gemfile.lock`.

> **Note:** the `release` job needs `contents: write` (declared in the workflow)
> to create the Release. Confirm the repository's Settings → Actions → Workflow
> permissions allow it, otherwise the final step fails when the tag is pushed.

See `openspec/` for the specification of externally observable behaviour.
