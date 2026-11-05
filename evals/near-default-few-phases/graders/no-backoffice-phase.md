---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"area"\s*:\s*"packages-backoffice"'
match: not_contains
arm: with-only
---

No backoffice phase without a backoffice customization.
