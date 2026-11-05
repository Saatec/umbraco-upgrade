---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"lts"\s*:\s*\{\s*"value"\s*:\s*true'
match: not_contains
arm: with-only
---

No LTS status was invented for the unknown target.
