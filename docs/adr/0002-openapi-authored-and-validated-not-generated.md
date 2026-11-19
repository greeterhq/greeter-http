# 2. The OpenAPI description is authored and validated, not generated

## Status

Accepted (2026-11-19)

## Context

greeter-docs and later tooling (such as a security scan of the deployed API)
need a machine-readable description of the HTTP API. This service is a Rack app
behind an AWS Lambda adapter with one route, handled by hand in `RackApp`. Rack
has no route table to introspect, so there is nothing to generate a description
from. Annotating the code would add a second place that describes each response
and would still not prove the description matches what the app returns.

## Decision

`openapi.yaml` (OpenAPI 3.1, repository root) is written by hand and kept
honest by tests and CI:

- Every response that the composed app (`GreeterHttp::App.build`) produces in
  RSpec and Cucumber is validated against it with `openapi_first`. A mismatch
  raises and names the operation and the status. Only responses are validated,
  because tests send invalid requests on purpose.
- A spec fails when `info.version` differs from `GreeterHttp::VERSION`.
- On pull requests, `oasdiff` compares the file with the base branch's copy and
  fails on breaking changes.
- The release tarball includes `openapi.yaml`.
- `openapi_first` is a test-group gem. It is never required from `lib/` or
  `exe/` and is never part of the Lambda bundle. A spec and a release check both
  enforce that.

## Consequences

- The description can lag behind the code for any response that no test
  produces. A new route or status needs a test, and so a description update, to
  be covered.
- Every release edits two version strings, `lib/greeter_http/version.rb` and
  `openapi.yaml`. The version spec makes forgetting the second one a failing
  build.
- The description says what the service does today, including `500` and `503`,
  and says nothing about `404` or `415`, which only happen on paths that are not
  part of the API.
- Coverage reporting (which operations the tests exercise) is off. It is a
  possible follow-up.
- Changing the approach later, for example to generate from a framework, needs a
  new record that supersedes this one.
