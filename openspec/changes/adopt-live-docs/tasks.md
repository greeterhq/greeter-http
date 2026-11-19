# Tasks

## 1. Red tests

The maintainer runs `tests-open` before this group and `tests-close` after 1.14.
The `Gemfile` and `Gemfile.lock` changes (`openapi_first ~> 4.4`, `:test` group)
are already in the working tree and go in the red commit.

- [ ] 1.1 Write `spec/tooling/slug_spec.rb`: the design's table of hand-written slugs, plus the property check over every real heading (lowercase letters, digits and single hyphens; unique per capability and level). Tag it `requirement: 'every-requirement-has-a-tagged-test', scenario: 'slug-rule-turns-headings-into-slugs'`.
- [ ] 1.2 Write `spec/trace_check_spec.rb` and fixtures under `spec/fixtures/trace_check/`: `specs/`, `changes/in-flight-change/`, `changes/archive/2026-01-01-archived-change/`, `examples/*.rb`, `features/*.feature` and `excluded/`. Cover the untagged requirement, unknown slugs in RSpec and in Cucumber, a scenario slug under another requirement, a same-text scenario, in-flight versus archived, REMOVED and RENAMED headings, fixture exclusion, the one-requirement-one-scenario tag rule, and one example on the real repo. Add the `greeting_counter.feature` example (13 scenarios, seven requirements, no feature-level tag). Tag each example with its `live-docs-traceability` scenario.
- [ ] 1.3 Write `spec/tooling/repo_trace_document_spec.rb`: valid RSpec and Cucumber results, refused locations (`..`, `.`, empty segment, leading `/`, line 0, wrong prefix for the source), refused slugs, statuses and sources, without echoing the value. Use string keys for bad values.
- [ ] 1.4 Write `spec/tooling/repo_trace_formatter_spec.rb` and fixtures under `spec/fixtures/repo_trace/`: the v1 document with `repo` `greeter-http`, skipped versus pending, collapsed shared examples, `git rev-parse HEAD` and null `run_id` fallbacks, malformed values from tags and from the environment, and description privacy (`Alice Smith`).
- [ ] 1.5 Write `spec/tooling/cucumber_repo_trace_spec.rb` and fixtures under `spec/fixtures/repo_trace_cucumber/`: the v1 document with `source: cucumber`, `Scenario:` line locations, pending versus skipped, malformed tags and environment values, and no scenario names or step text in the output.
- [ ] 1.6 Write `spec/bin/merge_repo_trace_spec.rb`, which runs `bin/merge-repo-trace` as a subprocess: the merge, each mismatched field (including `run_id` null versus non-null), shape errors per source, unsafe locations, malformed top-level values on both inputs, and a duplicated result.
- [ ] 1.7 Write `spec/workflows/ci_workflow_spec.rb`, one group per CI scenario: `functional` trace env, formatter and merge; the upload gate, retention and failure behaviour; `notify-docs` needs, permissions, gate, token inputs and dispatch; top-level and per-job permissions; no `${{` in the relevant `run:` bodies; the scheduled-run guards in `ci.yml` and `cd.yml`; no `traceability-report`; `api-diff` trigger, checkout, oasdiff inputs, permissions, base-ref `env` and the base-has-file condition; the `concurrency` group and `cancel-in-progress` values; the `release` job copying `openapi.yaml` before `tar` and its build check for `openapi_first-*`; and the `--dry-run` of the `functional` rspec command.
- [ ] 1.8 Write `spec/openapi_description_spec.rb`: the request, success responses, error responses, status list, version headers, no `servers`, no other path, and the `info.version` check against `GreeterHttp::VERSION`. Add `spec/fixtures/openapi/version_mismatch.yaml` for the failing case.
- [ ] 1.9 Write `spec/tooling/openapi_contract_spec.rb` and fixtures under `spec/fixtures/openapi/`: described responses pass through unchanged, and an undocumented `418`, an extra field, a string `count` and a missing version header each fail naming `POST /greetings` and the status. `GET /nope` is not validated. `features/support/openapi_contract.rb` exists and requires the shared support. The wrapper is installed on `GreeterHttp::App` and `build_handler` is wrapped too.
- [ ] 1.10 Add to `spec/security/http_security_spec.rb` a group proving the Lambda bundle stays clean: `git grep -n openapi_first -- lib exe infra` finds nothing, and the `Gemfile` declares `openapi_first` only in the `:test` group.
- [ ] 1.11 Write `spec/docs/adr_spec.rb` (untagged): both ADR files exist, are numbered, and have `Status`, `Context`, `Decision` and `Consequences` headings.
- [ ] 1.12 Tag `features/greeting_counter.feature` per the design's table: delete the feature-level `@requirement-greeting-counter` line and add one `@requirement-<slug> @scenario-<slug>` line above each of the 13 scenarios. Change nothing else.
- [ ] 1.13 Run `bundle exec rspec` and confirm each new spec fails for the right reason (NameError, a missing file or an expectation failure, never a syntax or load error), and that the existing specs still pass.
- [ ] 1.14 Commit as `test(adopt-live-docs): red`.

## 2. Implementation

The maintainer runs `tests-open` before 2.2, 2.3, 2.6 and 2.9, which edit files
under `spec/` and `features/`, and `tests-close` after 2.9.

- [ ] 2.1 Copy `spec/support/repo_trace/slug.rb`, `check.rb` and `document.rb` from greeter-cli (not `tag_only_diff.rb`), with `REPO` set to `greeter-http`. Verify: the slug, trace-check and document specs pass.
- [ ] 2.2 Add `spec/support/repo_trace_formatter.rb` and the `.rspec` `--require ./spec/support/repo_trace_formatter` line. Verify: the formatter spec passes.
- [ ] 2.3 Add `features/support/repo_trace.rb` and delete `features/support/traceability.rb`. Verify: the Cucumber writer spec passes and `bundle exec cucumber` still passes.
- [ ] 2.4 Copy `bin/merge-repo-trace` from greeter-cli (executable, stdlib only), with `greeter-http` as the repo. Verify: the merge spec passes.
- [ ] 2.5 Write `openapi.yaml` per the design, with `info.version` equal to `GreeterHttp::VERSION`. Verify: the description spec passes and `OpenapiFirst.load('openapi.yaml')` loads it.
- [ ] 2.6 Add `spec/support/openapi_contract.rb` (install, `Build`, `Checked`, `Mismatch`, version check), load it from `.rspec` with `--require ./spec/support/openapi_contract` after `spec_helper` (no edit to `spec/spec_helper.rb`), and add `features/support/openapi_contract.rb` (no edit to `features/support/env.rb`). Verify: the contract spec passes and every existing example and scenario still passes with response validation on. If an existing response does not match `openapi.yaml`, stop and say which, because either the description or the test is wrong.
- [ ] 2.7 Update `ci.yml`: top-level `permissions`, `concurrency` (group `ci-${{ github.event_name }}-${{ github.ref }}`, `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`), the schedule, the `functional` trace env, formatter, merge and gated upload, remove the `traceability-report` upload, add `notify-docs` and `api-diff`, and update `release` (copy `openapi.yaml`, check the bundle). Verify: `ci_workflow_spec` passes and `actionlint` is clean.
- [ ] 2.8 Write the two ADRs in `docs/adr/`. Verify: the ADR spec passes.
- [ ] 2.9 Add the file-scoped `.rubocop.yml` exclusions. Verify: `bundle exec rubocop` is clean.
- [ ] 2.10 At commit time, add or refresh `.talismanrc` checksum entries only for files Talisman actually flags, using the pre-commit hook's suggested entries. Remove entries for deleted files.
- [ ] 2.11 Manual, outside the repo: set `DISPATCH_APP_CLIENT_ID` and `DISPATCH_APP_PRIVATE_KEY` for this repo and install the App on `greeter-docs` with Contents write.

## 3. Verify and docs

- [ ] 3.1 Run `bundle exec rspec --format progress --format RepoTraceFormatter`, `bundle exec cucumber` and `bin/merge-repo-trace tmp/repo-trace.json tmp/repo-trace-spec.json tmp/repo-trace-bdd.json`. Confirm both sources appear, every requirement (27 existing plus this change's) is covered, and `grep -c Alice tmp/repo-trace*.json` is 0.
- [ ] 3.2 Run `bundle exec rubocop`, `actionlint`, `sam validate -t infra/template.yaml` and `openspec validate --all --strict`. All pass.
- [ ] 3.3 Run this scripted check from the repo root after the commits, and paste the commands and their output under this task. Every command after the first must print nothing. Also check the Lambda boundary.
  ```bash
  git diff --name-status origin/main -- spec features | grep -v '^A'
  # expect exactly: M features/greeting_counter.feature, M spec/security/http_security_spec.rb, D features/support/traceability.rb

  git diff --unified=0 origin/main -- features/greeting_counter.feature \
    | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | grep -vE '^\+\s*(@\S+\s*)+$' | grep -vxE '^-@requirement-greeting-counter\s*'
  # expect: no output (added lines hold only tags; the one removed line is the old feature-level tag)

  git diff --unified=0 origin/main -- spec/security/http_security_spec.rb | grep -E '^-' | grep -vE '^---'
  # expect: no output (additions only)

  git diff origin/main --stat -- lib exe infra
  git grep -n openapi_first -- lib exe infra
  # expect: no output from either
  ```
- [ ] 3.4 Run `sam build -t infra/template.yaml` and confirm `.aws-sam/build` has no `openapi_first-*` directory.
- [ ] 3.5 Update `README.md`: the Testing section (trace files, the merge command, the slug rule, response validation), an OpenAPI section (where `openapi.yaml` lives, how it is validated, how breaking changes are blocked), the release steps (bump `version.rb` and `openapi.yaml` together), the ADR location, and the line about `@requirement-greeting-counter`.
- [ ] 3.6 Prove red in CI first: push the red commit plus only the `.rubocop.yml` exclusions to a throwaway branch, confirm `lint` passes and `functional` fails for the new specs, and put the failing run's URL in the PR description.
- [ ] 3.7 Prove the breaking-change check: open a throwaway pull request that makes a breaking change to `openapi.yaml` (make `X-Greeter-Synthetic` required), confirm `api-diff` fails, and record the failing run URL here. Close the pull request without merging and delete its branch. Also confirm the real pull request that adds `openapi.yaml` shows `api-diff` green with the oasdiff step skipped.
