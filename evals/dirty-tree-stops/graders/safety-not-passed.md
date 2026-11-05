---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"safety"\s*:\s*\{\s*"status"\s*:\s*"passed"'
match: not_contains
arm: with-only
---

Gate 3 did not pass.
