---
type: regex
target: { source: file, path: .umbraco-upgrade/evidence/discovery/inventory.json }
pattern: 'FAKE-SECRET-FOR-TESTS'
match: not_contains
arm: with-only
---

The discovery evidence is redacted.
