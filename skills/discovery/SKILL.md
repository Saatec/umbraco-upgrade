---
name: discovery
description: Internal gate 1 (discovery) for the umbraco-upgrade workflow. Read-only inspection of an Umbraco project. Loaded by the upgrade-workflow skill.
user-invocable: false
---

# Gate 1: Discovery

Read-only. Nothing outside `.umbraco-upgrade/` changes. Do not build or run the project and do not connect to any database.

Scripts are run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## Steps

1. **Create the state.** `state.ps1 init -ProjectRoot "<root>" -Mode <upgrade|plan> -Target "<target>"`. It records `git status` before writing anything. If it reports that state exists, stop and tell the user (resume is not available in this version).
2. **Activate the hooks for an outside project.** If the project root is not the session's working directory or below it, run `state.ps1 session-marker -ProjectRoot "<root>" -SessionId "<session id>" -DataDir "<plugin data dir>"`. Without the marker the safety hooks would not see this project.
3. **Explain the state folder** and ask for the folder policy (see the workflow skill, "First run").
4. **Run discovery.** `Invoke-Discovery.ps1 -ProjectRoot "<root>"`. It writes redacted evidence to `.umbraco-upgrade/evidence/discovery/` (`version.json`, `inventory.json`, `patterns.json`, `database.json`) and updates the state's `source` and `project` sections. Read the summary it prints. For detail, read the evidence files; they contain no secrets.
5. **Review the version signals** in `evidence/discovery/version.json`:
   - If `version.needsConfirmation` is true or `conflicts` is not empty, show the user each signal (kind, file, version) and ask which version is installed. Record the answer in gate 2.
   - A configuration status key that differs from the package version can mean the database was not upgraded with the code. Point this out.
6. **Review the patterns** in `evidence/discovery/patterns.json` ([references/pattern-registry.md](references/pattern-registry.md) explains the registry):
   - `patterns`: customizations found. They drive the phases of the plan.
   - `baselineSignals`: signals that default installations also have (startup shape, view compilation settings, database engine, secrets in configuration, extensions of the web components backoffice). They add mandatory work, never count as customizations, and secrets among them are always flagged.
   - `requiresPackageMetadata`: patterns classified at gate 4 from NuGet metadata.
   - `unclassified`: files that use CMS namespaces but matched no pattern. List them as "needs classification". When there are more than about 30 of them, or a pattern has more than about 100 hits, delegate the classification to the `umbraco-upgrade:inventory-analyst` agent (give it the project root and the list) and use its summary.
7. **Write `.umbraco-upgrade/inventory.md`** from `${CLAUDE_PLUGIN_ROOT}/skills/upgrade-planning/templates/inventory.md`. Fill it only from the evidence. Mark anything not detected as "not detected", not as "absent": a detector that did not fire proves nothing.
8. **Pass the gate.** `state.ps1 gate -ProjectRoot "<root>" -Gate discovery -Status passed -Evidence "inventory.md"`.

## Never

- Print configuration files directly. Use `Read-RedactedConfig.ps1 -Path <file>` when you need to see one. The safety hook blocks direct dumps of secret-bearing files.
- Treat a missing detector hit as proof that a customization does not exist.
- Copy code from the project into the inventory beyond the one-line redacted snippets in the evidence.
