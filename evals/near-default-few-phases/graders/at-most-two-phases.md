---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"id"\s*:\s*"P3"'
match: not_contains
arm: with-only
---

A near-default site gets at most two middle phases.
