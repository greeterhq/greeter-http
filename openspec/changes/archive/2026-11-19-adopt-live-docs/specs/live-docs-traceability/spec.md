## ADDED Requirements

### Requirement: Every requirement has a tagged test
Every `### Requirement:` heading SHALL be covered by at least one RSpec example
tagged `requirement: '<slug>'` or one Cucumber scenario tagged
`@requirement-<slug>`. A slug is the heading text lowercased, with each run of
characters other than a-z and 0-9 replaced by one `-` and `-` trimmed from both
ends. Scenario slugs come the same way from `#### Scenario:` headings.

#### Scenario: Slug rule turns headings into slugs
- **WHEN** the slug function is given the headings in the slug table (for example `Greet a guest and return a running count`, `Surfaces control/escape characters as an error`, `Gate ref and acceptance_ref must agree`, `Clock#now raises NotImplementedError`, `Equal names agree across ==, eql?, hash, and uniq`, `"  --Leading and trailing!!  "`) and every real requirement and scenario heading in this repo
- **THEN** it returns `greet-a-guest-and-return-a-running-count`, `surfaces-control-escape-characters-as-an-error`, `gate-ref-and-acceptance-ref-must-agree`, `clock-now-raises-notimplementederror`, `equal-names-agree-across-eql-hash-and-uniq`, `leading-and-trailing` for the examples, and a string of only lowercase letters, digits and single hyphens, unique within its capability, for every real heading

#### Scenario: Requirement with no tagged test fails and is named
- **WHEN** the trace check runs against a fixture `spec.md` containing a requirement that no RSpec example or Cucumber scenario is tagged with
- **THEN** rspec fails with a message naming that requirement's slug and the fixture file

#### Scenario: Greeting-counter scenarios are tagged one to one
- **WHEN** `features/greeting_counter.feature` is read
- **THEN** each of its 13 scenarios has exactly one `@requirement-<slug>` and one `@scenario-<slug>` tag matching a `greeting-counter` heading, all seven requirements are covered, and the feature has no feature-level `@requirement-` tag

### Requirement: Tagged tests must match a requirement and scenario
A test whose requirement slug matches no known requirement, or whose scenario
slug is not a scenario of its requirement, SHALL fail the suite, naming the
slug and the test's file. Known headings come from main specs and from the
ADDED and MODIFIED sections of non-archived changes. Tags are read from
`spec/**/*.rb` and `features/**/*.feature`, excluding `spec/fixtures/**`.

#### Scenario: Unknown requirement slug fails and is named
- **WHEN** the trace check runs with an RSpec example, and separately a Cucumber scenario, tagged with the requirement slug `no-such-requirement`
- **THEN** rspec fails with a message naming `no-such-requirement` and the test's file and line

#### Scenario: Scenario slug is matched only within its requirement
- **WHEN** the trace check runs with a test whose scenario slug exists only under a different requirement, and another whose scenario slug equals its own requirement's slug
- **THEN** it fails naming the first test's scenario, requirement and file, and reports no problem for the second

#### Scenario: Requirements in in-flight changes are known
- **WHEN** a test is tagged with a requirement or scenario found only in an ADDED or MODIFIED section of a change that is not archived, or only in an archived change, or only in a REMOVED or RENAMED section
- **THEN** the first is known and reports no problem, and the others are reported as unknown with the test's file and line

#### Scenario: Fixture files are not scanned
- **WHEN** the trace check runs on the real repo, where `spec/fixtures/**` contains tags naming unknown requirements
- **THEN** it reports no problem caused by those fixture tags, and none for any real file

### Requirement: Repo trace contains only slugs, statuses, locations and run metadata
The RSpec formatter and the Cucumber writer SHALL each write a
`greeterhq.repo-trace.v1` file with one result per test tagged with both a
requirement and a scenario. Neither SHALL write descriptions, scenario names,
step text, failure messages or any field outside the schema, because those can
contain guest names.

#### Scenario: Formatter writes the v1 document
- **WHEN** a suite with one passing and one failing tagged example is run with the RSpec formatter
- **THEN** the file `tmp/repo-trace-spec.json` has `schema` `greeterhq.repo-trace.v1`, `repo` `greeter-http`, `sha` (`GITHUB_SHA` or `git rev-parse HEAD`), `recorded_at` (UTC ISO 8601), `run_id` (`GITHUB_RUN_ID` or `null`), and two `results` with statuses `passed` and `failed`, `source` `rspec`, and `spec/...rb:LINE` locations

#### Scenario: Cucumber writer writes the v1 document
- **WHEN** a fixture feature with one passing and one failing tagged scenario is run with the Cucumber writer
- **THEN** the file `tmp/repo-trace-bdd.json` has the same top-level fields and two `results` with statuses `passed` and `failed`, `source` `cucumber`, and `features/<file>:<line>` locations pointing at each `Scenario:` line

#### Scenario: Skipped and pending are told apart
- **WHEN** an RSpec example marked `skip` and one marked `pending` are run with the formatter, and a Cucumber scenario with a pending step and one whose steps are skipped (such as a `@smoke` scenario without `GREETER_BASE_URL`) are run with the writer
- **THEN** each result has status `skipped` or `pending` to match

#### Scenario: Writers refuse malformed values
- **WHEN** a tagged test has a requirement or scenario value that is not a lowercase slug, a location with a `.`, `..` or empty path segment, or the environment supplies a `GITHUB_SHA` that is not 40 hex characters or a `GITHUB_RUN_ID` that is not digits
- **THEN** the writer raises an error naming the field, without echoing the value, and writes no file

#### Scenario: Writers omit descriptions
- **WHEN** a tagged RSpec example whose description contains `Alice Smith`, and a tagged Cucumber scenario whose name and step text contain `Alice Smith`, are recorded
- **THEN** neither written file contains `Alice Smith`, and each result has exactly the keys `requirement`, `scenario`, `status`, `source`, `location`

### Requirement: The RSpec and Cucumber traces merge into one trace
`bin/merge-repo-trace` SHALL merge the RSpec and Cucumber trace files into one
`greeterhq.repo-trace.v1` file that contains every result from both. It SHALL
fail and write nothing when the inputs differ in `schema`, `repo`, `sha` or
`run_id`, or when the same result appears in both.

#### Scenario: Merge combines both traces
- **WHEN** an RSpec trace and a Cucumber trace with the same schema, repo, sha and run_id and disjoint results are merged
- **THEN** the output has the same schema, repo, sha and `run_id`, the later of the two `recorded_at` values, and all results from both files

#### Scenario: Merge rejects mismatched inputs
- **WHEN** the two files differ in `schema`, `repo`, `sha` or `run_id` (including one `null` and one non-null `run_id`)
- **THEN** the merge exits non-zero with a message naming the differing field and writes no output file

#### Scenario: Merge rejects inputs outside the v1 shape
- **WHEN** an input has an unknown top-level key, a `schema` other than `greeterhq.repo-trace.v1`, a `repo` other than `greeter-http`, a `sha`, `run_id` or `recorded_at` that does not match its pattern (even when both inputs agree), a result with an extra key, a `status` outside `passed|failed|pending|skipped`, a `source` other than `rspec` or `cucumber`, or a requirement, scenario or location that does not match its pattern for that source
- **THEN** the merge exits non-zero naming the file and field and writes no output file

#### Scenario: Merge rejects a duplicated result
- **WHEN** the same requirement, scenario and location appear in both files
- **THEN** the merge exits non-zero with a message naming that requirement and location and writes no output file

### Requirement: CI publishes the trace on main and weekly
CI SHALL run RSpec with the formatter and then Cucumber in the `functional`
job on every push and pull request, and merge the two traces. Only on push to
`main` and on the weekly schedule SHALL CI upload the merged trace as artifact
`repo-trace` and send `repository_dispatch` `docs-refresh` to
`greeterhq/greeter-docs`. A failed `functional` job SHALL publish no trace and
send no dispatch.

#### Scenario: Functional job writes and merges both traces
- **WHEN** `.github/workflows/ci.yml` is parsed
- **THEN** `functional` runs rspec with `--format RepoTraceFormatter` and `REPO_TRACE_PATH=tmp/repo-trace-spec.json`, runs cucumber with `REPO_TRACE_PATH=tmp/repo-trace-bdd.json`, and then runs `bin/merge-repo-trace tmp/repo-trace.json` on both files, on every event that runs `functional`

#### Scenario: Trace is uploaded only on main and weekly
- **WHEN** `.github/workflows/ci.yml` is parsed
- **THEN** the schedule is `17 6 * * 1`, and the `functional` step that uploads `repo-trace` runs only after the tests passed and only when `github.event_name == 'schedule' || (github.event_name == 'push' && github.ref == 'refs/heads/main')`, with `retention-days: 90` and `if-no-files-found: error`

#### Scenario: Notify-docs dispatches docs-refresh
- **WHEN** `.github/workflows/ci.yml` is parsed
- **THEN** `notify-docs` has `needs: functional`, `permissions: {}`, the same gate, a token from `actions/create-github-app-token@v3` (client-id `vars.DISPATCH_APP_CLIENT_ID`, private-key `secrets.DISPATCH_APP_PRIVATE_KEY`, owner `greeterhq`, repositories `greeter-docs`), and a `docs-refresh` dispatch with `client_payload[repo]=greeter-http`

#### Scenario: Workflow credentials are least-privilege
- **WHEN** `.github/workflows/ci.yml` is parsed
- **THEN** the top-level `permissions` is exactly `{contents: read}`, only `release` and `bump-core` grant `write`, `notify-docs` has `permissions: {}`, the mint step requests only `permission-contents: write`, does not set `skip-token-revoke` and is directly before the dispatch step, the app token reaches `gh` only as `GH_TOKEN` in `env`, and no `run:` step of `notify-docs` or of the trace steps contains a `${{` expression

#### Scenario: Runs on main and weekly runs always finish
- **WHEN** `.github/workflows/ci.yml` is parsed
- **THEN** `concurrency.group` is `ci-${{ github.event_name }}-${{ github.ref }}` and `concurrency.cancel-in-progress` is `${{ github.event_name == 'pull_request' }}`, so only a superseded pull request run is cancelled and a run on `main`, a weekly run and a dispatch run always finish and publish

#### Scenario: Scheduled run creates no release or deployment
- **WHEN** `.github/workflows/ci.yml` and `.github/workflows/cd.yml` are parsed
- **THEN** the publish gate excludes pull requests, tag pushes and `repository_dispatch`, `release` runs only for a `v*` tag ref, `bump-core` runs only for `repository_dispatch`, and `cd.yml` runs only on the `deploy-release` dispatch

#### Scenario: The old traceability report is gone
- **WHEN** `features/support/` and `.github/workflows/ci.yml` are inspected
- **THEN** `features/support/traceability.rb` does not exist, and no job uploads `traceability-report` or `tmp/traceability.json`
