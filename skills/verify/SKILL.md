---
name: verify
description: Verify an Umbraco upgrade. After the last phase it runs final verification (gate 5) with automated checks, an independent review, and a manual checklist; for an upgrade still in progress it checks what is done so far. Separates what was verified automatically, manually, and not at all.
argument-hint: [project-path]
arguments: [path]
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:verify

Arguments as typed: `$ARGUMENTS`

## 1. Validate the arguments

If more than one argument was given, stop and print the usage line below.

Run (from the session's working directory):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-UpgradeArguments.ps1" -Command verify -Path "$path"
```

- If `ok` is false, show each error message exactly, show the usage line, and stop.
- Show any warnings to the user before continuing.
- Use `projectRoot` from the output as the project path for every later step.

Usage: `/umbraco-upgrade:verify [project-path]`, for example `/umbraco-upgrade:verify`.

## 2. Verify

Load the `umbraco-upgrade:verification` skill with the Skill tool and follow it with:

- project root: `projectRoot` from step 1
- session id: `${CLAUDE_SESSION_ID}`
- plugin data directory: `${CLAUDE_PLUGIN_DATA}`

It decides from state whether this is gate 5 (every phase done or deferred) or an interim check of an upgrade in progress, and it ends with the report.
