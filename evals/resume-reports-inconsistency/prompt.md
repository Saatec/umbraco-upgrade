---
description: E4. /umbraco-upgrade:resume when state says P2 is done at a commit that HEAD no longer contains. The plugin reports the inconsistency and asks; it repairs nothing and does not re-run or continue a phase.
expected_outcome: Test-StateReality.ps1 ran; no git command changed the branch; no state command touched a phase; state.json still records two done phases; the reply reports that the P2 checkpoint is not part of HEAD and asks the user how to proceed.
tags: [e4, resume, reconciliation]
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash]
append_system_prompt: "This run is unattended. When the umbraco-upgrade workflow asks the user a question, end your turn after asking it."
---

/umbraco-upgrade:resume
