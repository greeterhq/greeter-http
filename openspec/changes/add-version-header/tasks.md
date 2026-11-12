# Tasks

## 1. Red tests

Write all tests first, commit as `test(add-version-header): red`, and show each
failing for the right reason (missing header expectation or `NameError` for the
missing middleware, not a syntax error). Do not edit these files afterwards to
make them pass.

- [ ] 1.1 Write `spec/adapters/version_headers_spec.rb` covering: headers added to 201, 200, 400, 409, 413, 422, 503, 500, 404 (unrouted path) and 404 (`GET /greetings`) responses of a stubbed inner app / `App.build` with an in-memory counter; values equal the constants; request-supplied `X-Greeter-Version` and env vars ignored; `X-Greeter-Synthetic: true` gives identical status, body, headers and no echo. Tag each example `@requirement-<slug>` and `@scenario-<slug>` per the spec. Verify: `bundle exec rspec spec/adapters/version_headers_spec.rb` fails with `NameError`/expectation failures.
- [ ] 1.2 Extend `spec/adapters/lambda_handler_spec.rb` to assert both headers appear unchanged in the returned `headers` for the 201, 422 and unrouted-path fixtures. Verify: those examples fail on missing headers.
- [ ] 1.3 Add `features/version_headers.feature` with a `@smoke` scenario (tag `@requirement-deployed-stage-exposes-version-headers`, `@scenario-smoke-check-on-a-deployed-stage`) that posts a greeting to `GREETER_BASE_URL` and checks `X-Greeter-Version` matches `\d+\.\d+\.\d+` with no leading "v" and `X-Greeter-Core-Version` is non-empty. Add its steps to a new `features/step_definitions/version_header_steps.rb`; the request MUST send `X-Greeter-Synthetic: true`. Verify: with `GREETER_BASE_URL` unset the scenario is skipped; against a local `rackup` it fails on missing headers.
- [ ] 1.4 Add a version assertion in `spec/adapters/version_headers_spec.rb` that `GreeterHttp::VERSION == '0.5.20'`. Verify: fails while the version is `0.5.19`.
- [ ] 1.5 (S2, S4) In `spec/adapters/version_headers_spec.rb`, add examples tagged for the "Malformed version value is rejected at startup" scenario: constructing the middleware with `'v0.5.20'`, `"0.5.20\r\nX-Evil: 1"`, `' 0.5.20'`, `''` and `nil` raises `ArgumentError`; and an inner app that sets its own `x-greeter-version` is overwritten by the constant. Verify: fails because the middleware does not exist yet (`NameError`).
- [ ] 1.6 (S3) In `spec/security/http_security_spec.rb`, add examples for "No other version-disclosing headers": across 201, 422 and 404 responses, the only headers matching `/version|server|powered/i` are the two version headers. Verify: fails on missing version headers (expectation failure), and the existing CORS and wildcard examples stay green.

## 2. Middleware and wiring

- [ ] 2.1 Create `lib/greeter_http/adapters/version_headers.rb` (frozen_string_literal, keyword `app:`, `service_version:`, `core_version:` defaulting to the constants, lowercase header keys, no reads of `env` or `ENV`). Verify: `spec/adapters/version_headers_spec.rb` passes.
- [ ] 2.2 Require it in `lib/greeter_http/app.rb` and wrap `Adapters::RackApp` in `App.build`. Verify: `spec/adapters/lambda_handler_spec.rb` and `spec/architecture_spec.rb` pass; `bundle exec rubocop` is clean for the touched files.
- [ ] 2.3 (S2) In the middleware constructor, validate both values against `\A\d+(\.\d+)*([-.][0-9A-Za-z]+)*\z` (no leading "v", no whitespace or control characters) and raise `ArgumentError` otherwise; do not rescue exceptions raised by the inner app. Verify: task 1.5 examples pass.
- [ ] 2.4 Bump `GreeterHttp::VERSION` to `0.5.20` in `lib/greeter_http/version.rb`. Verify: the task 1.4 example passes and the CI tag check logic still reads the file correctly.

## 3. Verify and docs

- [ ] 3.1 Document the two headers (names, source constants, out-of-scope API Gateway responses) in `README.md` and `docs/observability.md`. Verify: the documented `curl -i` against `bundle exec rackup` shows both headers.
- [ ] 3.2 Run `bundle exec rspec` and `bundle exec cucumber` (smoke scenarios skipped without `GREETER_BASE_URL`). Verify: all green.
- [ ] 3.3 Run `bundle exec rubocop`, `sam validate --template infra/template.yaml`, and `openspec validate add-version-header --strict`. Verify: all pass with no offences.
- [ ] 3.4 (S1) Run `bundle exec brakeman` and `bundle exec bundle-audit check --update`. Verify: no new warnings, and no advisory against the greeter-core version being advertised.
- [ ] 3.5 After deploy to a stage, run the `@smoke` scenario with `GREETER_BASE_URL` set. Verify: it passes and shows `0.5.20`.

## Workflow follow-up

- Archive the change after review and a successful deployed smoke run.
