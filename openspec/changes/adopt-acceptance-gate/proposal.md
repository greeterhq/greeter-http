# Proposal

## Why

Today CD deploys a release to dev, smokes it, and then asks for prod approval.
Nothing proves the release against the shared acceptance suite
(`greeterhq/greeter-acceptance`), nothing puts dev back when a release turns out
bad, and the acceptance ledgers never learn what was deployed. Wave 1 builds
that suite; this change makes it a hard gate on every greeter-http release and
keeps the ledgers current.

## What Changes

- `cd.yml` gains a `resolve` job that validates the dispatched tag (`vX.Y.Z`)
  and resolves the tagged commit sha. `deploy-dev` consumes the tag from it.
- A `gate` job calls the acceptance suite's reusable gate workflow (pinned at
  `v0.2.2`) for channel `http`, environment `stage` (which is dev), after
  `deploy-dev`. The target URL comes from the suite's committed configuration,
  never from this workflow.
- `deploy-prod` now needs `gate`, so a failed gate means no prod deployment and
  no approval request.
- A `restore-dev` job runs when dev deployed but the gate failed. It reads the
  last http version the stage ledger recorded, redeploys that release to dev
  (checksum verified, smoke checked) and always ends failed so the run is red.
  It refuses, without deploying, when the ledger is unreadable, malformed, has
  no http entry, records a bad version, or records the failed version itself.
- `announce-stage` (after the gate) and `announce-prod` (after the prod smoke)
  send `channel-released` to `greeter-acceptance` using a minted,
  single-repository GitHub App token, in jobs with `permissions: {}`.
- New scripts: `bin/last-good-release` (ledger reader) and
  `bin/check-acceptance-ref` (keeps the gate's `uses:` ref and `acceptance_ref`
  equal and `vX.Y.Z`). `ci.yml`'s lint job gets one step that runs the latter.
- `docs/observability.md` "Rollback" describes `restore-dev`.

No application code, API contract, infrastructure template or greeter-core
change.

## Capabilities

### New Capabilities
- `acceptance-gated-release`: how a greeter-http release is proven against the
  acceptance suite on dev before prod, how dev is restored when it fails, and
  how deployed releases are announced to the acceptance ledgers.

### Modified Capabilities
<!-- none: greeting-counter and version-headers requirements are unchanged -->

## Impact

- Repos touched: `greeter-http` only. **greeter-core is not affected.**
  `greeter-acceptance` is consumed (reusable workflow, ledger read, dispatch
  target) and not modified.
- Files: `.github/workflows/cd.yml`, `.github/workflows/ci.yml` (one lint step),
  `bin/last-good-release`, `bin/check-acceptance-ref`, `docs/observability.md`,
  new specs under `spec/bin/` and `spec/workflows/` with fixtures under
  `spec/fixtures/`.
- Also `.talismanrc`: it pins checksums of `cd.yml` and `ci.yml`, so editing
  them requires refreshing those entries. This file is outside the list of
  files you named; see design.md "Scope notes".
- Needs in place before the first gated release: `vars.DISPATCH_APP_CLIENT_ID`
  and `secrets.DISPATCH_APP_PRIVATE_KEY` (both already set), and the App
  installed on `greeter-acceptance` with permission to send a repository
  dispatch.

## Non-goals

- No change to `deploy-prod`'s own steps, to `deploy-dev`'s steps beyond the
  tag source, to `bin/smoke`, `infra/rollback.sh`, or the SAM template.
- No automatic restore of prod, and no restore when the gate is cancelled or
  skipped (only when it fails).
- No change to what the acceptance suite tests, how it records results, or its
  ledger format.
- No change to the `release` job's existing `deploy-release` dispatch in
  `ci.yml`.
- Not adding `X-Greeter-Synthetic` to `bin/smoke` (see design.md: the smoke
  steps, including the new restore smoke, keep the behaviour they have today).
