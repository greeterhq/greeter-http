# synthetic-traffic Specification

## Purpose

Keeps traffic that this repository's own tools send to a deployed stage out of
real guest counts and real-user log views, by marking every such request as
synthetic.

## Requirements

### Requirement: Repository tools mark deployed-stage traffic as synthetic
Every tool in this repository that sends requests to a deployed stage SHALL
send the header `X-Greeter-Synthetic: true` on every request it makes,
whatever the request's body or expected status.

#### Scenario: Post-deploy smoke script marks every request
- **WHEN** the post-deploy smoke script runs against a base URL and completes both of its checks (the greeting that is sent twice and the malformed-JSON request that expects 400)
- **THEN** every request the base URL receives carries `X-Greeter-Synthetic: true`

#### Scenario: Deployed load generator marks every request
- **WHEN** the deployed load generator sends greetings to a base URL
- **THEN** every request the base URL receives carries `X-Greeter-Synthetic: true`
