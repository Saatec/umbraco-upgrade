---
name: report
description: Generate or regenerate the Umbraco upgrade report (.umbraco-upgrade/report.md) from the recorded state, evidence, and decisions, at any point of an upgrade.
argument-hint: [project-path]
arguments: [path]
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:report

Arguments as typed: `$ARGUMENTS`

## 1. Validate the arguments

If more than one argument was given, stop and print the usage line below.

Run (from the session's working directory):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-UpgradeArguments.ps1" -Command report -Path "$path"
```

- If `ok` is false, show each error message exactly, show the usage line, and stop.
- Show any warnings to the user before continuing.
- Use `projectRoot` from the output as the project path for every later step.

Usage: `/umbraco-upgrade:report [project-path]`, for example `/umbraco-upgrade:report`.

## 2. Write the report

Load the `umbraco-upgrade:reporting` skill with the Skill tool and follow it with the project root from step 1. It changes nothing but `.umbraco-upgrade/report.md`.
