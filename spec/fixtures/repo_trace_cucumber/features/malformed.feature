Feature: Malformed tag

  @requirement-BadSlugValue @scenario-ok-scenario
  Scenario: Carries a requirement tag that is not a slug
    Given a step for "nobody" that passes
