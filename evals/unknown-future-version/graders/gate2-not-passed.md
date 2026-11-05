---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"versionPath"\s*:\s*\{\s*"status"\s*:\s*"passed"'
match: not_contains
arm: with-only
---

Gate 2 does not pass on invented facts.
