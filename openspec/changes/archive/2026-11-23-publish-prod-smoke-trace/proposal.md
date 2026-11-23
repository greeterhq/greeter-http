# Proposal

## Why

The `version-headers` requirement "Deployed stage exposes version headers" is
covered only by the `@smoke` scenario in `features/version_headers.feature`.
That scenario needs `GREETER_BASE_URL`, which `ci.yml` never sets, so the
`functional` job always records it as `skipped`. CD's smoke steps run against
a real stage but publish no trace. greeter-docs therefore never sees this
requirement pass.

## What Changes

- New workflow `.github/workflows/smoke-prod.yml`. It is the only producer of
  prod smoke evidence.
  - Triggers: `schedule` daily at `17 6 * * *`, `workflow_dispatch`, and
    `workflow_run` on workflow `CD`, types `[completed]`.
  - One job. It runs only on `refs/heads/main`, and not when the event is
    `workflow_run` and that run's conclusion is not `success`.
  - `permissions: contents: read`. No secrets, no variables, no AWS steps.
  - `env.GREETER_BASE_URL` is committed as
    `https://dhsuw1brrc.execute-api.eu-west-2.amazonaws.com`.
  - Steps:
    1. `actions/checkout@v5` with no `ref:` and `persist-credentials: false`.
    2. `ruby/setup-ruby@v1` with `bundler-cache: true`.
    3. `bundle exec cucumber --tags @smoke --format progress` with
       `REPO_TRACE_PATH: tmp/repo-trace-smoke-prod.json`.
    4. A `jq -e` check that the trace has a `passed` result for
       `deployed-stage-exposes-version-headers`.
    5. `actions/upload-artifact` (same version as `ci.yml`) with name
       `repo-trace-smoke-prod`, path `tmp/repo-trace-smoke-prod.json`,
       `retention-days: 90` and `if-no-files-found: error`, on success only.
  - Action versions match `ci.yml`. No `run:` block contains `${{ }}`.
- New requirement "A scheduled prod smoke publishes a trace" in the
  `live-docs-traceability` capability, with one scenario per point above.
- New spec `spec/workflows/smoke_prod_workflow_spec.rb`. It parses the
  workflow YAML the way `spec/workflows/cd_workflow_spec.rb` does, with one
  tagged example per scenario.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `live-docs-traceability`: adds the requirement "A scheduled prod smoke
  publishes a trace". Existing requirements are unchanged.

## Impact

- **Repos:** greeter-http only. greeter-core is not affected. greeter-docs and
  greeter-acceptance are not changed. greeter-docs can read the new artifact,
  but wiring it in is out of scope.
- **New files:** `.github/workflows/smoke-prod.yml` and
  `spec/workflows/smoke_prod_workflow_spec.rb`.
- **Edited files:** `README.md` (Testing section) and, only if Talisman flags
  them, `.talismanrc` entries.
- **Unchanged (constraint):** `.github/workflows/cd.yml`,
  `features/support/repo_trace.rb`, `spec/support/repo_trace/*`,
  `.github/workflows/ci.yml`, every feature file, `lib/`, `exe/` and `infra/`.
- **Traffic:** each run sends the `@smoke` requests (about seven POSTs) to
  prod once a day, after each successful CD run, and on each manual run. The
  smoke steps already send `X-Greeter-Synthetic: true`.
- A new file under `spec/` means the maintainer runs `tests-open` for the red
  commit.

## Non-goals

- No change to `cd.yml`, its smoke jobs or its triggers.
- No change to the trace writer, the trace schema or `bin/merge-repo-trace`.
  The prod trace is a separate artifact and is not merged with `repo-trace`.
- No stage (dev) smoke trace. Only prod is published.
- No `concurrency` group. Artifacts are scoped to a run, so overlapping runs
  cannot clash.
- No `docs-refresh` dispatch from this workflow, and no greeter-docs change.
- No new requirement text in `version-headers`.
