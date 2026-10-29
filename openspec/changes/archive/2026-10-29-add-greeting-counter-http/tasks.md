# Tasks

Follow TDD throughout: for each behavior, write the failing RSpec (or Cucumber)
example first and watch it fail for the right reason (NameError / expectation
failure, not a syntax error), then implement until green. Test files under `spec/`
and `features/` are protected by the `protect-tests-during-apply` guard; run
`touch tmp/allow-test-edits` before each test-writing step and remove it afterward.
Keep every file RuboCop-clean and `frozen_string_literal: true`. Compose
`greeter-core` only — never reopen, subclass, or vendor it.

## 1. Project skeleton and composition seams

- [x] 1.1 Create the hexagonal directory layout under `lib/greeter_http/` (`application/`, `ports/`, `adapters/`) and a top-level `lib/greeter_http.rb`; verify `bundle exec ruby -Ilib -e "require 'greeter_http'"` loads without error.
- [x] 1.2 Add a `spec/spec_helper.rb` and `.rspec` (require `greeter/core`, `greeter/core/testing`, SimpleCov) and a Cucumber `features/support/env.rb`; verify `bundle exec rspec` and `bundle exec cucumber` run green with zero examples/scenarios.

## 2. GreetingCounter port and result type

- [x] 2.1 Write a failing spec asserting `GreetingCounter#increment(guest:, idempotency_key:, fingerprint:)` raises `NotImplementedError` on the abstract base and that `KeyReused`/`Unavailable` error classes exist; see it red.
- [x] 2.2 Implement `ports/greeting_counter.rb` (abstract `#increment`, nested `KeyReused`, `Unavailable`) and the `GreetedGuest`/counter `Result` value; verify 2.1 passes.

## 3. GreetAndCount application service (with in-memory fake counter)

- [x] 3.1 Write a failing spec for `GreetAndCount#call(raw_name:, idempotency_key:)` using a `Greeter::Core::Testing::FixedClock` and an in-memory fake counter: asserts it calls core `GreetingService#greet`, returns normalized name + count, and propagates `InvalidGuestName`; see it red.
- [x] 3.2 Implement `application/greet_and_count.rb` composing injected `greeting_service` and `greeting_counter` (keyword args, no globals), computing the fingerprint from the normalized `GuestName#display`; verify 3.1 passes.
- [x] 3.3 Add specs for replay (`replayed: true` result) and `KeyReused` propagation using the fake counter; verify they pass.

## 4. DynamoDB counter adapter

- [x] 4.1 Write failing specs against a stubbed DynamoDB client (aws-sdk stubs or DynamoDB Local) for first-increment: asserts one `GetItem` then a `TransactWriteItems` (dedupe `Put` with `attribute_not_exists(SK)` + counter `Update` guarded on prior count) and returns count `1`, `replayed: false`; see it red.
- [x] 4.2 Implement `adapters/dynamodb_greeting_counter.rb` item shapes (`PK=GUEST#<display>`, `SK=COUNTER` / `SK=IKEY#<key>`), the optimistic-lock transaction, and `expires_at = now + ttl` on the dedupe item; verify 4.1 passes.
- [x] 4.2a Verify the dedupe item stores `fingerprint` and `count_snapshot = new count`, and the counter item has no `expires_at`; assert via the stubbed write payloads.
- [x] 4.3 Add failing specs for the replay branch: `TransactionCanceled` on the dedupe condition → `GetItem` dedupe → fingerprint match returns `count_snapshot` with `replayed: true`; implement the cancellation-reason handling; verify green.
- [x] 4.4 Add failing specs for fingerprint mismatch → raises `KeyReused`, and for the counter-condition-failed branch → bounded re-read/retry; implement; verify green.
- [x] 4.5 Add failing specs for throttling/transient cancellation and client errors → raises `Unavailable`; implement the mapping; verify green.
- [x] 4.6 Add a spec proving cross-key dedupe and snapshot stability: K1 → count N, K2 → N+1, replay K1 → returns N (not current); verify green.

## 5. Clock and presenter adapters

- [x] 5.1 Write a failing spec for a `SystemClock` adapter satisfying `Ports::Clock#now` (returns a `Time`); implement `adapters/system_clock.rb`; verify green.
- [x] 5.2 Write a failing spec for a presenter that renders `"Hello, <display>!"` and the JSON body (`guest_name`, `greeting`, `count`, `greeted_at`); implement in `adapters/`; verify green.

## 6. Rack application (HTTP contract)

- [x] 6.1 Write failing `rack-test` specs for `POST /greetings`: happy path returns `201` with body `{guest_name, greeting, count}` for a fresh key; see it red.
- [x] 6.2 Implement `adapters/rack_app.rb` routing, JSON parsing, `Idempotency-Key` extraction, calling `GreetAndCount`, and success presentation (`201` first success, `200` replay); verify 6.1 passes.
- [x] 6.3 Add `rack-test` specs + implementation for the error contract: missing key → `400`, `InvalidGuestName` → `422`, `KeyReused` → `409`, `Unavailable` → `503` + `Retry-After`, unexpected → `500`; verify all green.
- [x] 6.4 Add a `rack-test` spec asserting replay returns `200` with a body identical to the original `201` body; verify green.

## 7. Lambda handler adapter

- [x] 7.1 Write a failing spec that feeds an API Gateway proxy event (method, path, headers incl. `Idempotency-Key`, JSON body) to the handler and asserts it returns the API Gateway response shape (`statusCode`, `headers`, `body`) by delegating to the Rack app; see it red.
- [x] 7.2 Implement `adapters/lambda_handler.rb` as a pure event↔Rack translator (no business logic); verify 7.1 passes.

## 8. Composition root

- [x] 8.1 Implement `lib/greeter_http/app.rb` as the only composition root: construct the DynamoDB client, `SystemClock`, core `GreetingService`, `DynamoDbGreetingCounter`, `GreetAndCount`, Rack app; read table name and the TTL window (default 24h) from injected config/env; verify a spec that builds the app wires a working Rack app end-to-end against a stubbed/local DynamoDB.

## 9. End-to-end acceptance (Cucumber, one scenario per spec scenario)

- [x] 9.1 Write `features/greeting_counter.feature` tagged `@requirement-greeting-counter` with exactly one scenario per scenario in `specs/greeting-counter/spec.md` (first greeting, subsequent, case/whitespace equivalence, empty name 422, over-long 422, missing key 400, retry no double-count, replay returns original count, 201-vs-200, key reuse 409, reuse-after-window, cross-key dedupe, throttling 503); see them red.
- [x] 9.2 Drive the features through the Rack app (via `rack-test`) with an in-memory or DynamoDB-Local backend and a fake/controllable clock and TTL; implement step definitions until all scenarios pass.
- [x] 9.3 Verify each OpenSpec scenario maps to exactly one `@requirement-greeting-counter` Cucumber scenario (count and names line up).

## 10. Infrastructure (AWS SAM)

- [x] 10.1 Author `infra/template.yaml` (AWS SAM): Ruby 3.3 Lambda pointing at `adapters/lambda_handler`, HTTP API with a single `POST /greetings` route and route-level throttling; verify `sam validate` passes.
- [x] 10.2 Define the DynamoDB table in the template: on-demand (pay-per-request) billing, PITR enabled, SSE enabled, and TTL on `expires_at`; pass the table name to the Lambda via environment; verify `sam validate` and that the TTL/PITR/SSE properties are present.
- [x] 10.3 Scope the Lambda execution role to least privilege on that one table: `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem` only (DynamoDB authorizes the optimistic-lock `TransactWriteItems` by its underlying Put/Update actions, not by `TransactWriteItems` itself), resource-limited to the table ARN; verify no wildcard table/action remains in the rendered policy.
- [x] 10.4 Enable X-Ray active tracing on the Lambda and set CloudWatch log retention to 14 days; verify both appear in `sam validate`/the synthesized template.
- [x] 10.5 Add CloudWatch alarms on the HTTP API 5xx rate and p95 latency; verify the alarms synthesize with sensible thresholds and reference the right metrics.

## 11. Full verification gate

- [x] 11.1 Run `bundle exec rspec` and `bundle exec cucumber` — all green; remove `tmp/allow-test-edits`.
- [x] 11.2 Run `bundle exec rubocop` clean and `openspec validate add-greeting-counter-http --strict --no-interactive` — both pass.
