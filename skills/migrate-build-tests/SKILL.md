---
name: migrate-build-tests
description: Internal phase skill of the umbraco-upgrade workflow for build, view precompilation, automated tests, and functional verification phases with manual checklists. Loaded during plan execution.
user-invocable: false
---

# Build, test, and functional verification phases

Used for phases with area `build-tests` or `functional-verification`. These two areas share one skill: both check the result of the earlier phases, use the same scripts and checklists, and hand evidence to the independent verifier. Patterns that can break at runtime while the build passes (raw SQL on internal tables, configuration reads, access rules, picker values, implicit dependencies) add their checks here.

Follow [migration-rules.md](../upgrade-workflow/references/migration-rules.md). The core rule: **Never remove, stub, or disable custom functionality to make the project compile. If something cannot be migrated directly, record it as unresolved with a proposed approach (port, replace, or redesign) and ask.** This includes tests: never delete, skip, or weaken a failing test to make the suite pass.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

## 1. Build and tests

1. `Test-Build.ps1 -ProjectRoot "<root>" -PhaseId <P> -Precompile -Test` (drop `-Precompile` only when the models mode in use requires runtime compilation, and say so).
2. Read the summary: errors, warnings, test results. Fix causes in the code the earlier phases changed; a failing test means behavior changed. Record a test that cannot pass as an unresolved item with a proposal.
3. Implicit dependencies (`pkg.implicit-transitive`): add explicit package references at versions compatible with the target.

## 2. Functional verification checklist

Build the checklist from the phase's criteria and the patterns of the project, then ask the user to run it on the local site against the migrated local copy. Cover what applies:

- backoffice login and a typical task for each user group; permissions and start nodes
- each content type renders; media, forms, and search work
- each custom backoffice extension loads, edits, and saves
- member login, registration, password reset, protected pages and media
- external integrations and scheduled jobs (sandbox or test endpoints only)
- custom routes, content finders, not-found and error pages
- the site log shows no new errors after browsing

Record what the user checked and their words with `Write-Evidence.ps1 -Folder <P> -Name checklist.md -Text "..."`. Mark only what they confirmed.

## 3. Independent check

Delegate to the `umbraco-upgrade:independent-verifier` agent with the project root and the phase id. Save its report as evidence and resolve every criterion it does not confirm.

## 4. Criteria

Record each criterion with its evidence. Hand back to the phase loop for the checkpoint.

## Never

- Report success from a build alone.
- Skip, delete, or weaken tests or checks to make a phase pass.
- Mark a manual criterion met without the user's confirmation.
