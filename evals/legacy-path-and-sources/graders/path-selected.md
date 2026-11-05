---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"selection"\s*:\s*"selected"'
arm: with-only
---

An upgrade path was selected.
