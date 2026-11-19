# Design

## Context

greeter-docs reads requirement slugs, test statuses and an OpenAPI description
for each repo. The slug rule, the trace-check rules and the
`greeterhq.repo-trace.v1` schema are shared across greeterHQ repos. greeter-cli's
`adopt-live-docs` (archived) is the reference implementation, and its support
code is copied here. This design follows it and adds what greeter-http needs:
a single `functional` CI job that runs both test tools, an existing RSpec tag
convention, and the OpenAPI description.

Current state that matters:

- `features/greeting_counter.feature` has one feature-level
  `@requirement-greeting-counter` tag (matches no heading) and 13 untagged
  scenarios. Their names equal the `greeting-counter` scenario headings.
- `spec/` already carries `requirement:`/`scenario:` metadata on the
  `version-headers` and `acceptance-gated-release` examples. Running greeter-cli's
  trace check against this tree reports exactly 20 problems: 7 untagged
  `greeting-counter` requirements and 13 untagged scenarios. Nothing else is
  missing or unknown.
- `features/support/traceability.rb` writes a bare array to
  `tmp/traceability.json`, and `functional` uploads it as `traceability-report`.
- `functional` runs RSpec, Cucumber, then the DynamoDB-local integration specs
  in one job. `release` runs only for `v*` tags. `cd.yml` runs only on the
  `deploy-release` dispatch. `bump-core` runs only on the
  `greeter-core-released` dispatch. There is no RubyGems publish job.
- `spec/spec_helper.rb` loads no `spec/support/**`. `.rspec` is
  `--require spec_helper` and `--format documentation`.
- `GreeterHttp::App.build` returns `Adapters::VersionHeaders` wrapping
  `Adapters::RackApp`. Responses are `[status, headers, body]` with lowercase
  header names. The success body is
  `{guest_name, greeting, count, greeted_at}`. `count` is null when
  `GREETER_COUNTER_ENABLED=false`. A replay differs from a first success only by
  status (`200` vs `201`). Errors are `{error, message}`.
- `spec/app_spec.rb` only tests backend selection and produces no responses.
  The responses come from `version_headers_spec`, `http_security_spec`,
  `lambda_handler_spec` and the Cucumber world, and all of them go through
  `App.build` or `App.build_handler`.

`lib/` and `exe/` do not change.

## Decisions

### Slug helper
`spec/support/repo_trace/slug.rb` defines `RepoTrace::Slug.call(text)`:
`text.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')`. No camel-case
splitting. `spec/tooling/slug_spec.rb` asserts a table of hand-written slugs for
headings chosen to hit each rule, then checks every real heading by property:

| Heading text | Slug |
|---|---|
| Greet a guest and return a running count | greet-a-guest-and-return-a-running-count |
| Replaying an idempotency key returns the original result | replaying-an-idempotency-key-returns-the-original-result |
| Names differing only by case or whitespace share a count | names-differing-only-by-case-or-whitespace-share-a-count |
| Gate ref and acceptance_ref must agree | gate-ref-and-acceptance-ref-must-agree |
| Hostile tag text is not echoed | hostile-tag-text-is-not-echoed |
| Surfaces control/escape characters as an error | surfaces-control-escape-characters-as-an-error |
| Clock#now raises NotImplementedError | clock-now-raises-notimplementederror |
| Completes #greet in under 5 ms at p99 | completes-greet-in-under-5-ms-at-p99 |
| Equal names agree across ==, eql?, hash, and uniq | equal-names-agree-across-eql-hash-and-uniq |
| Unrouted requests carry version headers | unrouted-requests-carry-version-headers |
| `"  --Leading and trailing!!  "` | leading-and-trailing |

For every real requirement and scenario heading in `openspec/specs/**` and the
in-flight change specs, the slug must match `\A[a-z0-9]+(-[a-z0-9]+)*\z` and be
unique among the headings of its level in its capability. This keeps tags
unambiguous without a hand-written row for each of the roughly 140 headings.

### Trace check
`spec/support/repo_trace/check.rb` defines
`RepoTrace::Check.call(spec_glob:, change_glob:, example_glob:, feature_glob:, exclude_glob: nil)`,
which returns problem strings. `spec/trace_check_spec.rb` runs it against
fixtures, plus one example on the real repo (`openspec/specs/**/spec.md`,
`openspec/changes/**/specs/**/spec.md`, `spec/**/*.rb`, `features/**/*.feature`,
excluding `spec/fixtures/**/*`).

- Headings: `^### Requirement:\s*(.+)$` and `^#### Scenario:\s*(.+)$`. A scenario
  belongs to the requirement above it.
- Change deltas: paths under `changes/archive/` are skipped. Only headings inside
  `## ADDED Requirements` and `## MODIFIED Requirements` count, and REMOVED and
  RENAMED are ignored. A slug in both a main spec and a MODIFIED delta combines
  their scenarios. Delta requirements need a tagged test too, so this change's
  own requirements are enforced before archive.
- RSpec tags are found by text, using
  `requirement:\s*'([^']+)',\s*scenario:\s*'([^']+)'`. Cucumber tags are found by
  text too: the tags of a scenario are the feature-level tags plus the tag lines
  above its `Scenario:` line. A scenario with a `@requirement-` or `@scenario-`
  tag needs exactly one of each. Untagged scenarios (the `@smoke` ones) are
  allowed.
- Requirement slugs match across all spec files. Scenario slugs match only within
  their requirement, and a scenario slug equal to its requirement's slug is valid.
- Problems:
  - `requirement "<slug>" (<spec.md>) has no tagged test`
  - `test tagged requirement "<slug>" (<file>:<line>) matches no requirement heading`
  - `test scenario "<slug>" (<file>:<line>) is not a scenario of requirement "<slug>"`
  - `scenario at <file>:<line> needs exactly one @requirement- and one @scenario- tag`
- Fixtures in `spec/fixtures/trace_check/`: `specs/`, `changes/in-flight-change/`
  (ADDED, MODIFIED, REMOVED and RENAMED sections), `changes/archive/...`,
  `examples/*.rb`, `features/*.feature` and `excluded/`.
- Rule for test data: values that look like tags (`requirement: '...'`,
  `@requirement-...`) must not appear in scanned files except as real tags. Test
  data that needs such values uses string keys or lives in `spec/fixtures/`.
  Comments in scanned files must not contain the literal tag form.

### Shared trace document
`spec/support/repo_trace/document.rb` defines `RepoTrace::Document`, used by both
writers and `bin/merge-repo-trace`. It is copied from greeter-cli with `REPO` set
to `greeter-http`.

- `result(requirement:, scenario:, status:, source:, location:)` validates each
  value, and `header(sha:, run_id:, recorded_at:)` validates the run metadata.
  `validate(document)` checks a parsed document in full.
- Patterns:
  - slug: `\A[a-z0-9]+(?:-[a-z0-9]+)*\z`
  - rspec location: `\Aspec(?:/[\w-][\w.-]*)+\.rb:[1-9]\d*\z`
  - cucumber location: `\Afeatures(?:/[\w-][\w.-]*)+\.feature:[1-9]\d*\z`
  - sha: `\A[0-9a-f]{40}\z`
  - run_id: `\A\d+\z` or nil
  - recorded_at: `\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z`
  - schema exactly `greeterhq.repo-trace.v1`, repo exactly `greeter-http`
  - status one of `passed|failed|pending|skipped`
- Every path segment starts with a word character or `-`, so `.`, `..`, empty
  segments and absolute paths are rejected (S8).
- A violation raises a message starting `invalid <field>`. It never echoes the
  value, and nothing is written.
- `sha` is `GITHUB_SHA`, else `git rev-parse HEAD` (an argv array, no shell).
  `run_id` is `GITHUB_RUN_ID` or nil. `recorded_at` is the UTC time to the second.
- Results with the same requirement, scenario and location collapse to the worst
  status (failed, pending, skipped, passed). Results are sorted by file, line,
  requirement, scenario. Parent directories are created.

### RSpec formatter
`spec/support/repo_trace_formatter.rb` defines `RepoTraceFormatter`, registered
for `:example_passed, :example_failed, :example_pending, :close`. It records each
example that has both `requirement` and `scenario` metadata (inherited from
groups). RSpec reports `skip` and `pending` as `:example_pending`, so a truthy
`metadata[:skip]` maps to `skipped` and anything else to `pending`. It reads only
the slug metadata, the status and the location, never descriptions or
exceptions. The path is `ENV['REPO_TRACE_PATH']`, default
`tmp/repo-trace-spec.json`. `.rspec` gains `--require ./spec/support/repo_trace_formatter`,
and the formatter writes only when selected with `--format RepoTraceFormatter`.
The integration run in `functional` does not select it, so it never overwrites
the trace.

`spec/tooling/repo_trace_formatter_spec.rb` runs fixture example files
(`spec/fixtures/repo_trace/*.rb`) in a subprocess with `--options /dev/null` and
`REPO_TRACE_PATH` in a temp dir, then reads the JSON. The fixture descriptions
contain `Alice Smith` on purpose.

### Cucumber writer
`features/support/repo_trace.rb` requires the shared document. An `After` hook
records each scenario with exactly one `@requirement-` and one `@scenario-` tag,
reading only the tags, the status and the location. An `AfterAll` hook writes
`ENV['REPO_TRACE_PATH']`, default `tmp/repo-trace-bdd.json`, once. Status mapping:
`passed` and `failed` as is, `pending` and `undefined` to `pending`, `skipped`
to `skipped`. The `@smoke` scenarios are skipped without `GREETER_BASE_URL`, so
they appear as `skipped`. A malformed value prints the field on stderr (the
progress formatter hides hook errors), raises, and writes nothing.

`features/support/traceability.rb` is deleted. `spec/tooling/cucumber_repo_trace_spec.rb`
runs fixture features from `spec/fixtures/repo_trace_cucumber/` in a subprocess.

### Merge script
`bin/merge-repo-trace OUT IN_A IN_B` (stdlib only, `# frozen_string_literal: true`,
copied from greeter-cli). It validates both inputs in full before comparing them,
fails with exit 1 and one line on stderr, writing nothing, when `schema`,
`repo`, `sha` or `run_id` differ, an input is outside the v1 shape, or a result is
in both inputs. Otherwise it writes the shared fields, the later `recorded_at`
and all results, sorted. It uses `JSON.parse`, never `JSON.load`.

Here both files come from the same job, so the merge is a step, not a job. It
still matters because greeter-docs gets one file, and because the merge checks
that the two writers agree on `sha` and `run_id`.

### openapi.yaml
OpenAPI 3.1, at the repo root, authored by hand (ADR 0002). Shape:

- `info`: `title: greeter-http`, `version: '0.5.21'` (`GreeterHttp::VERSION`).
  No `servers`.
- One path, `/greetings`, with `post` (`operationId: createGreeting`).
- Parameters: `Idempotency-Key` (header, required, `type: string`,
  `minLength: 1`, no `format`) and `X-Greeter-Synthetic` (header, optional,
  string). `RackApp` rejects only a missing or empty key (the
  `key.nil? || key.empty?` check in `rack_app.rb`), so the schema says exactly
  that. The description text says clients should send a UUID.
- Request body: required `application/json` object with required string `name`.
- Responses `201` (a new greeting) and `200` (a replay of a recorded request;
  the description says so). Both use schema `Greeting`: required
  `guest_name`, `greeting` (strings), `count` (`type: [integer, 'null']`,
  `minimum: 1`) and `greeted_at` (`format: date-time`), with
  `additionalProperties: false`.
- Responses `400`, `409`, `413`, `422`, `500` and `503` use schema `Error`:
  required `error` and `message`, `additionalProperties: false`, with a per-status
  `error` enum (400: `missing_idempotency_key`, `malformed_request`; 409:
  `idempotency_key_reused`; 413: `payload_too_large`; 422: `invalid_name`; 500:
  `internal_error`; 503: `temporarily_unavailable`). `503` adds a required
  `Retry-After` header.
- Every response lists required `X-Greeter-Version` and `X-Greeter-Core-Version`
  headers through `components/headers`.
- No `404`, `415` or `default`. A request the router does not route is not part of
  the API (see Decisions).

`spec/openapi_description_spec.rb` loads the file and asserts each scenario of the
requirement, and compares `info.version` with `GreeterHttp::VERSION`. The version
comparison is a function in `spec/support/openapi_contract.rb`, so a fixture file
can prove it fails.

### Response validation (test support only)
`spec/support/openapi_contract.rb` defines `OpenapiContract`. `lib/`, `exe/` and
`infra/` never reference `openapi_first`.

- `OpenapiContract.install` is idempotent. It calls
  `OpenapiFirst::Test.setup` once and registers `openapi.yaml`, with:
  - `ignore_request_error { true }`, because tests send invalid requests on
    purpose and only responses are validated;
  - `ignored_unknown_status = []`. The gem's default is `[401, 404, 500]`, and any
    response with one of those statuses is never raised. That would hide 500
    mismatches, and 500 is documented here;
  - `report_coverage = false`, so the gem's 100 % coverage gate does not exit the
    process with status 2.
- A module `OpenapiContract::Build` is prepended to
  `GreeterHttp::App.singleton_class`. Its `build(...)` calls `super` and wraps the
  result with `OpenapiContract::Checked`. `build_handler` and `build_from_env`
  call `build`, so every composed app is wrapped. Apps built directly from
  `RackApp` or `VersionHeaders` (such as the logging spec and the version-header
  stub specs) are deliberately not wrapped.
- `Checked#call` delegates to `OpenapiFirst::Test.app(app)`, whose silent
  validation raises `OpenapiFirst::ResponseInvalidError` on a mismatch. `Checked`
  rescues it and raises `OpenapiContract::Mismatch`, with a message that starts
  `POST /greetings status <status>:` followed by the gem's message. That names the
  operation and the status.
- `OpenapiFirst` skips response validation for a request that matches no
  operation (no path, a method the path does not define, or a content type the
  operation does not define). So `GET /nope`, `GET /greetings` and a POST without
  a JSON content type are not validated, which is what the brief asks for.
- RSpec loads it from `.rspec` (`--require ./spec/support/openapi_contract`,
  after `spec_helper`), and the file calls `install` when it is required, so
  `spec/spec_helper.rb` is not edited. Cucumber loads it from
  `features/support/openapi_contract.rb`, which Cucumber auto-loads, so
  `features/support/env.rb` is not edited either. A spec asserts that the
  Cucumber file exists and requires the shared support, so Cucumber cannot lose
  the hook silently.
- `spec/tooling/openapi_contract_spec.rb` wraps small Rack apps with fixed
  responses (`spec/fixtures/openapi/`) to prove: a described response passes, an
  undocumented status, an extra field, a string `count` and a missing version
  header each fail naming the operation and status, and `GET /nope` passes
  through unchanged.
- The bundle boundary is checked in two places: a spec in
  `spec/security/http_security_spec.rb` (`git grep -n openapi_first -- lib exe infra`
  finds nothing, and the `Gemfile` declares the gem only in the `:test` group), and
  a `release` job step after `sam build` that fails if `.aws-sam/build` contains an
  `openapi_first-*` directory. The `Gemfile` entry already uses `group: :test`.

### CI (`ci.yml`)
- `on:` gains `schedule: - cron: '17 6 * * 1'`. The existing `repository_dispatch`
  and tag triggers are unchanged.
- `concurrency` becomes
  `group: ci-${{ github.event_name }}-${{ github.ref }}` and
  `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`. A superseded
  pull request run is still cancelled. A push to `main`, a weekly run and a
  dispatch run are never cancelled, so they always finish and publish. The event
  name in the group also stops a pull request run and a push run for the same
  ref from cancelling each other. `ci_workflow_spec` asserts both values.
- Top-level `permissions: contents: read`. Only `release` (`contents: write`) and
  `bump-core` (`contents: write`, `pull-requests: write`) keep their own grants.
- The publish gate, shared by the upload step and `notify-docs`, is
  `github.event_name == 'schedule' || (github.event_name == 'push' && github.ref == 'refs/heads/main')`.
  It excludes pull requests, tag pushes and `repository_dispatch`.
- `functional`:
  - RSpec runs as
    `bundle exec rspec --format progress --format html --out coverage/rspec.html --format RepoTraceFormatter`
    with `REPO_TRACE_PATH: tmp/repo-trace-spec.json`.
  - Cucumber runs with `REPO_TRACE_PATH: tmp/repo-trace-bdd.json`.
  - A "Merge traces" step runs
    `bin/merge-repo-trace tmp/repo-trace.json tmp/repo-trace-spec.json tmp/repo-trace-bdd.json`
    after both test steps, on every event, so a bad trace fails pull requests too.
  - An "Upload repo trace" step, with `if: <gate>`, uploads `tmp/repo-trace.json`
    as `repo-trace` with `retention-days: 90` and `if-no-files-found: error`. It
    uses the default success condition, so a red run uploads nothing.
  - The `traceability-report` upload is removed.
- `notify-docs`: `needs: functional`, `if: <gate>`, `permissions: {}`. Steps:
  `actions/create-github-app-token@v3` with
  `client-id: ${{ vars.DISPATCH_APP_CLIENT_ID }}`,
  `private-key: ${{ secrets.DISPATCH_APP_PRIVATE_KEY }}`, `owner: greeterhq`,
  `repositories: greeter-docs` and `permission-contents: write`, with no
  `skip-token-revoke`, then, directly after it,
  `gh api repos/greeterhq/greeter-docs/dispatches -f event_type=docs-refresh -f client_payload[repo]=greeter-http`
  with `GH_TOKEN` from the step output in `env:`. No fallback if the credentials
  are missing.
- `api-diff`: `if: github.event_name == 'pull_request'`,
  `permissions: {contents: read}`. Steps: `actions/checkout@v5` with
  `fetch-depth: 0` and `persist-credentials: false`; a step that sets output
  `present` by running `git cat-file -e "origin/${BASE_REF}:openapi.yaml"`, with
  `BASE_REF: ${{ github.base_ref }}` in `env:`; then
  `oasdiff/oasdiff-action/breaking@v0` with `if: steps.<id>.outputs.present == 'true'`,
  `base: 'origin/${{ github.base_ref }}:openapi.yaml'`,
  `revision: 'HEAD:openapi.yaml'`, `fail-on: ERR` and `review: false`. The
  comparison is skipped only when the base has no `openapi.yaml`, which is the
  pull request that first adds it. `review: false` keeps the description off
  oasdiff.com.
- `release`: before `tar`, the packaging step copies `openapi.yaml` into
  `dist/${pkg}/`. After `sam build`, a check step fails if
  `.aws-sam/build` contains an `openapi_first-*` directory.
- A scheduled run starts `lint`, `functional`, `spec-gate`, `perf` and
  `security` (no `repository_dispatch` guard applies to it). `release` needs a
  `refs/tags/v` ref, so it skips, and `cd.yml` only follows the `deploy-release`
  dispatch, so nothing is released or deployed.
- `spec/workflows/ci_workflow_spec.rb` parses `ci.yml` and `cd.yml` with
  `YAML.safe_load_file` (`"on"` is quoted, so the key loads as a string) and
  asserts everything above. It also runs the `functional` job's rspec command
  with `--dry-run` to prove `RepoTraceFormatter` resolves and examples are
  selected.

### Tagging existing tests
Only `features/greeting_counter.feature` changes. The feature-level
`@requirement-greeting-counter` line is deleted, and each scenario gets one tag
line. The `# Requirement:` comments and the scenario names stay.

| Scenario | `@requirement-` | `@scenario-` |
|---|---|---|
| First greeting for a new guest | greet-a-guest-and-return-a-running-count | first-greeting-for-a-new-guest |
| Subsequent greeting for an existing guest | greet-a-guest-and-return-a-running-count | subsequent-greeting-for-an-existing-guest |
| Names differing only by case or whitespace share a count | greet-a-guest-and-return-a-running-count | names-differing-only-by-case-or-whitespace-share-a-count |
| Empty name is rejected | reject-invalid-guest-names | empty-name-is-rejected |
| Over-long name is rejected | reject-invalid-guest-names | over-long-name-is-rejected |
| Missing idempotency key is rejected | require-a-client-supplied-idempotency-key | missing-idempotency-key-is-rejected |
| Retry with the same key does not double-count | replaying-an-idempotency-key-returns-the-original-result | retry-with-the-same-key-does-not-double-count |
| Replay returns the original count even after other greetings | replaying-an-idempotency-key-returns-the-original-result | replay-returns-the-original-count-even-after-other-greetings |
| Replay is distinguishable from a first success by status | replaying-an-idempotency-key-returns-the-original-result | replay-is-distinguishable-from-a-first-success-by-status |
| Same key with a different guest is rejected | reject-reuse-of-an-idempotency-key-for-a-different-request | same-key-with-a-different-guest-is-rejected |
| Reused key counts again after the retention window | forget-idempotency-keys-after-a-bounded-window | reused-key-counts-again-after-the-retention-window |
| Deduplication spans multiple retained keys | forget-idempotency-keys-after-a-bounded-window | deduplication-spans-multiple-retained-keys |
| Storage throttling yields a retryable response | report-transient-storage-failures-as-retryable | storage-throttling-yields-a-retryable-response |

The tag-only property is checked by a script (task 3.3), run from the repo root
after the commits, and its command and output are recorded in `tasks.md`:

```bash
# 1. The existing test files that change are exactly these; every other file
#    under spec/ and features/ is new (A).
git diff --name-status origin/main -- spec features | grep -v '^A'
#    expect: M features/greeting_counter.feature
#            M spec/security/http_security_spec.rb
#            D features/support/traceability.rb

# 2. In greeting_counter.feature every added line holds only tags, and the one
#    removed line is the old feature-level tag.
git diff --unified=0 origin/main -- features/greeting_counter.feature \
  | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
  | grep -vE '^\+\s*(@\S+\s*)+$' | grep -vxE '^-@requirement-greeting-counter\s*'
#    expect: no output

# 3. http_security_spec.rb gets additions only.
git diff --unified=0 origin/main -- spec/security/http_security_spec.rb \
  | grep -E '^-' | grep -vE '^---'
#    expect: no output
```

The other two capabilities need no new tags: their examples already carry
`requirement:`/`scenario:` metadata, and the trace check confirms every heading
is covered. The new capabilities' own specs are tagged as they are written.

### RuboCop
`.rubocop.yml` already disables most RSpec cops this change would trip
(`DescribeClass`, `ExampleLength`, `MultipleExpectations`,
`MultipleMemoizedHelpers`). It gains file-scoped exclusions only, each with a
comment, for what remains: `RSpec/SpecFilePathSuffix`,
`RSpec/IdenticalEqualityAssertion` and `RSpec/ExpectActual` under
`spec/fixtures/**/*`, and any Metrics cop the copied support files trip. The
exact list is confirmed when RuboCop runs.

### ADRs
`docs/adr/0001-record-architecture-decisions.md` and
`docs/adr/0002-openapi-authored-and-validated-not-generated.md`, MADR style, each
with `Status`, `Context`, `Decision` and `Consequences` headings.

- 0001: decisions that shape the repo are recorded as numbered Markdown files in
  `docs/adr/`, one per decision, never edited after acceptance except for status.
- 0002: Rack has no route introspection, so the description cannot be generated.
  It is written by hand, every response the composed app produces in tests is
  validated against it (openapi_first, test group only), and oasdiff blocks
  breaking changes on pull requests. Consequences: the description can lag in
  paths no test exercises, the version must be bumped with `VERSION`, and the
  gem never enters the Lambda bundle.

`spec/docs/adr_spec.rb` checks that both files exist, are numbered, and have the
four headings. It verifies no OpenSpec scenario, so it is not tagged.

## Security considerations

| # | Finding | Resolution |
|---|---|---|
| S1 | greeter-docs renders trace values. Tags and the env-supplied sha and run_id are free text, so "no guest names" depends on never writing arbitrary strings. | Both writers and the merge validate every value against fixed patterns and write nothing on a violation. Messages never echo values. |
| S2 | The App token could carry every permission the App holds on greeter-docs. | `owner: greeterhq`, `repositories: greeter-docs`, `permission-contents: write` only, no `skip-token-revoke`, minted in the step directly before use. `ci_workflow_spec` asserts each. |
| S3 | Expressions interpolated into `run:` are the usual workflow injection route. | `notify-docs`, the trace steps and `api-diff` have no `${{` in `run:`. The base ref reaches the script through `env`, and the token only as `GH_TOKEN`. |
| S4 | Without top-level `permissions`, jobs get the repository default token, which may be write-all. | Top-level `contents: read`. Only `release` and `bump-core` grant write, `notify-docs` has `{}`. |
| S5 | Artifacts must come from the same run and only after a green run. | The upload is a step in `functional`, after the tests, with the default success condition. No cross-job download. |
| S6 | Pull requests and forks. | The publish gate excludes `pull_request`. `api-diff` has `contents: read`, no secrets, `review: false` (nothing is uploaded to oasdiff.com), and the action's `allow-external-refs` stays at its safe default. |
| S7 | `create-github-app-token@v3` and `oasdiff-action/breaking@v0` are referenced by mutable tag. | Kept as requested. SHA pinning belongs to `add-dependency-scanning`. |
| S8 | Location patterns that accept `..` could point greeter-docs outside the repo. | Each path segment must start with `[\w-]`, and the line is at least 1. Writers and merge share the patterns. |
| S9 | The merge could publish two inputs that agree on a malformed value. | It validates `schema`, `repo`, `sha`, `run_id` and `recorded_at` in each input before comparing them. |
| S10 | A test-only gem in the Lambda bundle enlarges the attack surface of the deployed function. | `openapi_first` is only in the `:test` group. A security spec and a `release` check fail on any reference in `lib`, `exe`, `infra` or the built bundle. |
| S11 | `openapi.yaml` is published in the tarball and read by greeter-docs. | No `servers`, no real hostnames, no secrets, and only invented example names. |
| S12 | The "no guest data" guarantee covers `repo-trace` only. `simplecov-report` (`coverage/rspec.html`) holds RSpec descriptions. | No change. Tests use sample names only. |
| S13 | Consumer side: greeter-docs treats `client_payload[repo]` and the trace as untrusted input. | Out of scope here. The greeter-docs change that consumes `docs-refresh` should allowlist repo names, never use payload or trace values in paths or shell, validate the schema, and cap size. |
| S14 | New test dependencies (`openapi_first`, `json_schemer` and others) add supply-chain surface in CI. | `bundler-audit` already runs in the `security` job. The gems are test-only and pinned by `Gemfile.lock`. |

## Risks / trade-offs

- A regex scan can be fooled by tag text in a comment or string. Accepted: it is
  simple and needs no Node or CLI. See the test-data rule above.
- `OpenapiFirst` skips validation for requests that match no operation, so a
  `POST /greetings` without a JSON content type is not validated. All existing
  specs and features send `application/json`.
- `openapi.yaml` can lag behind the code for paths no test exercises. Coverage
  reporting is off in this change and is a follow-up.
- Every release now needs two version edits (`version.rb` and `openapi.yaml`).
  The version spec fails the build when they differ, and `release` already checks
  the tag against `VERSION`.
- `notify-docs` fails until the credentials and the App installation exist.
- The trace code (`spec/support/repo_trace/*`, the formatter, the Cucumber
  writer and `bin/merge-repo-trace`) is copied from greeter-cli, not shared, so
  the copies can drift. The shared `greeterhq.repo-trace.v1` schema is the
  contract between the repos and greeter-docs, and each copy is tested against
  it. Merging the copies is out of scope for Wave 1.

## Decisions

- **415 is not described.** The service never returns it, and the HTTP contract
  does not change in Wave 1.
- **No `replayed` field.** The body is described exactly as the code returns it.
  `201` is a new greeting and `200` is a replay, and the `200` description says
  so. `count` is nullable (null when `GREETER_COUNTER_ENABLED=false`).
- **500 is described** with `internal_error`, the version headers and the
  `{error, message}` body. Every error response (400, 409, 413, 422, 500, 503)
  uses that body, and 503 also has `Retry-After`. 404 is not described, because
  it only happens on undocumented paths.
- **Response validation never touches `lib/`.** It lives in `spec/support` and
  `features/support`, prepended to `GreeterHttp::App`'s singleton class, because
  `openapi_first` is a test-group gem and is not in the Lambda bundle.
- **Scope of coverage:** every requirement in `openspec/specs`: 7
  `greeting-counter`, 10 `version-headers` and 10 `acceptance-gated-release`,
  plus this change's own. There is no `ports` capability here.
- **`client_payload[repo]` is `greeter-http`.** The Cucumber trace uses
  `source: cucumber` and `features/<file>:<line>` locations.
- **Two new flat capabilities**, matching this repo's layout:
  `live-docs-traceability` and `api-description`.
- **One `functional` job** writes both traces and merges them with
  `bin/merge-repo-trace`.
- **Top-level `permissions: contents: read`** in `ci.yml`.
- **oasdiff is skipped only when the base branch has no `openapi.yaml`.**
- **`Idempotency-Key` is `type: string`, `minLength: 1`, with no `format`.** The
  brief's `format: uuid` was wrong: `RackApp` rejects only a missing or empty
  key. The description says clients should send a UUID.
- **Runs on `main` and weekly runs always finish.** `concurrency` is
  `ci-<event>-<ref>`, cancelling only for pull requests. A spec checks both values.
- **The tag-only check is a script, not a visual check.** Only
  `features/greeting_counter.feature` may change by tags: its added lines must
  hold only tags (`^\+\s*(@\S+\s*)+$`). The one removed line is the old
  feature-level `@requirement-greeting-counter` tag, which cannot stay because
  every scenario would inherit it and the trace check requires exactly one
  requirement tag. The security spec gets additions only, and
  `features/support/traceability.rb` is deleted, as the brief asks.
- **Copied trace code is accepted for Wave 1.** See the risk above.
- **`.talismanrc` at commit time:** add checksum entries only for files
  Talisman actually flags, and remove entries for deleted files.
- **The throwaway `api-diff` pull request** is closed without merging and its
  branch deleted. Its failing run URL is recorded in task 3.7.
- **The old `traceability.rb` and `traceability-report` are removed**, per the
  brief. This differs from greeter-cli, which kept them.
- **Tests open for apply.** The maintainer runs `tests-open` for the red tests and
  the apply, and `tests-close` after each. The `Gemfile` and `Gemfile.lock`
  changes (`openapi_first ~> 4.4`, `:test` group) are in the working tree and go
  in the red commit. The change branch `change/adopt-live-docs` already exists.

## Assumptions

- Features use idempotency keys such as `K1`. They satisfy `minLength: 1`, and no
  request validation runs in tests anyway.
- Duplicate results inside one writer collapse to the worst status, and the
  merge keeps the later `recorded_at`.
