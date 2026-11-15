# Tasks

## 1. Red tests

Write all tests first and commit as `test(adopt-acceptance-gate): red`. Show
each failing for the right reason (`NameError` for the missing
`LastGoodRelease` / `CheckAcceptanceRef` classes, or an expectation failure on
the workflow structure), not a syntax or load error: the script specs must
`load` the script only when the file exists, so its absence surfaces as
`NameError`. Tag every example with `requirement:` and `scenario:` metadata
holding the slugs of the OpenSpec headings. Do not edit these files afterwards
to make them pass.

- [x] 1.1 Write `spec/bin/last_good_release_spec.rb` with fixtures `spec/fixtures/ledger/{valid,wrong_schema,wrong_environment,no_http,bad_version,not_json}.json` and an injected fetcher (no network). One example per scenario: valid ledger prints `v0.5.20`; unreadable (fetcher raises, and non-JSON body); wrong schema; missing http entry; bad version (`0.5.20`, `v0.5.20; x`); recorded equals failed; and (S12) a hostile fixture `spec/fixtures/ledger/hostile_version.json` whose version is a very long string containing a line break and `::error::x`, asserting a single-line message that starts with `last-good-release:`, shows the value quoted and cut to 64 characters, and has no output line starting with `::`. Also assert nothing is printed on failure and the reason text names the cause. Verify: `bundle exec rspec spec/bin/last_good_release_spec.rb` fails with `NameError: uninitialized constant LastGoodRelease`.
- [x] 1.2 Write `spec/bin/check_acceptance_ref_spec.rb` with fixtures `spec/fixtures/workflows/{gate_match,gate_mismatch,gate_not_version,gate_missing,gate_wrong_source}.yml`. Examples: matching refs pass; differing refs fail naming both; non-`vX.Y.Z` refs fail naming the value; a missing gate job fails; (S15) a gate whose `uses:` is another repository or path fails naming the source it found. Verify: fails with `NameError: uninitialized constant CheckAcceptanceRef`.
- [x] 1.3 Write `spec/workflows/cd_workflow_spec.rb` (parses `.github/workflows/cd.yml` and `ci.yml` with `YAML.safe_load`) covering the workflow scenarios: resolve job exists with `contents: read`, validates the tag from `env:` and outputs `tag` and `sha`, `deploy-dev` needs `resolve` and no longer reads `client_payload` directly; gate `uses`/`with` values, no URL-like input, `permissions: contents: read`; `deploy-prod` needs `[resolve, gate]` with no `always()`; `restore-dev` needs, exact `if`, `environment: dev`, step order (ledger read before credentials, checksum before `sam deploy`, final failing step); announce jobs' `permissions: {}`, needs, token action inputs (`owner`, single `repositories`), `GH_TOKEN` via `env:`, only `-f` fields, environment `stage` or `prod`; no `${{ github.event.` or `${{ needs.` expression inside any `run:` of the new jobs; (S12) the `resolve` run body never echoes `$TAG` into an `::error::` or any output line; (S14) workflow-level `permissions` is empty and every job declares its own; (S16) the gate job's permissions are exactly `contents: read`; (S13) the announce mint step sets `permission-contents: write` and no other `permission-*` input; ci.yml lint job runs `bin/check-acceptance-ref`. Verify: fails with expectation failures (jobs missing).
- [x] 1.4 Confirm every scenario in `specs/acceptance-gated-release/spec.md` maps to exactly one example (list requirement and scenario slugs from the examples and diff against the spec headings). Verify: no scenario is missing or duplicated.

## 2. Scripts

- [x] 2.1 Create `bin/last-good-release` (executable, `# frozen_string_literal: true`): `LastGoodRelease` class with injected `fetcher:` and `ledger_url:` (constant default, no CLI override), the checks in design.md decision 5, default `Net::HTTP` fetcher over https with timeouts and a body size cap, and a main guard that prints only the version to stdout and `last-good-release: <reason>` to stderr with exit 1 on error. Untrusted values appear in messages only quoted with escaping and cut to 64 characters (S12). The default fetcher follows no redirects and treats any non-200 as unreadable. Verify: `spec/bin/last_good_release_spec.rb` passes and `bundle exec rubocop bin/last-good-release` is clean.
- [x] 2.2 Create `bin/check-acceptance-ref` (executable): `CheckAcceptanceRef` class, default path `.github/workflows/cd.yml`, `YAML.safe_load`, messages naming the offending values, exit 1 on failure; require the gate's `uses:` source to be exactly `greeterhq/greeter-acceptance/.github/workflows/gate.yml` (S15). Verify: `spec/bin/check_acceptance_ref_spec.rb` passes, rubocop is clean, and `bin/check-acceptance-ref` exits 0 once task 3.1 is done.

## 3. Workflows

Edit one concern at a time and run `actionlint` after each.

- [x] 3.1 In `cd.yml`: add workflow-level `permissions: {}` and make sure every existing job declares its own (they already do; confirm) (S14); add the `resolve` job, printing only static text on a bad tag (S12), and switch `deploy-dev` to `needs: resolve` and `needs.resolve.outputs.tag` (no other change to its steps); update the file's header comment to the new flow; add the `gate` job exactly as in design.md decision 3. Verify: `actionlint .github/workflows/cd.yml` is clean and the resolve, deploy-dev and gate examples in `spec/workflows/cd_workflow_spec.rb` pass.
- [x] 3.2 In `cd.yml`: add `restore-dev` per design.md decision 4 and change `deploy-prod` to `needs: [resolve, gate]` using `needs.resolve.outputs.tag` (steps otherwise unchanged). Verify: `actionlint` clean and the restore-dev and deploy-prod examples pass.
- [x] 3.3 In `cd.yml`: add `announce-stage` and `announce-prod` per design.md decision 7, including `permission-contents: write` on the mint step (S13). Verify: `actionlint` clean and the announce examples pass.
- [x] 3.4 In `ci.yml`: add one step to the `lint` job, `run: bin/check-acceptance-ref`, after the RuboCop step. No other change. Verify: `actionlint .github/workflows/ci.yml` clean, the lint example passes, `git diff --stat .github/workflows/ci.yml` shows only that step.
- [x] 3.5 Review `git diff` of both workflows for secrets, then (S19) refresh the `.talismanrc` checksums for `.github/workflows/cd.yml` and `ci.yml` (and any new file talisman flags). Verify: `talisman --scanWithHtml` or the pre-commit hook reports no findings for the changed files.

## 4. Verify and docs

- [x] 4.1 Update `docs/observability.md` "Rollback": describe `restore-dev` (when it runs, what it restores, what it refuses, that the run stays red), how to read its refusal messages, and that prod is never touched. Verify: the described steps match the job names and messages in `cd.yml` and `bin/last-good-release`.
- [x] 4.2 Run `bundle exec rspec` and `bundle exec cucumber`. Verify: all green.
- [x] 4.3 Add `.github/actionlint.yaml` (the two `create-github-app-token@v3` ignores for `cd.yml`, as in greeter-cli), change `for i in $(seq 1 30)` to `for _ in $(seq 1 30)` in `ci.yml`'s step "Start DynamoDB Local (-sharedDb)" (fixes SC2034), then run `bundle exec rubocop`, `actionlint` (no arguments, no `-ignore` flags), `sam validate --template infra/template.yaml --lint`, `bin/check-acceptance-ref`, and `openspec validate --all --strict`. Verify: all pass with no offences, and `actionlint` exits 0.
- [x] 4.4 Run `bin/last-good-release v0.5.21` read-only against the live stage ledger. Verify: it prints the version the ledger records (currently `v0.5.20`), and `bin/last-good-release v0.5.20` fails saying it equals the failed version.
- [x] 4.5 App credentials: no change. `vars.DISPATCH_APP_CLIENT_ID` keeps its name and its value (the numeric App ID `5670669`), which `create-github-app-token@v3` accepts via `@octokit/auth-app`; greeter-cli's announce jobs already recorded cli `v0.1.12` on both ledger branches with it, which also shows the App is installed on `greeter-acceptance` with Contents: write. Verify: the note is in design.md "Credentials (task 4.5)".
- [x] 4.6 First real releases, verified after merge and recorded in design.md "Verification": the real `v0.5.21` release (gate passes, stage announced, prod waits for approval, prod announced) and a throwaway `v0.5.22` (gate fails, `restore-dev` puts back `v0.5.21`, prod is skipped). Verify: the design.md "Verification" table exists with the two run URLs, to be filled in before archiving.

## Workflow follow-up

- Archive the change: the "Verification" table in design.md now has both run URLs.
- Separate change: make `bin/smoke` send `X-Greeter-Synthetic: true`.
- Repository settings, no code (S16, S17): enable immutable releases on `greeter-http`, and tag protection for `v*` on `greeter-acceptance`.
- Separate change (S17): have `resolve` record the artifact digest and make `deploy-dev` and `deploy-prod` verify against it.
- Optional drill: exercise `restore-dev` once with a deliberately failing candidate.
