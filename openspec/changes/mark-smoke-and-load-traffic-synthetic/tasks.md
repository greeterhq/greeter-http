# Tasks

## 1. Red tests

The maintainer runs `tests-open` before this group and `tests-close` after 1.5.

- [ ] 1.1 Write `spec/support/recording_http_server.rb` per design D4. It starts WEBrick on `127.0.0.1` port 0, records each request's method, path, headers and body in a thread-safe array, answers through a block the caller supplies, sends WEBrick's logs to a null logger, and shuts down in `ensure`. Verify: requiring it in `irb -Ilib` and starting and stopping the server raises no errors.
- [ ] 1.2 Write `spec/bin/smoke_spec.rb` per design D2. It has one example tagged `requirement: 'repository-tools-mark-deployed-stage-traffic-as-synthetic'` and `scenario: 'post-deploy-smoke-script-marks-every-request'`. The stub answers valid JSON with `201` and an increasing `count`, and invalid JSON with `400`. The example runs `ruby bin/smoke` with `Open3.capture3` and `GREETER_BASE_URL` pointing at the stub, then asserts exit 0, three received requests, and `X-Greeter-Synthetic: true` on each.
- [ ] 1.3 Write `spec/perf/load_spec.rb` per design D3. It has one example tagged `requirement: 'repository-tools-mark-deployed-stage-traffic-as-synthetic'` and `scenario: 'deployed-load-generator-marks-every-request'`. The example loads `perf/load.rb` with `require_relative`, calls `GreeterHttp::Perf::Load.run(base_url:, vus: 2, duration_s: 1, rate: 10)` against a stub that answers `201`, then asserts at least one received request, `X-Greeter-Synthetic: true` on each, and `failed` equal to 0.
- [ ] 1.4 Run `bundle exec rspec spec/bin/smoke_spec.rb spec/perf/load_spec.rb`. Confirm that both examples fail on the header expectation, with the script still exiting 0 and `failed` still 0. They must not fail on a load error, a bind error or a non-zero smoke exit. Run `bundle exec rspec spec/trace_check_spec.rb` and confirm that it passes. Until 1.2 and 1.3 exist it fails with "requirement \"repository-tools-mark-deployed-stage-traffic-as-synthetic\" … has no tagged test", so this change must not merge without its red tests.
- [ ] 1.5 Commit as `test(mark-smoke-and-load-traffic-synthetic): red`, and record the red-run summary here.

## 2. Implementation

- [ ] 2.1 In `bin/smoke`'s `post` helper, add `req['X-Greeter-Synthetic'] = 'true'` per design D1, and update the header comment to say that the script marks its traffic as synthetic. Verify: `spec/bin/smoke_spec.rb` passes.
- [ ] 2.2 In `GreeterHttp::Perf::Load.attempt`, add `req['X-Greeter-Synthetic'] = 'true'` per design D1, and add one line to the module comment saying so. Verify: `spec/perf/load_spec.rb` passes.
- [ ] 2.3 Confirm that `git diff --stat` shows no change to `lib/`, `infra/`, `openapi.yaml`, `.github/workflows/`, `features/` or any existing file under `spec/`.
- [ ] 2.4 At commit time, add `.talismanrc` entries only for files Talisman flags. Commit as `feat(mark-smoke-and-load-traffic-synthetic): mark smoke and load traffic synthetic`.

## 3. Verify and docs

- [ ] 3.1 Update the "Synthetic traffic" section of `docs/observability.md` to list three senders of the header: the canary, `bin/smoke` and the `@smoke` Cucumber steps, and the deployed load test in `perf/`. Verify: `spec/docs/adr_spec.rb` and any docs specs still pass.
- [ ] 3.2 Run `bundle exec rspec` and `bundle exec cucumber` (smoke scenarios skip locally). Both pass, and `spec/trace_check_spec.rb` reports the new requirement as covered.
- [ ] 3.3 Run `bundle exec rubocop`, `sam validate -t infra/template.yaml` and `openspec validate --all --strict`. All pass.
- [ ] 3.4 Against dev, run `GREETER_BASE_URL=<dev ApiBaseUrl> bin/smoke`. Then, with read access to the dev table, look up the run's guest under its normalised (title-cased) name. Confirm that a `synthetic#GUEST#<name>` counter item exists and that no `GUEST#<name>` item exists. Record the name and the result here.

## Workflow follow-up

- Archive the change after review, so that `synthetic-traffic` becomes a main spec.
- Decide separately whether to remove the existing real-keyed smoke-guest and perf-guest items from dev and prod. That is a manual data operation, and it needs a PITR restore point first.
