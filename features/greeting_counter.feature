Feature: Greeting counter over HTTP

  Greets a guest over HTTP and returns a per-guest greeting count, with
  idempotent, non-double-counting behavior under client retries. Each scenario
  below corresponds to exactly one scenario in the greeting-counter spec delta
  and drives the Lambda handler adapter in-process with built API Gateway v2
  events and an in-memory counter.

  # Requirement: Greet a guest and return a running count

  @requirement-greet-a-guest-and-return-a-running-count @scenario-first-greeting-for-a-new-guest
  Scenario: First greeting for a new guest
    When a client greets "alice bonsu" with a fresh idempotency key
    Then the response status is 201
    And the response guest name is "Alice Bonsu"
    And the response count is 1

  @requirement-greet-a-guest-and-return-a-running-count @scenario-subsequent-greeting-for-an-existing-guest
  Scenario: Subsequent greeting for an existing guest
    Given the guest "alice bonsu" has already been greeted 1 time with fresh keys
    When a client greets "alice bonsu" with a fresh idempotency key
    Then the response status is 201
    And the response count is 2

  @requirement-greet-a-guest-and-return-a-running-count @scenario-names-differing-only-by-case-or-whitespace-share-a-count
  Scenario: Names differing only by case or whitespace share a count
    Given a client greets "  alice bonsu " with a fresh idempotency key
    When a client greets "Alice Bonsu" with a fresh idempotency key
    Then the response status is 201
    And the response count is 2

  # Requirement: Reject invalid guest names

  @requirement-reject-invalid-guest-names @scenario-empty-name-is-rejected
  Scenario: Empty name is rejected
    When a client greets "" with a fresh idempotency key
    Then the response status is 422
    And no guest count has changed

  @requirement-reject-invalid-guest-names @scenario-over-long-name-is-rejected
  Scenario: Over-long name is rejected
    When a client greets a name of 100 characters with a fresh idempotency key
    Then the response status is 422
    And no guest count has changed

  # Requirement: Require a client-supplied idempotency key

  @requirement-require-a-client-supplied-idempotency-key @scenario-missing-idempotency-key-is-rejected
  Scenario: Missing idempotency key is rejected
    When a client greets "alice bonsu" with no idempotency key
    Then the response status is 400
    And no guest count has changed

  # Requirement: Replaying an idempotency key returns the original result

  @requirement-replaying-an-idempotency-key-returns-the-original-result @scenario-retry-with-the-same-key-does-not-double-count
  Scenario: Retry with the same key does not double-count
    Given a client greets "alice bonsu" with idempotency key "K1"
    When a client resends the greeting for "alice bonsu" with idempotency key "K1"
    Then the response count equals the first response count
    And the stored count for "alice bonsu" is unchanged by the retry

  @requirement-replaying-an-idempotency-key-returns-the-original-result @scenario-replay-returns-the-original-count-even-after-other-greetings
  Scenario: Replay returns the original count even after other greetings
    Given a client greets "alice bonsu" with idempotency key "K1" producing count 1
    And the same guest is greeted to a higher count with other fresh keys
    When a client resends the greeting for "alice bonsu" with idempotency key "K1"
    Then the response status is 200
    And the response count is 1

  @requirement-replaying-an-idempotency-key-returns-the-original-result @scenario-replay-is-distinguishable-from-a-first-success-by-status
  Scenario: Replay is distinguishable from a first success by status
    Given a client greets "alice bonsu" with idempotency key "K1"
    When a client resends the greeting for "alice bonsu" with idempotency key "K1"
    Then the first response status is 201 and the replay response status is 200
    And both response bodies are identical

  # Requirement: Reject reuse of an idempotency key for a different request

  @requirement-reject-reuse-of-an-idempotency-key-for-a-different-request @scenario-same-key-with-a-different-guest-is-rejected
  Scenario: Same key with a different guest is rejected
    Given a client greets "alice bonsu" with idempotency key "K1"
    When a client greets "bob stone" with idempotency key "K1"
    Then the response status is 409
    And no guest count has changed

  # Requirement: Forget idempotency keys after a bounded window

  @requirement-forget-idempotency-keys-after-a-bounded-window @scenario-reused-key-counts-again-after-the-retention-window
  Scenario: Reused key counts again after the retention window
    Given a client greets "alice bonsu" with idempotency key "K1"
    When the retention window elapses
    And a client resends the greeting for "alice bonsu" with idempotency key "K1"
    Then the response status is 201
    And the response count is 2

  @requirement-forget-idempotency-keys-after-a-bounded-window @scenario-deduplication-spans-multiple-retained-keys
  Scenario: Deduplication spans multiple retained keys
    Given a client greets "alice bonsu" with idempotency key "K1"
    And a client greets "alice bonsu" with idempotency key "K2"
    When a client resends the greeting for "alice bonsu" with idempotency key "K1"
    Then the response count is 1
    And the stored count for "alice bonsu" is unchanged by the retry

  # Requirement: Report transient storage failures as retryable

  @requirement-report-transient-storage-failures-as-retryable @scenario-storage-throttling-yields-a-retryable-response
  Scenario: Storage throttling yields a retryable response
    Given the persistent store rejects writes with a transient throttling condition
    When a client greets "alice bonsu" with a fresh idempotency key
    Then the response status is 503
    And the response body does not leak internal error details
