---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: 'FAKE-SECRET-FOR-TESTS'
match: not_contains
arm: with-only
---

The upgrade state holds no secret value.
