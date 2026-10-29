---
type: regex
target: { source: file, path: .umbraco-upgrade/plan.md }
pattern: 'FAKE-SECRET-FOR-TESTS'
match: not_contains
arm: with-only
---

The plan contains no secret value.
