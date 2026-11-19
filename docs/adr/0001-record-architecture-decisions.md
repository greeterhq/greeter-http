# 1. Record architecture decisions

## Status

Accepted (2026-11-19)

## Context

Decisions that shape this repository (what is generated and what is written by
hand, which test tools run where, what ships in the Lambda bundle) are made in
pull requests and OpenSpec changes. A year later the reason is hard to find: the
design document of an archived change explains one decision among many, and the
pull request thread is not part of the repository.

## Decision

Each decision that shapes the repository is recorded as one Markdown file in
`docs/adr/`, in the MADR style, with these headings: Status, Context, Decision,
Consequences.

- Files are named `NNNN-short-title.md`, numbered from 0001 in the order they
  are accepted.
- An accepted record is not edited, except to change its Status (for example to
  "Superseded by 0007"). A reversed decision gets a new record that links to the
  one it replaces.
- A record is short: the forces, the choice, and what follows from it.

## Consequences

- The reasons for a decision stay next to the code and are found with `git log`
  and `grep`, not by reading old pull requests.
- Writing a record is one more step in a change that makes such a decision. It is
  checked only for shape (`spec/docs/adr_spec.rb`), not for quality.
- The record is the place to point to from a design when the choice is
  expected to outlive the change.
