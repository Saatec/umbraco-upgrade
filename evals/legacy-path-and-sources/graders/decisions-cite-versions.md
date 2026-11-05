---
type: llm
focus: { source: file, path: .umbraco-upgrade/decisions.md }
arm: with-only
---

PASS if every decision in the file lists at least one source URL together with the version that source applies to (the source, an intermediate, or the target version) and a date, or is marked unverified.
FAIL if a decision states a version fact or an upgrade path without any source, or without saying which version its source applies to.
