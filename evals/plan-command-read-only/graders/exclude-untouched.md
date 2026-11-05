---
type: regex
target: { source: file, path: .git/info/exclude }
pattern: 'umbraco-upgrade'
match: not_contains
arm: both
---

Plan mode never edits .git/info/exclude.
