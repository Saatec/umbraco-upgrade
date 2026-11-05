---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"strategy"\s*:\s*"in-place"'
arm: with-only
---

The selected path is in place.
