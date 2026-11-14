# Design

## Context

Observed, not assumed:

- `cd.yml` runs on `repository_dispatch: deploy-release`. `deploy-dev` reads the
  tag from `github.event.client_payload.tag`, downloads and verifies the
  release tarball, runs `sam deploy`, resolves `ApiBaseUrl` from the stack and
  runs `bin/smoke` plus `cucumber --tags @smoke`. `deploy-prod` needs
  `deploy-dev` and sits behind the `prod` environment's approval.
- `actions/checkout` on a `repository_dispatch` run checks out the default
  branch, not the tag. That is existing behaviour and not changed here.
- `greeterhq/greeter-acceptance` is public. Its tag `v0.2.2` has
  `.github/workflows/gate.yml` (a `workflow_call` with inputs
  `acceptance_ref`, `channel`, `candidate_version`, `candidate_sha`,
  `environment`) which validates those inputs and takes its target only from
  `config/environments.yml`.
- That config's `stage` http `base_url` is `https://q2ypn34esg...`, which is the
  `ApiBaseUrl` of the `greeter-http-dev` stack. `prod` is `dhsuw1brrc...`,
  which is the prod stack. So "stage" really is dev.
- The stage ledger (`ledger-stage` branch, `deployed.json`) has schema
  `greeterhq.deployed.v1` and `channels.http.version` like `v0.5.20`.
- `record.yml` accepts `repository_dispatch: channel-released` with payload
  fields `channel`, `version`, `sha`, `environment`.
- Repo variables `DISPATCH_APP_CLIENT_ID` and secret `DISPATCH_APP_PRIVATE_KEY`
  exist. Environments `dev` and `prod` exist.
- Scripts under `bin/` are standalone Ruby (`iam-check`, `smoke`) and are
  linted by RuboCop. Nothing under `bin/` has specs today.

See proposal.md for motivation and non-goals.

## Goals / Non-Goals

**Goals:**
- Prod is unreachable unless the gate passed on the exact tag and commit.
- A failed gate leaves dev on the last version the ledger recorded, or fails
  loudly without touching dev when that is not possible.
- Every value from the dispatch event is validated and never interpolated into
  a script.

**Non-Goals:**
- Restoring prod, or restoring when the gate is cancelled or skipped.
- Changing how `deploy-dev` or `deploy-prod` deploy.

## Decisions

1. **Job graph.**
   `resolve` -> `deploy-dev` -> `gate` -> {`restore-dev` on failure,
   `announce-stage`, `deploy-prod` on success} and `deploy-prod` ->
   `announce-prod`. `deploy-prod` has `needs: [resolve, gate]` and no
   `always()`, so a failed, cancelled or skipped gate skips it before its
   environment is evaluated, which is why no approval is requested.
   `gate` has no `if`, so it runs only after `deploy-dev` succeeds (including
   its smoke steps).

2. **`resolve`.** One step with the tag passed via `env:`, checked in bash with
   `[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]`, then
   `gh api "repos/${{ github.repository }}/commits/${TAG}" --jq .sha` with
   `GH_TOKEN: ${{ github.token }}` and `permissions: contents: read`. The sha is
   checked against `^[0-9a-f]{40}$` before it is written to `$GITHUB_OUTPUT`.
   On a bad tag the step prints a static message, never the tag (S12). The
   workflow also gets a top-level `permissions: {}` and every job declares its
   own (S14).
   Alternative: `git/ref/tags/<tag>` (would need a second call for annotated
   tags). Kept the commits endpoint as specified; it peels annotated tags.
   Risk: a branch with the same name as the tag would be ambiguous. Tags are
   `vX.Y.Z` and branches here are not, so accepted.

3. **`gate`.** `uses: greeterhq/greeter-acceptance/.github/workflows/gate.yml@v0.2.2`
   with exactly `acceptance_ref: v0.2.2`, `channel: http`,
   `candidate_version: needs.resolve.outputs.tag`,
   `candidate_sha: needs.resolve.outputs.sha`, `environment: stage`, and job
   `permissions: contents: read`. No `secrets:`, no URL input. A job-level
   `uses:` ref must be a literal, so the same version is written twice and
   `bin/check-acceptance-ref` keeps the two equal.

4. **`restore-dev`.** `if: always() && needs.deploy-dev.result == 'success' &&
   needs.gate.result == 'failure'`, `environment: dev`, permissions
   `id-token: write`, `contents: read`. Step order matters for safety:
   1. checkout, setup-ruby, setup-sam;
   2. `bin/last-good-release "$FAILED_TAG"` (no AWS credentials yet, so every
      refusal happens before anything can be deployed), output captured as
      `GOOD_TAG`;
   3. download the tarball and `.sha256` for `GOOD_TAG`, `shasum -c`, untar;
   4. configure AWS credentials (OIDC, same role as `deploy-dev`);
   5. `sam deploy` with the same flags as `deploy-dev`;
   6. resolve `ApiBaseUrl`, run `bin/smoke` (same as `deploy-dev`);
   7. a last step that prints what was restored and `exit 1`.
   Steps 2 to 6 failing also fail the job, which is the intended outcome.

5. **`bin/last-good-release`.** A Ruby script defining a small
   `LastGoodRelease` class: `new(fetcher:, ledger_url: LEDGER_URL)` and
   `#call(failed_tag)` returning the version or raising
   `LastGoodRelease::Error` with a reason, and an entry point
   `LastGoodRelease.run(argv, fetcher:, stdout:, stderr:)` returning the exit
   status (0, or 1 with one `last-good-release: <reason>` line on stderr and
   nothing on stdout). The main guard just calls `run` with the real fetcher
   and `exit`s with its result; the specs call `run` with an injected fetcher. The URL is a constant
   (`https://raw.githubusercontent.com/greeterhq/greeter-acceptance/ledger-stage/deployed.json`);
   the CLI has no option to change it. The default fetcher uses `Net::HTTP`
   over https with open and read timeouts and a body size cap. Main guard
   (`if $PROGRAM_NAME == __FILE__`) prints only the version on stdout and
   `last-good-release: <reason>` on stderr, exit 1 on any error. Specs `load`
   the file and inject a fetcher lambda, so no network is used.
   Checks, in order: fetch succeeds, JSON parses to an object, `schema ==
   "greeterhq.deployed.v1"`, `environment == "stage"`, `channels.http` is an
   object, its `version` matches `\Av\d+\.\d+\.\d+\z`, version differs from the
   failed tag. Any untrusted value in a message is quoted with `inspect`-style
   escaping and cut to 64 characters, and every message starts with
   `last-good-release:` (S12). The `environment` check is an addition to the brief (assumption,
   cheap, guards against reading the wrong ledger); say if you want it removed.

6. **`bin/check-acceptance-ref`.** Same shape: a `CheckAcceptanceRef` class
   with `CheckAcceptanceRef.run(argv, stdout:, stderr:)` returning the exit
   status (argv is an optional workflow path, default
   `.github/workflows/cd.yml` resolved from the script's location, not the
   working directory), `exit 1` with a message naming both values on
   a mismatch or non-`vX.Y.Z`. Default path `.github/workflows/cd.yml`, job
   `gate`. It also fails when the gate job, its `uses:` ref or `acceptance_ref`
   is missing, so deleting the gate cannot pass lint. It also requires the
   `uses:` source to be exactly
   `greeterhq/greeter-acceptance/.github/workflows/gate.yml` (S15). YAML is read with
   `YAML.safe_load`.

7. **Announce jobs.** `permissions: {}`, `needs: [resolve, gate]` (stage) and
   `needs: [resolve, deploy-prod]` (prod), no checkout. Step 1 mints a token
   with `actions/create-github-app-token@v3` (`client-id:
   ${{ vars.DISPATCH_APP_CLIENT_ID }}`, `private-key:
   ${{ secrets.DISPATCH_APP_PRIVATE_KEY }}`, `owner: greeterhq`,
   `repositories: greeter-acceptance`, `permission-contents: write` so the
   token carries nothing else, S13). Step 2 runs
   `gh api repos/greeterhq/greeter-acceptance/dispatches -f event_type=channel-released
   -f 'client_payload[channel]=http' -f 'client_payload[version]=$TAG' ...` with
   `GH_TOKEN: ${{ steps.app-token.outputs.token }}` and the other values as
   `env:`. Only `-f` is used: `-F` would treat a value beginning with `@` as a
   file to read.

8. **Tests for the workflow itself.** RSpec specs parse `cd.yml`/`ci.yml`
   (`YAML.safe_load`) and assert the structure: job order and `needs`, no
   `always()` on `deploy-prod`, the `if` on `restore-dev`, gate `with:` keys
   (no URL), announce permissions and token inputs, no `${{ ... }}` of event
   data inside `run:` blocks of the new jobs, and the lint step. This is an
   addition to the two script specs you listed; it is what lets every workflow
   scenario map to a test. `actionlint` runs locally as a verify step (it is
   not wired into CI because only one `ci.yml` step is in scope).

## Security considerations

| # | Finding | Severity | Disposition |
|---|---------|----------|-------------|
| S1 | `client_payload.tag` is attacker-influenced input (anyone who can dispatch). | Medium | `resolve` validates it from `env:` before any use; later jobs read only `needs.resolve.outputs.tag`. No expression of event data inside `run:` bodies in the new jobs (asserted by spec). |
| S2 | The ledger is read from the network and is untrusted. A bad value could end up in a filename, an API path or a shell. | Medium | Fixed https URL, size and time caps, strict schema, version regex before use; the version is only used in a quoted env var and in `greeter-http-<v>.tar.gz`. |
| S3 | Restoring to the version equal to the failed one would redeploy the bad release and look like a recovery. | Medium | Refused by `bin/last-good-release`. |
| S4 | A corrupted or substituted tarball. | Low | `shasum -c` before deploy, as `deploy-dev` does. The `.sha256` comes from the same release, so this catches corruption, not a compromised release. Accepted, same as today. |
| S5 | `-F` in `gh api` reads files for values starting with `@`. | Low | Only `-f` is used in announce jobs. (The existing `ci.yml` dispatch uses `-F`; out of scope.) |
| S6 | Token handling for the dispatch. | Medium | Minted in the job that uses it, owner `greeterhq`, one repository, passed only as `GH_TOKEN`, `permissions: {}`. Follows the workspace security rules. |
| S7 | The gate is a reusable workflow from another repo, pinned by a movable tag. | Low | Same organization, public, and the tag is protected by convention only. Prefer enabling tag protection on `greeter-acceptance`; pinning by commit sha would need `check-acceptance-ref` to map sha to tag, so it is not done here. |
| S8 | Prod bypass. | High | `deploy-prod` needs `gate`, has no `always()`, and a structure spec asserts both. |
| S9 | `restore-dev` uses the deploy role against dev. | Low | Same role and `dev` environment as `deploy-dev`; no new permissions. Credentials are configured only after the ledger check passes. |
| S10 | Workspace rule: synthetic traffic to a deployed environment must send `X-Greeter-Synthetic: true`. `bin/smoke` does not, and `restore-dev` runs it (as `deploy-dev` already does). | Low | Not changed here (`bin/smoke` is outside the files you listed). Suggest a follow-up change. The acceptance suite's own traffic is its repo's concern. |
| S11 | `DISPATCH_APP_CLIENT_ID` is `5670669`, which looks like a numeric App ID rather than a Client ID (those usually look like `Iv...`). The v3 token action expects the client id. | Medium | Verify before the first release; if it is the App ID, the mint step fails and announcements never happen (the release itself is unaffected). Recorded as a task (4.5). |
| S12 | **Workflow-command injection through logs.** GitHub Actions parses lines that start with `::` in a step's output. The tag (from the event) and the ledger version (from the network) are untrusted; echoing either, for example in an `::error::` line, lets its author emit commands or forge annotations (a line break in the value starts a new line). | Medium | Code. `resolve` prints only static text on a bad tag, never the tag. `bin/last-good-release` shows an untrusted value only as a quoted, escaped, length-limited string inside a message that starts with the tool name, so no output line can start with `::`. Spec scenarios and tasks 1.1, 1.3, 2.1, 3.1. Values are written to `$GITHUB_OUTPUT` only after validation, so output injection is not possible. |
| S13 | **Over-broad App token.** `create-github-app-token` gives the token every permission the App holds on the target repository unless narrowed. A repository dispatch only needs `contents: write`. | Medium | Code. The mint step sets `permission-contents: write` and nothing else. Asserted by the structure spec. Tasks 1.3, 3.3. |
| S14 | **Implicit default token permissions.** `cd.yml` has no workflow-level `permissions`, so any job without its own block inherits the repository default, which may be write. | Medium | Code. Add workflow-level `permissions: {}` and declare permissions on every job (`resolve`, `deploy-dev`, `gate`, `restore-dev`, `deploy-prod`, announce jobs). A spec asserts every job declares its own. Tasks 1.3, 3.1. |
| S15 | **Gate repointing.** `check-acceptance-ref` as first designed only compares versions. Someone could change the gate's `uses:` to another repository or path with the same ref and lint would pass. | Medium | Code. The check also requires the source to be exactly `greeterhq/greeter-acceptance/.github/workflows/gate.yml`. Tasks 1.2, 2.2. |
| S16 | **Gate code runs in this repository's context.** The reusable workflow checks out and runs suite code at `v0.2.2`, a movable tag, with this repository's `GITHUB_TOKEN`. | Low | No new code. The gate job gets exactly `contents: read`: no `id-token` (no AWS), no `secrets:`, no `actions`/`contents: write`. The structure spec asserts the exact set. Enable tag protection on `greeter-acceptance` (repository setting, see follow-up). |
| S17 | **Bytes tested are not necessarily the bytes deployed to prod.** The gate approves a tag and sha, but `deploy-prod` downloads the release asset again later, and release assets can be replaced unless releases are immutable. The `.sha256` comes from the same release, so replacing both passes the check. | Medium | No code in this change (changing the download steps is outside the files named). Enable GitHub immutable releases for this repository (setting, see follow-up). A later change can have `resolve` record the artifact digest and have both deploy jobs compare against it. |
| S18 | **A ledger that points at an older vulnerable release.** Anyone able to write the `ledger-stage` branch could steer restore to any previously released version. | Low | Accepted. Restore can only deploy a release that exists as a checksummed asset, the ledger branch is written only by the acceptance repository's publish job, and the reader cannot choose the URL. Not bounded by "older than the failed version" because a legitimate hotfix of an older line restores to a newer ledger version. |
| S19 | **Refreshing `.talismanrc` checksums blesses whatever is in the file.** | Low | Review the diff for secrets before refreshing; never refresh blindly (task 3.5). |

## Risks / Trade-offs

- [The restore path cannot be exercised without a failing gate] → Script specs
  cover its decisions, a structure spec covers its wiring, and a read-only run
  of `bin/last-good-release` against the live ledger checks the real data. The
  first genuine gate failure is the first full run. Consider a one-off drill
  with a deliberately failing candidate.
- [Gate `cancelled` or `skipped` leaves dev on the candidate] → Specified
  (restore only on `failure`); noted as a non-goal.
- [The ledger can lag: `announce-stage` is asynchronous] → Two quick releases
  could see the older ledger version at restore time. Restore then goes to an
  older good version, never to the failed one.
- [Version in the ledger may be unavailable as a GitHub Release] → The download
  step fails and the job fails with dev still on the candidate. Noted, not
  handled.
- [`.talismanrc` pins checksums of `cd.yml` and `ci.yml`] → Refresh them as the
  last edit of each file.

## Scope notes

- `.talismanrc` is edited (checksums only) although it was not in your list.
- Workflow-structure specs go beyond the two script specs you asked for.
- The ledger `environment == "stage"` check goes beyond the brief.
- The "Download + verify" steps of `deploy-dev` and `deploy-prod` had a static
  error message mentioning `client_payload`; it now says "no release tag from
  the resolve job". Nothing else in those steps changed except the tag source.
  (The structure spec asserts `deploy-dev` no longer mentions the payload.)
- `actionlint` 1.7.12 has stale metadata for `actions/create-github-app-token@v3`:
  it demands `app-id` and rejects `client-id`, but the action's `action.yml` at
  `v3` defines `client-id` and marks `app-id` deprecated. Those two reports (and
  a pre-existing shellcheck SC2034 in `ci.yml`'s functional job) are false
  positives or unrelated; they are ignored with `-ignore` when verifying.
