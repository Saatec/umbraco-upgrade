---
description: E5. /umbraco-upgrade:plan 17 on a near-default Umbraco 13 site plans an in-place upgrade with at most two middle phases and no backoffice phase.
expected_outcome: plan.md exists; state.json selects the in-place strategy and has phase P1 and at most P2, none in the packages-backoffice area.
tags: [e5, planning, near-default]
max_turns: 150
timeout_seconds: 2400
allowed_tools: [Read, Glob, Grep, Skill, Bash, Write, Edit, WebFetch, Agent]
append_system_prompt: "This run is unattended. When the umbraco-upgrade workflow asks the user a question, use these answers and continue: for the .umbraco-upgrade folder choose exclude-local; the detected source version is correct; accept the recommended upgrade path. For any other question, choose the option the workflow recommends and record it as a decision."
---

/umbraco-upgrade:plan 17
