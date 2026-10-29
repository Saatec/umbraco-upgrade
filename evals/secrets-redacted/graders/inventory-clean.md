---
type: regex
target: { source: file, path: .umbraco-upgrade/inventory.md }
pattern: 'FAKE-SECRET-FOR-TESTS'
match: not_contains
arm: with-only
---

The inventory names configuration keys but never their secret values.
