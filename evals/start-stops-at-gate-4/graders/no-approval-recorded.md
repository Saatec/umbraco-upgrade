---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"action"\s*:\s*"start-plan-execution"'
match: not_contains
arm: with-only
---

No approval to execute the plan was recorded.
