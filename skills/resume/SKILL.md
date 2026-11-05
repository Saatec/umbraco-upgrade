---
name: resume
description: Resume an interrupted Umbraco upgrade. Compares the recorded state with the repository and the project files, reports every difference and asks before acting, then continues from where the upgrade stopped.
argument-hint: [project-path]
arguments: [path]
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:resume

Arguments as typed: `$ARGUMENTS`

## 1. Validate the arguments

If more than one argument was given, stop and print the usage line below.

Run (from the session's working directory):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-UpgradeArguments.ps1" -Command resume -Path "$path"
```

- If `ok` is false, show each error message exactly, show the usage line, and stop.
- Show any warnings to the user before continuing.
- Use `projectRoot` from the output as the project path for every later step.

Usage: `/umbraco-upgrade:resume [project-path]`, for example `/umbraco-upgrade:resume` or `/umbraco-upgrade:resume C:\src\MySite`.

## 2. Reconcile, then continue

Load the `umbraco-upgrade:upgrade-state` skill with the Skill tool and follow its section "Resume reconciliation" with:

- project root: `projectRoot` from step 1
- session id: `${CLAUDE_SESSION_ID}`
- plugin data directory: `${CLAUDE_PLUGIN_DATA}`

If reconciliation reports any mismatch, it stops and asks; nothing is repaired or repeated. When state and reality agree, it hands over to the `umbraco-upgrade:upgrade-workflow` skill at the recorded position.
