# Spec Delta

## Purpose

Greets a guest over HTTP and returns how many times that guest has been greeted,
guaranteeing that client retries never inflate the count.

## ADDED Requirements

### Requirement: Greet a guest and return a running count

The system SHALL accept an HTTP request to greet a named guest and SHALL respond
with a greeting together with the total number of times that guest has been
greeted. The count SHALL increase by exactly one for each distinct greeting
request accepted for a guest. Guest identity SHALL use the greeting domain's
normalized name, so names differing only by surrounding whitespace or letter
case refer to the same guest.

#### Scenario: First greeting for a new guest

- **WHEN** a client sends a greeting request for a guest that has never been greeted, with a fresh idempotency key
- **THEN** the system responds `201 Created` with the greeting, the normalized guest name, and a count of `1`

#### Scenario: Subsequent greeting for an existing guest

- **WHEN** a client greets a guest who has been greeted before, with a fresh idempotency key
- **THEN** the system responds `201 Created` and the returned count is one greater than the previous count for that guest

#### Scenario: Names differing only by case or whitespace share a count

- **WHEN** a client greets `"  alice bonsu "` and later greets `"Alice Bonsu"`, each with a fresh idempotency key
- **THEN** both requests resolve to the same guest and the second response's count is one greater than the first

### Requirement: Reject invalid guest names

The system SHALL reject a greeting request whose name is invalid according to the
greeting domain (empty, longer than the domain's maximum length, or containing
control characters) and SHALL NOT change any guest's count for a rejected request.

#### Scenario: Empty name is rejected

- **WHEN** a client sends a greeting request with an empty or whitespace-only name
- **THEN** the system responds `422 Unprocessable Entity` with an error identifying the invalid name, and no count changes

#### Scenario: Over-long name is rejected

- **WHEN** a client sends a name longer than the domain's maximum allowed length
- **THEN** the system responds `422 Unprocessable Entity` and no count changes

### Requirement: Require a client-supplied idempotency key

The system SHALL require every greeting request to carry a client-supplied
idempotency key and SHALL reject a request that omits it, without changing any
count.

#### Scenario: Missing idempotency key is rejected

- **WHEN** a client sends a greeting request without an idempotency key
- **THEN** the system responds `400 Bad Request` with an error indicating the key is required, and no count changes

### Requirement: Replaying an idempotency key returns the original result

The system SHALL treat a repeated request that carries a previously seen
idempotency key and the same request content as a replay: it SHALL NOT greet the
guest again or change the count, and it SHALL return the same result (guest name
and count) that the original request produced.

#### Scenario: Retry with the same key does not double-count

- **WHEN** a client sends a greeting request and later resends an identical request with the same idempotency key
- **THEN** the second response reports the same count as the first and the guest's stored count is unchanged by the retry

#### Scenario: Replay returns the original count even after other greetings

- **WHEN** key `K` greets a guest to count `N`, other keys greet the same guest to count `M` (M greater than N), and the client then resends the request for key `K`
- **THEN** the replay responds `200 OK` with count `N`, the count the original request produced

#### Scenario: Replay is distinguishable from a first success by status

- **WHEN** a request succeeds for the first time and is then replayed with the same key and content
- **THEN** the first response status is `201 Created` and the replay response status is `200 OK`, with identical bodies

### Requirement: Reject reuse of an idempotency key for a different request

The system SHALL reject a request that reuses a known idempotency key but carries
request content different from the original request recorded for that key, and
SHALL NOT change any count.

#### Scenario: Same key with a different guest is rejected

- **WHEN** a client reuses an idempotency key that was recorded for one guest but sends a different guest name
- **THEN** the system responds `409 Conflict` indicating the key was already used for a different request, and no count changes

### Requirement: Forget idempotency keys after a bounded window

The system SHALL retain idempotency-key records for a bounded, configurable
retention window and MAY forget a key after the window elapses. A request bearing
a key that is no longer retained SHALL be treated as a new request. Deduplication
SHALL apply across all keys retained within the window, not only the most recently
seen key.

#### Scenario: Reused key counts again after the retention window

- **WHEN** a client reuses an idempotency key after that key's retention window has elapsed and the key is no longer retained
- **THEN** the request is treated as new and the guest's count increases by one

#### Scenario: Deduplication spans multiple retained keys

- **WHEN** a guest is greeted with keys `K1`, then `K2`, then `K1` is replayed, all within the retention window
- **THEN** the `K1` replay is recognized as a replay and does not change the count

### Requirement: Report transient storage failures as retryable

The system SHALL respond with a retryable error when it cannot reach or complete a
write to its persistent store due to a transient condition (such as throttling or
timeout), and SHALL NOT report such a condition as a permanent client error.

#### Scenario: Storage throttling yields a retryable response

- **WHEN** the persistent store rejects the write with a transient/throttling condition
- **THEN** the system responds `503 Service Unavailable` indicating the client may retry (optionally with a `Retry-After` hint), and no count is reported as changed
