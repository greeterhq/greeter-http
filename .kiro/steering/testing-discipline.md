---
inclusion: always
---
# Testing discipline
- TDD: write the failing test before the implementation. Show it red for the
  right reason (NameError / expectation failure, not a syntax error).
- NEVER edit a file under spec/ or features/ to make it pass. If a test looks
  wrong, stop and say so.
- Every OpenSpec scenario maps to exactly one Cucumber scenario or RSpec example,
  tagged @requirement-<requirement-slug> and @scenario-<scenario-slug>.
- OpenSpec (openspec/) is the only spec system. Do not create Kiro Specs.
- Never change greeter-core in Wave 1. If a task seems to need it, stop.
- Synthetic traffic against any deployed environment MUST send
  X-Greeter-Synthetic: true.
- Slugs: lowercase the OpenSpec heading, replace non-alphanumerics with "-",
  squeeze repeats, strip leading/trailing "-".