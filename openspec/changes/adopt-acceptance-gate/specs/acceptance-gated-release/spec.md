# Spec Delta

## Purpose

Makes the shared acceptance suite a hard gate on every greeter-http release:
a release must pass it on dev before prod, dev is restored when it fails, and
each deployed release is announced to the acceptance ledgers.

## ADDED Requirements

### Requirement: Release tag is validated and resolved before any deployment
The pipeline SHALL accept a release only when the dispatched tag is exactly
`vX.Y.Z` (digits only), SHALL resolve the commit that tag points to, and SHALL
do both before anything is deployed.

#### Scenario: Valid tag resolves to its commit
- **WHEN** a `deploy-release` event carries the tag `v0.5.21`
- **THEN** the pipeline outputs that tag and the 40-character sha of the tagged commit before the dev deployment starts

#### Scenario: Malformed tag stops the run
- **WHEN** a `deploy-release` event carries a tag that is not `vX.Y.Z`, such as `v1.2`, `main` or `v1.2.3; echo x`
- **THEN** the pipeline fails at the resolve step and no deployment, gate or announcement runs

#### Scenario: Hostile tag text is not echoed
- **WHEN** a `deploy-release` event carries a tag containing a line break or workflow-command text such as `v1.2.3` followed by a new line and `::error::x`
- **THEN** the run fails at the resolve step and no part of the tag appears in the log as a workflow command

### Requirement: Workflow token permissions are explicit
The CD workflow SHALL grant no permissions by default, and every job SHALL
declare the permissions it needs.

#### Scenario: Default none, every job declares
- **WHEN** the CD workflow is loaded
- **THEN** its workflow-level permissions are empty and every job declares its own permissions

### Requirement: Dev deployment is gated by the acceptance suite
The pipeline SHALL run the acceptance suite's gate for channel `http` against
environment `stage` after a successful dev deployment. The gate SHALL test the
stage base URL from the suite's committed configuration and SHALL NOT be given
a URL by this pipeline.

#### Scenario: Gate runs after a successful dev deployment
- **WHEN** the dev deployment and its smoke checks succeed for tag `v0.5.21` at commit `abc1234`
- **THEN** the gate runs for channel `http`, environment `stage`, with candidate version `v0.5.21` and candidate sha `abc1234`

#### Scenario: Gate target is not supplied by the pipeline
- **WHEN** the gate is invoked
- **THEN** the pipeline passes no URL or host to it, and the target is the stage base URL in the acceptance suite's committed configuration

### Requirement: A failed gate stops promotion to prod
The pipeline SHALL NOT deploy to prod, SHALL NOT request prod approval, and
SHALL NOT announce the release when the gate fails.

#### Scenario: Gate failure blocks prod
- **WHEN** the gate fails against stage
- **THEN** the prod deployment job does not run, no approval is requested for the prod environment, and no `channel-released` event is sent

#### Scenario: Gate success allows prod approval
- **WHEN** the gate passes against stage
- **THEN** the prod deployment job is eligible to run and requests approval from the prod environment

### Requirement: A failed gate restores dev to the last recorded release
The pipeline SHALL, when dev deployed successfully and the gate failed,
redeploy to dev the http version the stage ledger last recorded, using that
release's checksum-verified artifact, run the smoke checks, and mark the run
failed.

#### Scenario: Dev is restored after a gate failure
- **WHEN** the dev deployment succeeded, the gate failed, and the stage ledger records http version `v0.5.20`
- **THEN** the pipeline downloads the `v0.5.20` tarball and checksum, verifies the checksum, deploys it to the dev stack, and runs the smoke checks

#### Scenario: Restored run is still marked failed
- **WHEN** dev has been restored and its smoke checks pass
- **THEN** the restore job ends failed so the run is red

#### Scenario: Restore does not run for other outcomes
- **WHEN** the dev deployment failed, or the gate passed, or the gate was cancelled or skipped
- **THEN** the restore job does not run

#### Scenario: Corrupt artifact is not deployed
- **WHEN** the restore artifact's checksum does not match
- **THEN** nothing is deployed and the job fails

### Requirement: Restore refuses an unsafe or unknown target
The last-good-release reader SHALL print the recorded http version only when
the stage ledger is readable, has schema `greeterhq.deployed.v1`, has an http
entry whose version is `vX.Y.Z`, and that version differs from the failed one.
Otherwise it SHALL fail with the reason and the pipeline SHALL deploy nothing.

#### Scenario: Valid ledger prints the recorded version
- **WHEN** the ledger has schema `greeterhq.deployed.v1` and http version `v0.5.20`, and the failed version is `v0.5.21`
- **THEN** the reader prints `v0.5.20` and exits successfully

#### Scenario: Unreadable ledger fails
- **WHEN** the ledger cannot be fetched or is not valid JSON
- **THEN** the reader exits non-zero, names the ledger as unreadable, and prints no version

#### Scenario: Wrong schema fails
- **WHEN** the ledger's schema is not `greeterhq.deployed.v1`
- **THEN** the reader exits non-zero, names the schema, and prints no version

#### Scenario: Missing http entry fails
- **WHEN** the ledger has no http channel entry
- **THEN** the reader exits non-zero, says there is no recorded http version, and prints no version

#### Scenario: Bad recorded version fails
- **WHEN** the recorded http version is not `vX.Y.Z`, for example `0.5.20` or `v0.5.20; x`
- **THEN** the reader exits non-zero, says the version is invalid, and prints no version

#### Scenario: Recorded version equal to the failed version fails
- **WHEN** the recorded http version equals the failed version
- **THEN** the reader exits non-zero, says restoring would redeploy the failed version, and prints no version

#### Scenario: Untrusted ledger text is neutralised in messages
- **WHEN** the recorded http version is very long or contains a line break and workflow-command text such as `::error::x`
- **THEN** the reader fails with a single-line message that starts with the tool name, shows the value only as a quoted, escaped, length-limited string, and prints no line that starts with `::`

### Requirement: Deployed releases are announced to the acceptance ledgers
The pipeline SHALL send `channel-released` to the acceptance repository with
channel `http`, the release tag, its commit sha and the environment, once for
stage after the gate passes and once for prod after the prod smoke passes.

#### Scenario: Stage is announced after the gate passes
- **WHEN** the gate passes for tag `v0.5.21` at commit `abc1234`
- **THEN** `channel-released` is sent with channel `http`, version `v0.5.21`, sha `abc1234` and environment `stage`

#### Scenario: Prod is announced after the prod smoke passes
- **WHEN** the prod deployment and its smoke checks succeed
- **THEN** `channel-released` is sent with channel `http`, the same version and sha, and environment `prod`

#### Scenario: Nothing is announced for a failed stage or prod
- **WHEN** the gate fails, or the prod deployment or its smoke fails
- **THEN** no `channel-released` event is sent for that environment

### Requirement: Announcements hold only a single-repository App token
Each announce job SHALL hold no workflow token permissions and SHALL use only
a GitHub App token minted in that job and scoped to the acceptance repository.

#### Scenario: No workflow token permissions
- **WHEN** an announce job runs
- **THEN** the job declares empty permissions

#### Scenario: Token is scoped to one repository
- **WHEN** an announce job mints its token
- **THEN** the token is requested for owner `greeterhq` and exactly the repository `greeter-acceptance`, in the same job and immediately before it is used

#### Scenario: Token permissions are narrowed
- **WHEN** an announce job mints its token
- **THEN** it requests only the contents write permission that a repository dispatch needs, rather than every permission the App holds

#### Scenario: Event values are not interpolated into scripts
- **WHEN** an announce job sends the dispatch
- **THEN** the tag, sha and environment reach the command only as environment variables and string fields, and the token only as `GH_TOKEN`

### Requirement: The acceptance suite pin is consistent
The repository SHALL fail its lint check when the gate's workflow ref and its
`acceptance_ref` input differ or are not `vX.Y.Z`.

#### Scenario: Matching refs pass
- **WHEN** the gate uses ref `v0.2.2` and `acceptance_ref` is `v0.2.2`
- **THEN** the check exits successfully

#### Scenario: Differing refs fail
- **WHEN** the gate uses ref `v0.2.2` and `acceptance_ref` is `v0.2.1`
- **THEN** the check exits non-zero and names both values

#### Scenario: Refs that are not versions fail
- **WHEN** either ref is not `vX.Y.Z`, for example `main` or `v0.2`
- **THEN** the check exits non-zero and names the offending value

#### Scenario: Gate must come from the acceptance repository
- **WHEN** the gate job's workflow is not `greeterhq/greeter-acceptance/.github/workflows/gate.yml`, for example another repository or path
- **THEN** the check exits non-zero and names the source it found

#### Scenario: Lint runs the check
- **WHEN** the CI lint job runs
- **THEN** it runs the acceptance ref check
