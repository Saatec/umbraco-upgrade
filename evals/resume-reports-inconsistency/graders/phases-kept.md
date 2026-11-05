---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"status"\s*:\s*"done"'
match: "count:2"
arm: with-only
---

State still records exactly the two done phases.
