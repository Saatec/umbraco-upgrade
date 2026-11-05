---
name: update-knowledge
description: Refresh the plugin's Umbraco version knowledge (versions, LTS status, .NET requirements, upgrade-path rules, package mappings) from official sources into the plugin data directory, and produce a diff for the plugin maintainer.
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:update-knowledge

Arguments as typed: `$ARGUMENTS`

This command takes no arguments. If any were given, say so, show the usage line `/umbraco-upgrade:update-knowledge`, and stop.

It reads public sources only (NuGet, the Umbraco documentation site and its GitHub branches, releases.umbraco.com, the .NET release metadata, and endoflife.date as a labelled secondary source) and writes only to `${CLAUDE_PLUGIN_DATA}/knowledge/`. It never writes to the plugin's install directory and never touches a project.

## 1. Refresh

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Update-Knowledge.ps1" -DataDir "${CLAUDE_PLUGIN_DATA}"
```

If `ok` is false, show `error` and stop. Nothing was written.

## 2. Report

Summarize for the user, from the script output (the full report is in `report`):

- `valueChanges`: each fact whose value changed, old and new value, source
- `newMajors`: majors added from NuGet. Say clearly that their LTS status, support dates, minimum upgrade-from version, data migrations, and path rules are **unverified**
- `upcoming`: majors that are not released yet (not added): prereleases only on NuGet, or a pre-release documentation space (`docsSpace`, for example a `<n>.latest` space for the next major)
- `needsReview`: facts whose evidence was not found on the source page any more, or that a source now contradicts
- `unreachable`: sources that could not be fetched (those facts kept their previous values and dates)
- `refreshedDataInUse`: whether upgrades will use the refreshed data now. The refreshed copy is used only when it is newer than the knowledge shipped with the plugin
- the paths of `refresh-report.md` and `maintainer.patch`

## 3. Check what needs review

For each `needsReview` item and each new major, load the `umbraco-upgrade:doc-retrieval` skill and read the cited official page (or the new major's upgrade and breaking-changes pages). Tell the user what the page says now, with citations. Do not edit the knowledge files by hand: the refreshed files are written only by the script, and facts that need review stay marked until a maintainer updates the baseline. Facts confirmed by a user for one project are recorded in that project's `.umbraco-upgrade/decisions.md` during an upgrade, not in the knowledge.

## 4. For plugin maintainers

`maintainer.patch` is a unified diff from the knowledge shipped in the plugin to the refreshed files. In a clone of the plugin repository: `git apply <path to maintainer.patch>`, review every changed fact against its source, resolve needs-review items, run the test suite, and commit.
