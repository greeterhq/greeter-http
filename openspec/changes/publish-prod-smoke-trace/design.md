# Design

## Context

- `features/version_headers.feature` has one `@smoke` scenario tagged
  `@requirement-deployed-stage-exposes-version-headers
  @scenario-smoke-check-on-a-deployed-stage`.
- The `Before('@smoke')` hook in `features/step_definitions/smoke_steps.rb`
  skips every `@smoke` scenario when `GREETER_BASE_URL` is empty. `ci.yml`
  never sets that variable, so the trace from `functional` always says
  `skipped` for this requirement.
- `features/smoke_deployed.feature` is also tagged `@smoke` but has no
  `@requirement-` tags. `--tags @smoke` runs it, and the trace writer ignores
  it. A failure there still fails the cucumber step, so nothing is uploaded.
- `smoke_post` already sends `X-Greeter-Synthetic: true`.
- `features/support/repo_trace.rb` writes the trace through
  `RepoTrace::Document.write`. The document has top-level `results`, and each
  result has `requirement`, `scenario`, `status`, `source` and `location`
  (`spec/support/repo_trace/document.rb`, `RESULT_KEYS`). The jq filter's field
  names match these. `sha` is `GITHUB_SHA`, and the writer creates `tmp/`
  itself.
- `cd.yml` is named `CD` and runs on `repository_dispatch` `deploy-release`.

## Goals / Non-Goals

**Goals:** a trace from a real prod run that greeter-docs can read, produced
by one workflow, with no credentials and with a red run whenever the
version-headers smoke did not pass.

**Non-Goals:** see proposal. No change to `cd.yml`, the trace writer or
`ci.yml`.

## Decisions

### D1. Check out `GITHUB_SHA` (no `ref:`)

`actions/checkout@v5` with no `ref:` checks out `GITHUB_SHA`, and the trace
writer records `GITHUB_SHA` as `sha`. The tested code and the recorded sha
therefore always agree.

- `ref: main` was rejected. `main` can move between the trigger and the
  checkout, and then the trace would name a commit that was not tested.
- `github.event.workflow_run.head_sha` was rejected. CD runs on
  `repository_dispatch`, so its `head_sha` is the tip of `main` when the
  dispatch was sent, not the release tag. It adds nothing over `GITHUB_SHA`.

For `schedule` and `workflow_run`, `GITHUB_SHA` is the latest commit on the
default branch. For `workflow_dispatch` it is the tip of the branch the run was
started from, and the job runs only when that branch is `main` (D4, S1).

Checkout sets `persist-credentials: false`, so the token is not left in
`.git/config` for later steps (S2).

### D2. Committed `GREETER_BASE_URL`

The URL `https://dhsuw1brrc.execute-api.eu-west-2.amazonaws.com` is a
top-level `env` value in the workflow, not a variable or a secret.

- It is a public API Gateway endpoint. Calling it needs no credentials, so
  the workflow needs no secrets or variables, and the URL under test is
  visible and reviewed in git.
- It is the same value as `environments.prod.channels.http.base_url` in
  greeter-acceptance's `config/environments.yml` (checked when this change
  was written). If the prod stage is recreated, both files must change
  together.
- A stale URL fails loudly. The POST fails or returns the wrong status, the
  cucumber step goes red, and nothing is uploaded.
- CD does not use this value. Its deploy jobs read the stack's `ApiBaseUrl`
  output, and that stays as it is.

### D3. A silent skip fails the run

If the scenario is skipped (for example because the env was dropped) or the
trace has no entry for the requirement, cucumber can still exit 0. A step
between cucumber and the upload runs:

```bash
jq -e '[.results[] | select(.requirement == "deployed-stage-exposes-version-headers" and .status == "passed")] | length > 0' tmp/repo-trace-smoke-prod.json
```

`jq -e` exits non-zero when the result is `false`, so the job fails and the
upload does not run. If no trace was written, jq fails on the missing file.
`if-no-files-found: error` stays on the upload as a second guard. `jq` is
preinstalled on `ubuntu-latest`.

### D4. Trigger and job gate

```yaml
"on":
  schedule:
    - cron: '17 6 * * *'
  workflow_dispatch:
  workflow_run:
    workflows: [CD]
    types: [completed]
```

The job's `if` is
`github.ref == 'refs/heads/main' && (github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success')`.
A failed or cancelled CD run starts no smoke, and a manual run started from a
branch other than `main` is skipped (see S1). `"on"` is quoted, as in
`ci.yml`, so YAML does not read it as `true`.

### D5. Mirror `ci.yml` for Ruby and actions

The workflow uses the same action refs as `ci.yml` (`actions/checkout@v5`,
`ruby/setup-ruby@v1`, `actions/upload-artifact@v6`). It also passes
`ruby-version: ${{ env.RUBY_VERSION }}` and `bundler: ${{ env.BUNDLER_VERSION }}`
from a top-level `env` that copies `ci.yml` (`"3.3"`, `"4.0.22"`), with a
"keep in sync" comment like the one in `cd.yml`. The spec compares action refs
against `ci.yml` at test time, so a bump in `ci.yml` without one here fails
the spec. The Ruby and Bundler versions are not part of a scenario.

### D6. Upload on success only

The upload step has no `if:`, so the default `success()` applies. A red run
uploads nothing. greeter-docs reads the latest successful run.

### D7. Spec shape

`spec/workflows/smoke_prod_workflow_spec.rb` loads both files with
`YAML.safe_load_file(..., aliases: true)` and uses small helpers (`job`,
`steps`, `index_of_step`) as `cd_workflow_spec.rb` does. Each scenario maps to
one example tagged `requirement: 'a-scheduled-prod-smoke-publishes-a-trace'`
and `scenario: '<slug>'`. Because Psych reads the quoted `"on"` key as the
string `on`, the trigger example reads `workflow['on']`. The no-credentials
example checks for `secrets.`, `vars.` and `github.event.` in every string of
the parsed YAML, not the raw text, so a header comment that mentions one (for
example to explain why `workflow_run.head_sha` is not used) does not fail it.

## Risks / Trade-offs

- **Manual run from a branch.** The job `if` skips a `workflow_dispatch` run
  started on any branch but `main`. A branch can edit its own copy of the
  workflow to remove that guard, so greeter-docs must still filter runs (S1).
- **Prod traffic.** About seven synthetic POSTs per run. They are marked
  synthetic and use fresh keys, except `smoke-fixed-key`, which replays.
- **URL drift.** Covered by D2: the run goes red when the URL is stale.
- **Duplicate runs.** A schedule run and a CD-triggered run can overlap. Each
  run has its own artifact, so there is no clash.
- **Smoke failures in prod are not paged.** A red run is visible only in
  Actions. Alerting is out of scope.

## Security considerations

Review of the workflow as designed in D1 to D7. Findings marked **Task** need
code; each one names its task in `tasks.md`. The others are accepted risks or
notes, with the reason.

### S1. Prod evidence can be forged from a branch (Medium, accepted fix: Task 1.0, 2.1; cross-repo dependency on greeter-docs)

`workflow_dispatch` runs the copy of `smoke-prod.yml` on the branch it is
started from. Anyone with write access can push a branch whose workflow,
features or jq filter always "pass", run it, and get a green run with a
`repo-trace-smoke-prod` artifact recording
`deployed-stage-exposes-version-headers` as `passed`. The same branch could
add a `push` trigger. greeter-docs reads the latest successful run, so it
would show that forged result.

The trust root is branch protection on `main`: `schedule` and `workflow_run`
always use the default branch's copy of the workflow. Nothing inside a branch's
workflow can be trusted to restrict itself, so the real control has to be on
the consumer side.

- In this repo, the job `if` also requires `github.ref == 'refs/heads/main'`
  (D4, scenario "Job runs only on main and skips a failed CD run"). This
  doesn't stop a malicious branch, which can delete the guard, but it stops
  honest manual runs from a branch from publishing evidence.
- **Cross-repo dependency (greeter-docs, not tracked in this repo's tasks):**
  greeter-docs must accept a `repo-trace-smoke-prod` artifact only from a run
  where `path` is `.github/workflows/smoke-prod.yml`, `head_branch` is `main`,
  `event` is `schedule`, `workflow_run` or `workflow_dispatch`, and the
  trace's `sha` equals the run's `head_sha`. Until greeter-docs does this,
  the forgery path stays open.

### S2. Checkout persists the token for later steps (Low, accepted fix: Task 1.0, 2.1)

`actions/checkout@v5` writes `GITHUB_TOKEN` into `.git/config` by default.
Every later step can read it, and that includes `bundle install` and the gem
code Cucumber loads. The token is only `contents: read`, but nothing after
checkout needs it. Set `persist-credentials: false`, as `api-diff` in `ci.yml`
does.

### S3. `workflow_run` payload fields are attacker-influenced (Low, accepted fix: Task 1.0, 1.1)

`workflow_run` runs in the default branch's context with that branch's
token. The usual risk with this trigger comes from code or artifacts taken
from the triggering run. This design does neither. It checks out `GITHUB_SHA`
(D1), not `workflow_run.head_sha`, and downloads no artifact. CD can only be
started by a `repository_dispatch` call that needs a token with write access,
so forks cannot trigger it.

Some payload fields are free text that a committer controls, such as
`head_branch`, `display_title` and `head_commit.message`. Today the only field
read is `github.event.workflow_run.conclusion`, and only in the job `if`. The
"no `${{` in `run:`" scenario does not stop a later edit from passing a
free-text field through `env:` or `with:`. Add a check that the file's only
`github.event.` reference is `github.event.workflow_run.conclusion` in the job
`if`.

### S4. Actions pinned to tags, not commit SHAs (accepted)

`actions/checkout@v5`, `ruby/setup-ruby@v1` and `actions/upload-artifact@v6`
are movable tags. This matches `ci.yml`, as the brief requires. If one of
these actions were compromised, it would get a read-only token and no secrets
here, but it could still forge the artifact (see S1). Pinning to SHAs should
be a repo-wide change covering `ci.yml` and `cd.yml` together, not done in one
workflow. No task in this change.

### S5. Synthetic load on prod (accepted)

Each run sends seven POSTs to prod, one of them a 64 KiB body. Anyone with
write access can start runs repeatedly with `workflow_dispatch`. The
`$default` stage throttle in `infra/template.yaml` (rate 25, burst 50) bounds
the load. Every request sends `X-Greeter-Synthetic: true`, so real guest
counts are not touched, but the runs still write synthetic counter items and
idempotency records (TTL `IdempotencyTtlSeconds`, 86400 s). No task.

### S6. Committed prod URL (accepted)

The endpoint is unauthenticated and the same URL is already committed in
greeter-acceptance's `config/environments.yml`, so committing it here does not
widen exposure. It is the URL of a public API, not a credential. No task.

### S7. What reaches logs and the artifact (accepted)

The artifact holds only slugs, statuses, locations and run metadata.
`RepoTrace::Document` validates every field against a pattern before writing
and never writes names or messages. On a failure, Cucumber's progress output
prints expectation diffs, which can include response values such as the fixed
synthetic names (`Alice Bonsu`, `Carol Kay`) and status codes. The job has no
secrets to leak. Anyone with read access to the repo can read the logs. No
task.
