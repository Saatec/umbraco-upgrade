---
name: reporting
description: Internal report writer for the umbraco-upgrade workflow. Assembles .umbraco-upgrade/report.md from state, evidence, and decisions with New-Report.ps1. Loaded by /umbraco-upgrade:report and the verification skill.
user-invocable: false
---

# Report

The report is assembled by a script, so it shows exactly what state and the evidence record. Template: `${CLAUDE_PLUGIN_ROOT}/skills/upgrade-planning/templates/report.md` (the script follows its sections and table headers).

## Steps

1. `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/New-Report.ps1" -ProjectRoot "<root>"`. If `ok` is false, show `error` and stop.
2. Tell the user where `report.md` is, its `status`, and `counts` (verified automatically, verified manually, not verified). If `missingEvidence` is not zero, say that some evidence the state cites is missing and that `/umbraco-upgrade:resume` reports which.
3. Point out the "Not verified" section and the manual follow-ups. Do not summarize anything as verified that the report lists under "Not verified".

## Rules

- Never edit `report.md` by hand, and never add claims the state does not record. To change what the report says, record the missing results (gate 5) or decisions first, then run the script again.
- The report links to evidence and copies none of it; its text is redacted before it is written. Never paste secrets, connection strings, or configuration values into chat when you summarize it.
- The report can be regenerated at any point: plan only, during execution, or after gate 5. Each run replaces `report.md`.
