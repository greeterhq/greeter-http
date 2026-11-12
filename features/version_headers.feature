Feature: Version headers on a deployed stage
  Black-box clients can see exactly what is deployed. Runs only when
  GREETER_BASE_URL is set; otherwise the @smoke hook skips it. The request is
  sent with X-Greeter-Synthetic: true so it never touches real guest counts.

  @smoke @requirement-deployed-stage-exposes-version-headers @scenario-smoke-check-on-a-deployed-stage
  Scenario: Smoke check on a deployed stage
    Given the deployed base URL from GREETER_BASE_URL
    When I POST a greeting for "alice bonsu" with a fresh idempotency key
    Then the HTTP status is 201
    And the response header "X-Greeter-Version" is a plain dotted version without a leading "v"
    And the response header "X-Greeter-Core-Version" is present
