# Observability & operations — greeter-http

How to see what the service is doing, the alarms that page, and how to roll back.

## Structured logs

Every request emits one JSON line to the Lambda log group
(`/aws/lambda/<function>`), plus an API Gateway access log line to
`/aws/apigateway/greeter-http-access`. The application log fields are:

| Field | Meaning |
| --- | --- |
| `service` | Always `greeter-http` (filter tag). |
| `outcome` | `created`, `replayed`, `invalid_name`, `malformed_request`, `missing_idempotency_key`, `payload_too_large`, `idempotency_key_reused`, `unavailable`, `internal_error`, `not_found`. |
| `status` | HTTP status code. |
| `duration_ms` | Server-side request duration. |
| `synthetic` | `true` for monitoring (canary) traffic; `false` for real users. |
| `correlation_id` | From the `x-amzn-trace-id` header (falls back to the API GW request id). |
| `name_hash` | `sha256:<hex>` of the guest name — never the name itself. |
| `greeter_core_version` | The composed `Greeter::Core::VERSION` that handled the request. |
| `error` | Present only on `unavailable` / `internal_error`; the cause class + message. |

> Real-user dashboards should filter `synthetic = false` so the canary's
> traffic (every 5 minutes) doesn't skew the numbers.

## CloudWatch Logs Insights queries

Run these against the Lambda log group. Adjust the time range in the console.

### Latency p50 / p95 / p99 (real traffic)

```
fields duration_ms
| filter service = "greeter-http" and synthetic = false
| stats
    pct(duration_ms, 50) as p50,
    pct(duration_ms, 95) as p95,
    pct(duration_ms, 99) as p99,
    count(*) as n
```

### Latency percentiles per 5-minute bin (trend)

```
fields duration_ms
| filter service = "greeter-http" and synthetic = false
| stats pct(duration_ms, 95) as p95 by bin(5m)
```

### Error rate by outcome

"Error" here means a server-side failure (`unavailable`, `internal_error`);
4xx client rejections are counted separately so a burst of bad requests doesn't
look like an outage.

```
fields outcome
| filter service = "greeter-http" and synthetic = false
| stats count(*) as n by outcome
| sort n desc
```

Error *ratio* in one number:

```
fields outcome
| filter service = "greeter-http" and synthetic = false
| stats
    sum(outcome in ["unavailable","internal_error"]) as errors,
    count(*) as total,
    (errors * 100.0 / total) as error_pct
```

### Error rate by greeter-core version (regression triage)

Use this right after a `greeter-core` bump to see whether errors or latency
moved with the version. If `0.1.3` shows a higher `error_pct` or `p95` than
`0.1.2`, suspect the bump.

```
fields outcome, duration_ms, greeter_core_version
| filter service = "greeter-http" and synthetic = false
| stats
    count(*) as total,
    sum(outcome in ["unavailable","internal_error"]) as errors,
    (errors * 100.0 / total) as error_pct,
    pct(duration_ms, 95) as p95
  by greeter_core_version
| sort greeter_core_version desc
```

### Trace one request end to end

```
fields @timestamp, outcome, status, duration_ms, greeter_core_version
| filter correlation_id = "PASTE-TRACE-ID-HERE"
| sort @timestamp asc
```

## Paging alarms

Three CloudWatch alarms notify the **paging SNS topic** (`PagingTopicArn`
stack output). Subscribe a real destination via the `AlarmEmail` parameter or
by wiring the topic to PagerDuty/Slack.

| Alarm | Fires when | Why it matters |
| --- | --- | --- |
| **Http5xxAlarm** | API Gateway 5xx rate > 5% for 5 min | Users are getting server errors. |
| **HttpLatencyP95Alarm** | API Gateway p95 latency > `Latencyp95ThresholdMs` (default 1000 ms) for 5 min | The service is slow for most users. |
| **CanarySuccessAlarm** | The health canary's `SuccessPercent` < 100% (one run), or no data | The end-to-end checks (greeting increments, 400 on malformed, p95 < 300 ms) are failing — or the canary itself stopped running. |

The canary runs `bin/smoke`'s checks every 5 minutes against the live endpoint,
tagged `x-greeter-synthetic: true` so its traffic is isolated (see below).

## Synthetic traffic

The canary sends `x-greeter-synthetic: true`. The service then:

- tags the log line `synthetic = true` (filter it out of user dashboards), and
- records its greeting counts under a `synthetic#` key prefix in DynamoDB, so
  canary greetings never inflate real per-guest counts.

## Kill switch: disable the counter without a redeploy

`GREETER_COUNTER_ENABLED=false` (set on the Lambda function's environment, no
redeploy needed) makes the service **greet but not count** — it stops all
DynamoDB access and reports the count as `null`. Use it if DynamoDB is degraded
or costs spike. The cold-start banner logs `backend=disabled` so it is obvious
in the logs which mode is live. Set the variable back to `true` (or remove it)
to resume counting.

## Rollback

When a deploy goes bad, in rough order of preference:

1. **Flip the kill switch (fastest, no deploy).** If the problem is the counter
   / DynamoDB, set `GREETER_COUNTER_ENABLED=false` on the function and the
   service keeps greeting while you investigate.

2. **Redeploy the previous release artifact.** Each `v*` tag publishes a
   ready-to-deploy SAM build as a GitHub Release. Download the prior version's
   tarball, unpack it, and deploy:

   ```bash
   tar -xzf greeter-http-<previous>.tar.gz
   cd greeter-http-<previous>
   AWS_PROFILE=<deploy-profile> sam deploy
   ```

   Confirm the running version afterwards: the cold-start log line
   `[greeter-http] version=<previous>` appears on the next invocation (force a
   cold start by redeploying). Watch the alarms clear.

3. **CloudFormation stack rollback.** If a `sam deploy` itself fails mid-update,
   CloudFormation rolls the stack back to its last good state automatically
   (unless rollback was disabled). To roll back a *completed* bad deploy,
   redeploy the previous artifact as in (2) — CloudFormation has no "undo last
   change set" button.

### Post-rollback checks

- `error_pct` (query above) returns to baseline.
- `p95` back under budget.
- `CanarySuccessAlarm` returns to OK.
- If a `greeter-core` bump was the suspect, the by-version query shows the
  previous version handling traffic again.
