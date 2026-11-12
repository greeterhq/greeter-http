# Design

## Context

- `RackApp#call` builds `[status, headers, body]` per path via `success` and
  `error`; headers are lowercase hash keys (`content-type`, `retry-after`).
  404 comes from the non-`POST /greetings` branch; 500 and 503 from
  `map_unexpected`. There is no 405 or 415 today.
- `App.build` is the composition root: it returns `Adapters::RackApp.new(...)`,
  and `build_handler` wraps that in `LambdaHandler`. `config.ru` uses
  `App.build_from_env`, so wrapping inside `App.build` covers both entry points.
- `LambdaHandler#call` already copies the Rack headers into the response
  `headers` map via `stringify`; it does not filter them.
- `Greeter::Core::VERSION` is already read by `RackApp` for logging.
- See proposal.md for motivation and non-goals.

## Goals / Non-Goals

**Goals:**
- One place adds the headers so no route or error path can forget them.
- Values come only from `GreeterHttp::VERSION` and `Greeter::Core::VERSION`.

**Non-Goals:**
- Changing `RackApp` routing, status codes, or bodies.
- Handling exceptions that escape the Rack app entirely (see Risks).

## Decisions

1. **Rack middleware `GreeterHttp::Adapters::VersionHeaders`** in
   `lib/greeter_http/adapters/version_headers.rb`, initialised with
   `app:` plus `service_version:` and `core_version:` keywords, defaulting to
   the two constants. It calls the inner app and merges
   `x-greeter-version` and `x-greeter-core-version` into the returned headers
   (lowercase, as Rack 3 requires). It overwrites any inner value, never reads
   `env`.
   *Alternatives:* adding headers inside `RackApp#success`/`#error` (easy to
   miss a path, e.g. the 404 branch); adding them in `LambdaHandler` (would not
   cover `config.ru`/local runs and makes the Lambda adapter own HTTP policy).
2. **Wiring in `App.build` only:** `Adapters::VersionHeaders.new(app: rack_app)`.
   `App` stays the only composition root and the only place naming the
   concrete class. Constants are injected by default arguments so specs can
   pass fixed values.
3. **No special handling for `X-Greeter-Synthetic`.** `RackApp` already reads
   it only for counting and logging. The middleware ignores request headers, so
   the response is identical with or without it. A spec asserts equality of
   status, body, and headers and absence of an echoed header.
4. **Lambda handler unchanged.** `stringify` already passes headers through.
   `lambda_handler_spec.rb` gains assertions on fixtures for 201, 422 and an
   unrouted path.
5. **Version without "v":** `GreeterHttp::VERSION` is already `0.5.19` form;
   bump to `0.5.20`. The middleware does not strip or prepend anything. CI
   already asserts the version against the pushed `v*` tag.
6. **Smoke scenario** reuses the existing `POST` step and adds `Then` steps
   that read `@response['X-Greeter-Version']` and
   `@response['X-Greeter-Core-Version']`. It is tagged `@smoke` and is skipped
   when `GREETER_BASE_URL` is unset. Per workspace rules any traffic sent to a
   deployed environment sends `X-Greeter-Synthetic: true`; the existing
   `smoke_post` helper does not do that yet, so the new scenario's request must
   (see tasks).
7. **Traceability:** each spec scenario maps to exactly one RSpec example or
   Cucumber scenario tagged `@requirement-<requirement-slug>` and
   `@scenario-<scenario-slug>`.

## Security considerations

Review of this change against the current code (`rack_app.rb`,
`lambda_handler.rb`, `spec/security/http_security_spec.rb`, `infra/template.yaml`).

| # | Finding | Severity | Disposition |
|---|---------|----------|-------------|
| S1 | Exact service and core versions are visible to unauthenticated callers, which helps an attacker pick known CVEs for greeter-core. | Low | Accepted: it is the stated goal. Limit the exposure to exactly the two headers (S3). Keep `bundler-audit` in the verify step so a vulnerable core version is not the thing being advertised. |
| S2 | Header injection or response splitting if a version value ever contained CR/LF or odd characters. Today both are constants, but the constant could be edited, or a future change could source them elsewhere. | Medium | Code: validate both values against a strict pattern when the middleware is constructed, so a bad value fails at boot (Lambda init) and never reaches a response. Task 1.5 and 2.4. |
| S3 | A future edit could add more version-bearing headers (`Server`, `X-Powered-By`, Rack or Ruby versions). | Low | Code: a security spec asserts only the two version headers exist. Task 1.6. |
| S4 | A client-supplied `X-Greeter-Version` / `X-Greeter-Core-Version`, or a value set by the inner app, could be reflected or win over the constants. | Medium | Code: the middleware overwrites, never merges or reads `env`. Already in the spec; task 1.1 includes an inner-app-sets-a-different-value example. |
| S5 | CORS: custom headers are not readable by browser scripts cross-origin unless `Access-Control-Expose-Headers` is set. | Info | No change. The service deliberately has no CORS (existing security spec). Do not add `access-control-*` headers. The existing wildcard and CORS examples must still pass; neither version value contains `*`. |
| S6 | `X-Greeter-Synthetic: true` is client-controlled, so anyone can send it. | Info | Pre-existing and unchanged: it only moves the write to an isolated key space and changes neither status, body, nor version headers. Out of scope here; worth a separate look at whether synthetic traffic should be authenticated. |
| S7 | An exception escaping `RackApp` bypasses the middleware, and API Gateway then returns its own error without the headers. | Info | Accepted, as in Risks. It also means no stack trace or version leaks via that path. Do not add a catch-all rescue in the middleware, which could mask errors or echo exception text. |
| S8 | The smoke test sends traffic to a deployed stage. | Low | Code: the new smoke request MUST send `X-Greeter-Synthetic: true` (workspace rule). The existing `smoke_post` helper does not; changing it alters existing smoke scenarios and is left as a follow-up. Task 1.3. |
| S9 | Logging: versions are not secrets, and nothing new is logged. Guest names stay hashed. | Info | No change. |

No IAM, infrastructure, dependency, or secret changes are involved.

## Risks / Trade-offs

- [Exception escaping `RackApp` (e.g. from the logger) bypasses the middleware]
  → In scope are exceptions "mapped to 500"; `RackApp` maps greeting-path
  errors already. The middleware does not rescue, to avoid masking bugs. If
  escape is later judged to matter, add a rescue in the middleware as a
  separate change.
- [Spec lists 405 and 415, which the Rack app does not produce] → The spec
  requirements are written for "every response", with scenarios only for
  statuses that exist (404 for unrouted path or method). If 405/415 are added
  later the middleware covers them with no change.
- [Installed greeter-core may differ from the example `0.1.3`] → Tests compare
  against `Greeter::Core::VERSION` rather than a literal; the Gemfile pin is
  `~> 0.1` and is not changed.
- [Version exposure aids fingerprinting] → Accepted: the request is explicitly
  for black-box visibility; no secrets are exposed.
- [Rack 3 header-name casing] → Use lowercase keys; API Gateway returns them
  as-is and clients read case-insensitively.
