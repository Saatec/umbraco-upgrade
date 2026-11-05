---
description: E10. /umbraco-upgrade:plan writes only inside .umbraco-upgrade/: no project file, no .gitignore or .git/info/exclude edit, and no branch, even when the user picks the gitignore folder policy.
expected_outcome: plan.md exists; .gitignore and .git/info/exclude do not mention .umbraco-upgrade; no upgrade branch exists and New-UpgradeBranch.ps1 never ran; no file outside .umbraco-upgrade/ was written or edited; the folder policy is recorded only.
tags: [e10, plan, read-only]
max_turns: 150
timeout_seconds: 2400
allowed_tools: [Read, Glob, Grep, Skill, Bash, Write, Edit, WebFetch, Agent]
append_system_prompt: "This run is unattended. When the umbraco-upgrade workflow asks the user a question, use these answers and continue: for the .umbraco-upgrade folder choose gitignore; the detected source version is correct; accept the recommended upgrade path. For any other question, choose the option the workflow recommends and record it as a decision."
---

/umbraco-upgrade:plan 17
