---
name: start
description: Start an Umbraco CMS major-version upgrade. Runs discovery, version checks, safety setup, and writes a plan, then stops for your approval.
argument-hint: <target-version> [project-path]
arguments: [target, path]
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:start

Arguments as typed: `$ARGUMENTS`

## 1. Validate the arguments

If more than two arguments were given, stop and print the usage line below.

Run (from the session's working directory):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-UpgradeArguments.ps1" -Command start -Target "$target" -Path "$path"
```

- If `ok` is false, show each error message exactly, show the usage line, and stop. Do not create anything.
- Show any warnings to the user before continuing.
- Use `projectRoot` from the output as the project path for every later step.

Usage: `/umbraco-upgrade:start <target-version> [project-path]`, for example `/umbraco-upgrade:start 17` or `/umbraco-upgrade:start 17.2.0 C:\src\MySite`.

## 2. Run the workflow

Load the `umbraco-upgrade:upgrade-workflow` skill with the Skill tool and follow it in **upgrade mode** with:

- project root: `projectRoot` from step 1
- requested target: `target.requested` from step 1
- session id: `${CLAUDE_SESSION_ID}`
- plugin data directory: `${CLAUDE_PLUGIN_DATA}`

The workflow runs gates 1 to 4 and stops at gate 4 for approval. In this plugin version, plan execution is not available: after the user approves, record the approval and stop.
