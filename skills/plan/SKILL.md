---
name: plan
description: Discovery and an upgrade plan for an Umbraco CMS project, without changing anything outside .umbraco-upgrade/.
argument-hint: <target-version> [project-path]
arguments: [target, path]
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:plan

Arguments as typed: `$ARGUMENTS`

## 1. Validate the arguments

If more than two arguments were given, stop and print the usage line below.

Run (from the session's working directory):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-UpgradeArguments.ps1" -Command plan -Target "$target" -Path "$path"
```

If no project path was given, leave out `-Path` and its empty value: Windows PowerShell drops an empty argument, and the script then stops with a missing-argument error.

- If `ok` is false, show each error message exactly, show the usage line, and stop. Do not create anything.
- Show any warnings to the user before continuing.
- Use `projectRoot` from the output as the project path for every later step.

Usage: `/umbraco-upgrade:plan <target-version> [project-path]`, for example `/umbraco-upgrade:plan 17`.

## 2. Run the workflow

Load the `umbraco-upgrade:upgrade-workflow` skill with the Skill tool and follow it in **plan mode** with:

- project root: `projectRoot` from step 1
- requested target: `target.requested` from step 1
- session id: `${CLAUDE_SESSION_ID}`
- plugin data directory: `${CLAUDE_PLUGIN_DATA}`

Plan mode runs gates 1, 2, and 4. Gate 3 is described in the plan but not executed, because it creates a branch. Nothing outside `.umbraco-upgrade/` changes: no branch, no `.gitignore` or `.git/info/exclude` edit, no project file. Stop after the plan is written.
