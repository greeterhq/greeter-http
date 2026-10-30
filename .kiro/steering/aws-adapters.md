---
inclusion: fileMatch
fileMatchPattern: ["lib/greeter_http/adapters/**/*.rb", "infra/**/*"]
---
# AWS adapter rules
- Aws::DynamoDB::Client is always injected, never constructed in an adapter.
- Map every Aws::*::Errors::ServiceError to a domain-neutral error at the adapter boundary. Nothing named Aws:: crosses into application/.
- IAM: least privilege, no "*" in Action or Resource.
- Log the guest name only as a SHA-256 hash.