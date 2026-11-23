## ADDED Requirements

### Requirement: A scheduled prod smoke publishes a trace
`.github/workflows/smoke-prod.yml` SHALL be the only workflow that publishes
prod smoke evidence. It SHALL run the `@smoke` Cucumber scenarios against the
committed prod base URL, fail unless the trace records
`deployed-stage-exposes-version-headers` as `passed`, and only then upload the
trace as artifact `repo-trace-smoke-prod`. It SHALL hold no credentials beyond
a read-only `GITHUB_TOKEN`.

#### Scenario: Smoke runs daily, on demand and after CD
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** its triggers are exactly `schedule` with the single cron `17 6 * * *`, `workflow_dispatch`, and `workflow_run` with `workflows: [CD]` and `types: [completed]`

#### Scenario: Job runs only on main and skips a failed CD run
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** the workflow has exactly one job, and its `if` is `github.ref == 'refs/heads/main' && (github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success')`

#### Scenario: Workflow holds no credentials
- **WHEN** `.github/workflows/smoke-prod.yml` is read
- **THEN** the top-level `permissions` is exactly `{contents: read}`, no job declares `permissions`, the file contains no `secrets.` or `vars.` reference, no step uses an `aws-actions/` action or runs `aws` or `sam`, and the only `github.event.` reference in the file is `github.event.workflow_run.conclusion`, inside the job `if`

#### Scenario: Base URL is the committed prod endpoint
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** the top-level `env.GREETER_BASE_URL` is exactly `https://dhsuw1brrc.execute-api.eu-west-2.amazonaws.com`, and no job or step overrides it

#### Scenario: Smoke checks out the triggering commit
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** the first step uses `actions/checkout@v5` with no `ref` input and with `persist-credentials: false`, and the next step uses `ruby/setup-ruby@v1` with `bundler-cache: true`

#### Scenario: Cucumber runs only smoke scenarios and writes the trace
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** exactly one step runs `bundle exec cucumber --tags @smoke --format progress`, and that step's `env.REPO_TRACE_PATH` is `tmp/repo-trace-smoke-prod.json`

#### Scenario: A skipped version-headers smoke fails the run
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** a step after the cucumber step and before the upload step runs `jq -e` on `tmp/repo-trace-smoke-prod.json`, and its filter names `.results`, `.requirement == "deployed-stage-exposes-version-headers"` and `.status == "passed"`

#### Scenario: Trace is uploaded only after a passing run
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** the last step uses `actions/upload-artifact` with `name: repo-trace-smoke-prod`, `path: tmp/repo-trace-smoke-prod.json`, `retention-days: 90` and `if-no-files-found: error`, and has no `if`

#### Scenario: Actions are pinned as in CI
- **WHEN** `.github/workflows/smoke-prod.yml` and `.github/workflows/ci.yml` are parsed
- **THEN** every `uses:` in `smoke-prod.yml` names an action that `ci.yml` also uses, at the same ref as in `ci.yml`

#### Scenario: Run blocks contain no expressions
- **WHEN** `.github/workflows/smoke-prod.yml` is parsed
- **THEN** no step's `run:` value contains `${{`
