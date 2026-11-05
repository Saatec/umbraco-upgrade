---
description: E1. /umbraco-upgrade:start runs gates 1 to 4 on a near-default site and stops at gate 4 for approval. Nothing is executed and no project file changes.
expected_outcome: plan.md exists; state.json shows plan approval awaiting-approval, no approval recorded, and no phase started; no project file outside .umbraco-upgrade/ was written or edited; the reply asks the user to approve, change, or reject the plan.
tags: [e1, workflow, approval]
max_turns: 150
timeout_seconds: 2400
allowed_tools: [Read, Glob, Grep, Skill, Bash, Write, Edit, WebFetch, Agent]
append_system_prompt: "This run is unattended. When the umbraco-upgrade workflow asks the user a question, use these answers and continue: for the .umbraco-upgrade folder choose exclude-local; the detected source version is correct; accept the recommended upgrade path and the default branch name; there is no restored local database copy, and a production backup exists. Never approve the plan or any other approval yourself: when the workflow asks for an approval, end your turn."
---

/umbraco-upgrade:start 17
