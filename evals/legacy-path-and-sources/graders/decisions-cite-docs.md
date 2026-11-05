---
type: regex
target: { source: file, path: .umbraco-upgrade/decisions.md }
pattern: 'https://(docs\.umbraco\.com|raw\.githubusercontent\.com/umbraco/UmbracoDocs)/'
arm: with-only
---

Decisions cite the official Umbraco documentation.
