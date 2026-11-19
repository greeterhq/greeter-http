Feature: Statuses for Alice Smith

  @requirement-fixture-requirement @scenario-passing-scenario
  Scenario: Passes for Alice Smith
    Given a step for "Alice Smith" that passes

  @requirement-fixture-requirement @scenario-failing-scenario
  Scenario: Fails for Alice Smith
    Given a step for "Alice Smith" that fails

  @requirement-fixture-requirement @scenario-pending-scenario
  Scenario: Pending for Alice Smith
    Given a step for "Alice Smith" that is pending

  @requirement-fixture-requirement @scenario-skipped-scenario
  Scenario: Skipped for Alice Smith
    Given a step for "Alice Smith" that is skipped

  Scenario: Untagged for Alice Smith
    Given a step for "Alice Smith" that passes

  @requirement-fixture-requirement
  Scenario: Only a requirement tag for Alice Smith
    Given a step for "Alice Smith" that passes
