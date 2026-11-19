# api-description Specification

## Purpose
The HTTP API is described by a hand-written openapi.yaml that tracks the service version, is checked against every response of the composed app, and is guarded against breaking changes on pull requests.

## Requirements

### Requirement: The API is described by openapi.yaml
The repository SHALL contain `openapi.yaml` (OpenAPI 3.1) at its root that
describes `POST /greetings` as the `greeting-counter` and `version-headers`
specs define it and as the code returns it today. It SHALL describe no other
path, no `servers` entry, and no status the service does not return.

#### Scenario: The request is described
- **WHEN** `openapi.yaml` is loaded
- **THEN** `POST /greetings` has a JSON request body with a required string `name`, a required `Idempotency-Key` header of type string with `minLength` 1 and no `format`, whose description says clients should send a UUID, and an optional `X-Greeter-Synthetic` header

#### Scenario: Success responses are described
- **WHEN** `openapi.yaml` is loaded
- **THEN** `201` (a new greeting) and `200` (a replay of a recorded request) each have a JSON body with exactly the required fields `guest_name`, `greeting`, `count` (an integer, or null when the counter is disabled) and `greeted_at` (a date-time), and the `200` description says it is a replay

#### Scenario: Error responses are described
- **WHEN** `openapi.yaml` is loaded
- **THEN** `400`, `409`, `413`, `422`, `500` and `503` each have a JSON body with exactly the required fields `error` and `message`, where `error` is one of `missing_idempotency_key` or `malformed_request` (400), `idempotency_key_reused` (409), `payload_too_large` (413), `invalid_name` (422), `internal_error` (500) or `temporarily_unavailable` (503), and `503` also has a `Retry-After` header

#### Scenario: Only the returned statuses are described
- **WHEN** `openapi.yaml` is loaded
- **THEN** `POST /greetings` defines exactly the statuses `200`, `201`, `400`, `409`, `413`, `422`, `500` and `503`, with no `404`, no `415`, no `default`, and no other path

#### Scenario: Every response carries both version headers
- **WHEN** `openapi.yaml` is loaded
- **THEN** each of the eight responses lists `X-Greeter-Version` and `X-Greeter-Core-Version` as required string headers

### Requirement: The description version tracks the service version
`info.version` in `openapi.yaml` SHALL equal `GreeterHttp::VERSION`, so a
release cannot ship a description that names another version.

#### Scenario: Matching versions pass
- **WHEN** `info.version` in `openapi.yaml` equals `GreeterHttp::VERSION`
- **THEN** the version spec passes

#### Scenario: Differing versions fail
- **WHEN** `info.version` differs from `GreeterHttp::VERSION`
- **THEN** rspec fails and names both values

### Requirement: Every response of the composed app matches openapi.yaml
Test support SHALL validate every response that `GreeterHttp::App.build`
produces in RSpec and Cucumber against `openapi.yaml`, and SHALL raise when a
response does not match, naming the operation and the status. Responses to
requests that match no described operation are not validated.

#### Scenario: Described responses pass
- **WHEN** the composed app answers requests that produce `201`, `200`, `400`, `409`, `413`, `422`, `500` and `503` on `POST /greetings`
- **THEN** no validation error is raised and the response reaches the caller unchanged

#### Scenario: An undocumented status fails and is named
- **WHEN** the wrapped app returns status `418` for `POST /greetings`
- **THEN** rspec fails with a message naming the operation `POST /greetings` and the status `418`

#### Scenario: A field mismatch fails and is named
- **WHEN** the wrapped app returns `201` for `POST /greetings` with an extra body field, a missing `count`, or a `count` that is a string
- **THEN** rspec fails with a message naming the operation `POST /greetings` and the status `201`

#### Scenario: A missing version header fails and is named
- **WHEN** the wrapped app returns `200` for `POST /greetings` without `X-Greeter-Core-Version`
- **THEN** rspec fails with a message naming the operation `POST /greetings` and the status `200`

#### Scenario: Unrouted requests are not validated
- **WHEN** a request such as `GET /nope` or `GET /greetings` reaches the composed app
- **THEN** the `404` response reaches the caller unchanged and no validation error is raised

#### Scenario: Cucumber validates through the same support
- **WHEN** the Cucumber world builds its handler
- **THEN** `features/support/` loads the same validation support as RSpec, so a mismatched response fails the scenario that produced it

#### Scenario: The Lambda bundle stays free of the test gem
- **WHEN** `git grep -n openapi_first -- lib exe infra` runs, the `Gemfile` is read, and `.github/workflows/ci.yml` is parsed
- **THEN** the search finds nothing, `openapi_first` is declared only in the `:test` group, and the `release` job fails when `.aws-sam/build` contains an `openapi_first-*` directory

### Requirement: Breaking changes to openapi.yaml fail pull requests
On every pull request, CI SHALL compare `openapi.yaml` with the base branch's
copy and SHALL fail on breaking changes at level ERR. It SHALL skip the
comparison only when the base branch has no `openapi.yaml`.

#### Scenario: A breaking change fails the pull request
- **WHEN** a pull request makes a breaking change to `openapi.yaml`, such as making `X-Greeter-Synthetic` required
- **THEN** the `api-diff` job fails

#### Scenario: The comparison is configured as specified
- **WHEN** `.github/workflows/ci.yml` is parsed
- **THEN** `api-diff` runs only for `pull_request`, checks out with `fetch-depth: 0`, runs `oasdiff/oasdiff-action/breaking@v0` with `base` `origin/${{ github.base_ref }}:openapi.yaml`, `revision` `HEAD:openapi.yaml`, `fail-on` `ERR` and `review` `false`, has `permissions: {contents: read}`, and passes the base ref to scripts only through `env`

#### Scenario: A base without openapi.yaml skips the comparison
- **WHEN** the base branch has no `openapi.yaml`, as in the pull request that first adds it
- **THEN** the oasdiff step is skipped and the job passes, and the step runs whenever the base has the file

### Requirement: Releases carry the description
The release tarball SHALL contain `openapi.yaml`, copied from the tagged
commit, so later jobs and consumers use the released description.

#### Scenario: The tarball includes openapi.yaml
- **WHEN** `.github/workflows/ci.yml` is parsed
- **THEN** the `release` job copies `openapi.yaml` into the package directory before the `tar` step, so `greeter-http-<tag>/openapi.yaml` is in the tarball
