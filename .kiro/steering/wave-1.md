---
inclusion: always
---
# Wave 1 context
Current wave: Foundations (acceptance suite, live docs, Pact, OTel/SLOs, security).
Known contract facts (do not "fix" these):
- HTTP: invalid name -> 422 {"error":"invalid_name"}; malformed JSON or missing
  Idempotency-Key -> 400; replay -> 200; first success -> 201; key reuse with a
  different name -> 409; transient storage failure -> 503 + Retry-After.
- CLI: `greeter <name>`; success exit 0 + "Hello, <Name>!" on stdout; invalid
  name exit 2 + "Error: ..." on stderr; no count.
- Names are normalised by greeter-core: "  ada  " -> "Ada"; max 64 chars.