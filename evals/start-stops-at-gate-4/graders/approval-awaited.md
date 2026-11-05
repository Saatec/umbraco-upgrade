---
type: regex
target: { source: file, path: .umbraco-upgrade/state.json }
pattern: '"planApproval"\s*:\s*\{\s*"status"\s*:\s*"awaiting-approval"'
arm: with-only
---

Gate 4 waits for the user's approval.
