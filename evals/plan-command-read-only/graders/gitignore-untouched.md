---
type: regex
target: { source: file, path: .gitignore }
pattern: 'umbraco-upgrade'
match: not_contains
arm: both
---

Plan mode never edits .gitignore; the gitignore policy is applied only after gate 3 of /umbraco-upgrade:start.
