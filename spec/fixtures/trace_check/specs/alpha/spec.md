# alpha Specification

## Purpose

Fixture for spec/trace_check_spec.rb. Not a real capability.

## Requirements

### Requirement: Covered requirement
Tagged by examples/base.rb.

#### Scenario: Covered scenario
- **WHEN** x
- **THEN** y

### Requirement: Uncovered requirement
No example or feature is tagged with this requirement.

#### Scenario: Nobody tests this
- **WHEN** x
- **THEN** y

### Requirement: Same text scenario
The scenario repeats the requirement text.

#### Scenario: Same text scenario
- **WHEN** x
- **THEN** y

### Requirement: Other requirement
Owns a scenario that examples/wrong_scenario.rb uses under the wrong requirement.

#### Scenario: Only under other
- **WHEN** x
- **THEN** y

### Requirement: Feature covered
Tagged by features/base.feature.

#### Scenario: Feature covered
- **WHEN** x
- **THEN** y
