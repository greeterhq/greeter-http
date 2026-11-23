# Tasks

## 1. Red tests

The maintainer runs `tests-open` before this group and `tests-close` after 1.3.

- [x] 1.0 Security (design S1 to S3): amend `specs/live-docs-traceability/spec.md` so that each new check maps to one scenario, then run `openspec validate publish-prod-smoke-trace --strict`. Done during planning, with the maintainer's approval.
  - S1: "Job skips a failed CD run" is renamed "Job runs only on main and skips a failed CD run", and its `if` is `github.ref == 'refs/heads/main' && (github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success')`.
  - S2: in "Smoke checks out the triggering commit", the checkout step has `persist-credentials: false` and no `ref` input.
  - S3: in "Workflow holds no credentials", the only `github.event.` reference in the file is `github.event.workflow_run.conclusion`, inside the job `if`.
- [x] 1.1 Write `spec/workflows/smoke_prod_workflow_spec.rb`, modelled on `spec/workflows/cd_workflow_spec.rb`. It loads `smoke-prod.yml` and `ci.yml` with `YAML.safe_load_file(..., aliases: true)` and has one example per scenario of "A scheduled prod smoke publishes a trace", each tagged `requirement: 'a-scheduled-prod-smoke-publishes-a-trace'` and its scenario slug:
  - `smoke-runs-daily-on-demand-and-after-cd`
  - `job-runs-only-on-main-and-skips-a-failed-cd-run`
  - `workflow-holds-no-credentials`
  - `base-url-is-the-committed-prod-endpoint`
  - `smoke-checks-out-the-triggering-commit`
  - `cucumber-runs-only-smoke-scenarios-and-writes-the-trace`
  - `a-skipped-version-headers-smoke-fails-the-run`
  - `trace-is-uploaded-only-after-a-passing-run`
  - `actions-are-pinned-as-in-ci`
  - `run-blocks-contain-no-expressions`

  The examples for `job-runs-only-on-main-and-skips-a-failed-cd-run`, `smoke-checks-out-the-triggering-commit` and `workflow-holds-no-credentials` assert the S1, S2 and S3 checks as amended in 1.0. The S3 check collects every `github.event.` occurrence in the parsed YAML's strings (comments excluded, design D7).
- [x] 1.2 Run `bundle exec rspec spec/workflows/smoke_prod_workflow_spec.rb` and confirm every example fails because `smoke-prod.yml` does not exist (`Errno::ENOENT`), not because of a syntax or load error. Run `bundle exec rspec spec/trace_check_spec.rb` and confirm the new requirement and scenario slugs are known (they come from this change's ADDED section).
- [x] 1.3 Commit as `test(publish-prod-smoke-trace): red`. (f1a8f4b; red run: 10 examples, 10 failures, all `Errno::ENOENT` on `smoke-prod.yml`; trace check 15 examples, 0 failures.)

## 2. Implementation

- [x] 2.1 Write `.github/workflows/smoke-prod.yml` per design D1 to D6: header comment (purpose, triggers, why the URL is committed, why there is no `ref:`), quoted `"on"`, top-level `permissions: contents: read`, top-level `env` (`GREETER_BASE_URL`, `RUBY_VERSION`, `BUNDLER_VERSION`), one job with the D4 `if` (including the S1 `github.ref == 'refs/heads/main'` guard), and the steps checkout (with `persist-credentials: false`, S2), setup-ruby, cucumber, jq check and upload. Put a short comment above the `if` explaining that the guard covers honest manual runs from a branch only, and that greeter-docs must still filter runs (S1). Verify: `smoke_prod_workflow_spec` passes.
- [x] 2.2 Run `actionlint .github/workflows/smoke-prod.yml`. Verify: clean.
- [x] 2.3 Confirm that `git diff --stat` shows no change to `.github/workflows/cd.yml`, `.github/workflows/ci.yml`, `features/`, `spec/support/` or `lib/`.
- [x] 2.4 At commit time, add `.talismanrc` entries only for files Talisman flags. Commit as `feat(publish-prod-smoke-trace): scheduled prod smoke trace`.

## 3. Verify and docs

- [x] 3.1 Run `bundle exec rspec` and `bundle exec cucumber` (smoke skipped locally). Both pass, and `spec/trace_check_spec.rb` reports the new requirement as covered.
- [x] 3.2 Locally, run `GREETER_BASE_URL=https://dhsuw1brrc.execute-api.eu-west-2.amazonaws.com REPO_TRACE_PATH=tmp/repo-trace-smoke-prod.json bundle exec cucumber --tags @smoke --format progress`, then run the D3 `jq -e` command. Confirm that it exits 0. Run the jq command against a trace from a run without `GREETER_BASE_URL` and confirm that it exits 1.
  - With the URL (`REPO_TRACE_PATH=tmp/smoke-pass.json`): 6 scenarios (6 passed), cucumber exit 0; jq printed `true`, exit 0; the version-headers result is `passed` at `features/version_headers.feature:7`.
  - Without the URL (`REPO_TRACE_PATH=tmp/smoke-skip.json`): 6 scenarios (6 skipped), cucumber exit 0; jq printed `false`, exit 1; the version-headers result is `skipped`. Cucumber exits 0 on a full skip, so the jq step is what fails a silent skip (design D3).
- [x] 3.3 Run `bundle exec rubocop`, `actionlint`, `sam validate -t infra/template.yaml` and `openspec validate --all --strict`. All pass.
- [x] 3.4 Update `README.md` Testing section: the `smoke-prod` workflow, its triggers, the `repo-trace-smoke-prod` artifact, and that its URL must change together with greeter-acceptance's `config/environments.yml`.
- [x] 3.5 After merge, start `smoke-prod` with `workflow_dispatch` on `main`. Confirm that the run is green and the `repo-trace-smoke-prod` artifact contains `deployed-stage-exposes-version-headers` with status `passed`. Record the run URL here.
  - Passed, as reported by the maintainer: https://github.com/greeterhq/greeter-http/actions/runs/45088245869 (`main`, `e03ac08`, artifact `repo-trace-smoke-prod` not expired).
