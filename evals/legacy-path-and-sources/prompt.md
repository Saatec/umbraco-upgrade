---
description: E6. /umbraco-upgrade:plan 17 on an Umbraco 7.15 site selects a path that is not in place, records the alternatives, and cites a source URL and the version it applies to for every decision.
expected_outcome: state.json has a selected path whose strategy is not in-place and at least one rejected alternative; decisions.md cites official documentation URLs with the version each applies to.
tags: [e6, path, sources]
max_turns: 150
timeout_seconds: 2400
allowed_tools: [Read, Glob, Grep, Skill, Bash, Write, Edit, WebFetch, Agent]
append_system_prompt: "This run is unattended. When the umbraco-upgrade workflow asks the user a question, use these answers and continue: for the .umbraco-upgrade folder choose exclude-local; the detected source version is correct; accept the recommended upgrade path. For any other question, choose the option the workflow recommends and record it as a decision."
---

/umbraco-upgrade:plan 17
