---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"startedAt"\s*:\s*"'
match: not_contains
arm: with-only
---

No phase was started.
