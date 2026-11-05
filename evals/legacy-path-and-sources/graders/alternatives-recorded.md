---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"alternatives"\s*:\s*\[\s*\{'
arm: with-only
---

The rejected alternatives are recorded.
