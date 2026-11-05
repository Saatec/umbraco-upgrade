---
type: regex
target: { source: file, path: .git/refs/heads/main }
pattern: '^[0-9a-f]{40}'
arm: both
---

The main branch still exists.
