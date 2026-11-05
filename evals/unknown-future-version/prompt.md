---
description: E7. /umbraco-upgrade:plan 25 for a major version that does not exist stops gracefully at gate 2 or marks every fact unverified, and suggests a knowledge refresh. It invents no LTS status, .NET version, or support date.
expected_outcome: Gate 2 did not pass; state.json records no LTS value of true for the target; the reply says 25 is unknown or unverified and suggests /umbraco-upgrade:update-knowledge or confirming facts from official pages.
tags: [e7, path, unknown-version]
max_turns: 150
timeout_seconds: 2400
allowed_tools: [Read, Glob, Grep, Skill, Bash, Write, Edit, WebFetch, Agent]
append_system_prompt: "This run is unattended. When the umbraco-upgrade workflow asks the user a question, use these answers and continue: for the .umbraco-upgrade folder choose exclude-local; the detected source version is correct; accept the recommended upgrade path. For any other question, choose the option the workflow recommends and record it as a decision."
---

/umbraco-upgrade:plan 25
