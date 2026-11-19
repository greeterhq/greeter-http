# Proposal

## Why

greeter-docs needs to read greeter-http's requirements and the latest test
results, and it needs a machine-readable description of the HTTP API. Today:

- The seven `greeting-counter` Cucumber scenarios carry one feature-level
  `@requirement-greeting-counter` tag, which matches no heading. They have no
  per-scenario tags, so the trace check reports 7 untagged requirements and 13
  untagged scenarios.
- `features/support/traceability.rb` writes a bare array to
  `tmp/traceability.json`, which nothing else reads.
- The `version-headers` and `acceptance-gated-release` requirements are already
  tagged in RSpec, but nothing checks that every requirement stays covered.
- The API contract (`POST /greetings`, its statuses and headers) lives only in
  prose specs. Nothing validates what the Rack app returns against a machine
  description, and nothing blocks a breaking change to it.

greeter-core and greeter-cli adopt the same `live-docs-traceability`
capability. This change applies the shared rules here, where tests are both
Cucumber and RSpec, and adds the OpenAPI description.

## What Changes

**Live docs (shared rules, as in greeter-cli)**

- Slug rule: lowercase the heading text, replace each run of characters other
  than `a-z0-9` with one `-`, trim `-` from both ends.
- Replace the feature-level `@requirement-greeting-counter` tag with
  `@requirement-<slug> @scenario-<slug>` on each of the 13 `greeting-counter`
  scenarios, covering all seven requirements.
- RSpec formatter `spec/support/repo_trace_formatter.rb` writes
  `tmp/repo-trace-spec.json`. A Cucumber writer `features/support/repo_trace.rb`
  writes `tmp/repo-trace-bdd.json`. Both use schema `greeterhq.repo-trace.v1`
  with `repo` `greeter-http` and hold only slugs, statuses, locations and run
  metadata.
- Delete `features/support/traceability.rb` and the `traceability-report`
  artifact upload. The new writer replaces them.
- `bin/merge-repo-trace` merges the two files into `tmp/repo-trace.json`.
- `spec/trace_check_spec.rb` parses OpenSpec markdown directly (no Node, no
  OpenSpec CLI). It fails, naming the requirement and file, when a requirement
  has no tagged test, when a tag matches no heading, or when a scenario slug is
  not one of its requirement's scenarios.
- `ci.yml`:
  - the `functional` job runs RSpec with the formatter, then Cucumber, then
    merges the traces;
  - on push to `main` and weekly (`17 6 * * 1`) it uploads `repo-trace`
    (90 days);
  - a new `notify-docs` job sends `docs-refresh` to greeter-docs with
    `client_payload[repo]=greeter-http`;
  - top-level `permissions: contents: read` is added;
  - `concurrency` becomes group `ci-${{ github.event_name }}-${{ github.ref }}` with
    `cancel-in-progress` only for pull requests, so runs on `main` and weekly
    runs always finish and publish.

**OpenAPI description**

- `openapi.yaml` (OpenAPI 3.1) at the repo root describes `POST /greetings`
  exactly as the code returns it: statuses 200, 201, 400, 409, 413, 422, 500
  and 503, the `{guest_name, greeting, count, greeted_at}` success body (`count`
  is null when the counter is disabled), the `{error, message}` error body, the
  `Idempotency-Key` and `X-Greeter-Synthetic` request headers, `Retry-After` on
  503, and both version headers on every response. `info.version` equals
  `GreeterHttp::VERSION`.
- Test support wraps `GreeterHttp::App.build` (RSpec and Cucumber) with
  openapi_first's test wrapper, so every response of the composed app is
  validated against `openapi.yaml` and a mismatch raises, naming the operation
  and status. `lib/`, `exe/` and `infra/` do not reference openapi_first.
- A spec fails if `info.version` differs from `GreeterHttp::VERSION`.
- CI: on pull requests an `api-diff` job runs `oasdiff/oasdiff-action/breaking@v0`
  and fails on breaking changes. It is skipped only when the base branch has no
  `openapi.yaml`.
- The release tarball includes `openapi.yaml`, so later jobs (such as ZAP) use
  the released description.
- ADRs `docs/adr/0001-record-architecture-decisions.md` and
  `docs/adr/0002-openapi-authored-and-validated-not-generated.md`.

**Repos and code**

- Touches greeter-http only. greeter-core is not affected, and greeter-cli is
  only the reference implementation.
- `lib/` and `exe/` do NOT change. The HTTP contract is unchanged in Wave 1.

## Capabilities

### New Capabilities

- `live-docs-traceability`: slug rule, trace check, trace writers, merge, CI
  publication. Same capability name as in greeter-core and greeter-cli.
- `api-description`: the OpenAPI description, response validation, the version
  check, breaking-change detection and the release tarball.

### Modified Capabilities

None. `greeting-counter`, `version-headers` and `acceptance-gated-release` keep
their requirement and scenario text.

## Impact

- **Existing test files changed:**
  `features/greeting_counter.feature` (tag lines only) and
  `spec/security/http_security_spec.rb` (one added group, no removed lines).
  `features/support/traceability.rb` is deleted, as the brief asks. A scripted
  check (task 3.3) enforces this list. `spec/spec_helper.rb` and
  `features/support/env.rb` are not edited: RSpec loads the new support from
  `.rspec`, and Cucumber auto-loads `features/support/*.rb`.
- **Gemfile and lockfile:** `openapi_first ~> 4.4` in the `:test` group is
  already in the working tree (uncommitted) and ships with the red commit.
- **Other edited files:** `.github/workflows/ci.yml`, `.rspec`,
  `.rubocop.yml` (file-scoped exclusions), `.talismanrc` (checksums),
  `README.md`.
- **New files:** `openapi.yaml`, `bin/merge-repo-trace`, `docs/adr/`,
  `spec/support/` (slug, trace check, trace document, formatter,
  openapi_contract), `features/support/repo_trace.rb`,
  `features/support/openapi_contract.rb`, the tooling and contract specs, and
  fixtures under `spec/fixtures/`.
- **Needs the maintainer:** repo variable `DISPATCH_APP_CLIENT_ID` and secret
  `DISPATCH_APP_PRIVATE_KEY`, with the App installed on `greeter-docs`.
- Applying this change edits files under `spec/` and `features/`, so the
  maintainer runs `tests-open` for the red tests and for apply.
- Each release must bump `openapi.yaml` `info.version` in the same commit as
  `lib/greeter_http/version.rb`. A spec enforces this.

## Non-goals

- No change to `lib/`, `exe/`, `infra/` or greeter-core, and no change to the
  HTTP contract. Behaviour that the code does not have is not described:
  there is no 415, no 404 in the description, and no `replayed` field.
- `openapi_first` stays a test-group gem and never enters the Lambda bundle.
- No request validation in tests. Tests send invalid requests on purpose, so
  only responses are validated. Unrouted requests are not validated.
- No OpenAPI coverage reporting yet (`report_coverage` is off).
- No change to `cd.yml`, the acceptance gate or the existing requirement text.
- No generated documentation site, no SDK generation, and no greeter-docs
  changes.
- No `servers` entry: deployment URLs stay in the acceptance suite's
  configuration.
- No tag-only diff checker. The `greeting_counter.feature` edit is checked with
  a `git diff` filter.
