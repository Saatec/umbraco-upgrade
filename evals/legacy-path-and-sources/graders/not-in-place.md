---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"strategy"\s*:\s*"in-place"'
match: not_contains
arm: with-only
---

Umbraco 7 is not upgraded in place to 17.
