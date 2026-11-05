---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"stateFolderPolicy"\s*:\s*"gitignore"'
arm: with-only
---

The folder policy is recorded, to be applied by /umbraco-upgrade:start.
