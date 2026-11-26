# Design

## Context

- `bin/smoke` is a top-level script, not a module. It reads `GREETER_BASE_URL`
  when it loads, calls `abort` when the variable is empty, and ends with
  `exit 0` or `exit 1`. Every request goes through its `post` helper, which
  builds a `Net::HTTP::Post` and sets `Content-Type` and `Idempotency-Key`.
- `perf/load.rb` defines `GreeterHttp::Perf::Load`, a `module_function`
  module. Every request goes through `Load.attempt(http, uri, guest)`. The
  public entry point is `Load.run(base_url:, vus:, duration_s:, rate:)`.
- The `@smoke` step definitions already set the header as
  `request['X-Greeter-Synthetic'] = 'true'`
  (`features/step_definitions/smoke_steps.rb`). The canary sends
  `x-greeter-synthetic: true`. The service compares the value
  case-insensitively and the header name is case-insensitive in HTTP, so
  either casing works.
- `webrick` is already in the `:development, :test` bundle group, and nothing
  in `spec/` starts an HTTP server yet.
- The service honours the header from v0.5.0 onwards. CD's restore job runs
  `bin/smoke` from the default branch against the last good release, which
  could in principle be older.

## Goals / Non-Goals

**Goals:**
- Each tool sets the header at the single place where it builds a request, so
  a request added later goes through the same code and is marked too.
- The tests watch the requests a real HTTP endpoint receives, so they would
  catch a request that skips the shared helper.

**Non-Goals:**
- Making `bin/smoke` loadable as a library or restructuring either tool.
- A shared HTTP client for the two tools.

## Decisions

### D1. Set the header inside the existing request helpers

`bin/smoke`'s `post` and `Load.attempt` each gain one line:
`req['X-Greeter-Synthetic'] = 'true'`. The casing matches `smoke_steps.rb`.

*Alternative:* add an opt-out flag or env variable (for example
`GREETER_SYNTHETIC=false`). Rejected. The rule allows no exceptions for
deployed environments, and neither tool has a legitimate reason to write real
counts.

### D2. Test `bin/smoke` as a subprocess against a local recording server

`spec/bin/smoke_spec.rb` starts a WEBrick server on `127.0.0.1` with port 0
(the OS picks a free port). The server records each request's headers and
returns canned responses that let `bin/smoke` pass both checks:
- a valid greeting gets `201` with an increasing `count`
- a body that isn't valid JSON gets `400`

The spec runs `ruby bin/smoke` through `Open3.capture3`, with
`GREETER_BASE_URL` set to the server. It asserts that the script exits 0, that
the server received three requests, and that every one carried
`X-Greeter-Synthetic: true`.

A subprocess is needed because the script calls `exit` and `abort` at load
time, which would end the RSpec process. Checking exit 0 proves that both
checks ran, so no request was skipped.

*Alternative:* refactor `bin/smoke` into a `Smoke.run(..., http:)` module like
`bin/last-good-release`, then inject a fake client. Rejected for this change.
The refactor is larger than the fix, and CD runs this script on every deploy.

### D3. Test the load generator through `Load.run` against the same kind of server

`spec/perf/load_spec.rb` (a new directory) uses `require_relative` to load
`perf/load.rb`. It calls `Load.run` against a local recording server that
answers `201`, with `vus: 2`, `duration_s: 1` and `rate: 10`. It asserts that
the server received at least one request, that every request carried the
header, and that `run` reported no failures.

Calling `run` rather than `attempt` covers the real connection setup and the
threads. It takes about one second.

*Alternative:* call `Load.attempt` with a fake `http` that captures the
request object. That is faster, but it depends on a helper name and would miss
a request that bypasses `attempt`.

### D4. One shared test server helper

Both specs use `spec/support/recording_http_server.rb`, which each spec loads
with `require_relative`. The helper starts WEBrick on a free port in a
background thread, collects requests in a thread-safe array, answers through a
block the spec supplies, and shuts down in an `after`/`ensure`. It sends
WEBrick's access and error logs to a null logger so the spec output stays
clean.

### D5. Traceability tags

Each example carries the slugs derived from the spec headings:
- `requirement: 'repository-tools-mark-deployed-stage-traffic-as-synthetic'`
- `scenario: 'post-deploy-smoke-script-marks-every-request'` and
  `scenario: 'deployed-load-generator-marks-every-request'`

## Risks / Trade-offs

- **Restoring a release older than v0.5.0.** That release ignores the header,
  so its smoke greetings count as real, which is what happens today. Nothing
  gets worse.
- **Flaky port binding in CI.** Port 0 avoids collisions. The server binds to
  `127.0.0.1` only.
- **Spec run time.** The load spec adds about 1 s and the smoke subprocess
  about 1 s, which is acceptable for the `functional` job.
- **Old data stays.** Existing `GUEST#smoke guest …` and
  `GUEST#perf guest …` items in prod remain. See the proposal's Non-goals.

## Migration Plan

1. Merge, then cut a release as usual. `bin/smoke` runs from the checked-out
   default branch, so CD uses the new script on its next run even before a new
   Lambda release.
2. Rollback means reverting the commit. No data or infra change is involved.
