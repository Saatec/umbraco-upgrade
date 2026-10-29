---
name: upgrade-planning
description: Internal gate 4 (plan approval) for the umbraco-upgrade workflow. Checks package compatibility, composes phases from discovery and the selected path, writes the plan, risks, and compatibility matrix, and requests approval. Loaded by the upgrade-workflow skill.
user-invocable: false
---

# Gate 4: Plan approval

Templates: `${CLAUDE_PLUGIN_ROOT}/skills/upgrade-planning/templates/` (`plan.md`, `inventory.md`, `compatibility.md`, `risks.md`, `decisions.md`). Write the filled files into `.umbraco-upgrade/`.

Scripts run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`. Read `ok` and the messages of every script.

## 1. Package compatibility

`Test-PackageCompatibility.ps1 -ProjectRoot "<root>" -DataDir "${CLAUDE_PLUGIN_DATA}"`. It classifies every direct package reference for the target major from NuGet metadata and writes `evidence/planning/package-compatibility.json`. It fires the package patterns (`pkg.no-target-version`, `pkg.framework-only-libs`, `pkg.renamed-community`).

- `not-found` packages: ask the user where each comes from. Never guess a public package with a similar name.
- `unreachable` packages: their status stays unknown; list them as a risk.

## 2. Compose the phases

`Get-PhaseComposition.ps1 -ProjectRoot "<root>"`. It reads discovery, the selected path, and the package results, and writes the proposal to `evidence/planning/phase-composition.json` and the phase list to `tmp/phases.json`. Its rules (design rules, not version facts) are in `${CLAUDE_PLUGIN_ROOT}/knowledge/planning/phase-rules.json`:

- An area becomes a phase only when one of its detectors fired, or when the path has a mandatory step there (packages and framework for every step, a database migration for every step that changes the database, templates rebuilt when the path builds a new codebase).
- Order: framework, packages, custom code, backoffice, configuration and integrations, content conversions, then the database migration of the step. A step that builds a new codebase migrates its database right after the new project. Functional verification and the deployment rehearsal close the plan when they apply.
- Splitting: a high-difficulty pattern gets its own phase; a group above the volume thresholds splits; work that spans several path steps gets a phase in each step.
- A near-default project gets a framework phase and a database phase per path step.

Review the proposal. You may merge, rename, or reorder phases only with a reason written in `plan.md`. Never drop a pattern, a mandatory phase, or a criterion. Add a criterion for every documented step in `compatibility.md` that no phase covers yet, with its source. Then record the phases: `state.ps1 phases -ProjectRoot "<root>" -JsonFile "<root>/.umbraco-upgrade/tmp/phases.json"`.

## 3. Decisions and unresolved items

- Every entry in the proposal's `decisions` (patterns that need the user's decision, and detect-and-flag patterns) becomes an unresolved item: `state.ps1 unresolved -Item "<what needs deciding>" -Pattern <id>`, with the options from `Get-PatternGuidance.ps1 -ProjectRoot "<root>" -PatternId <id>` and their sources as the question in `plan.md`.
- Packages without a release for the target are decision points (replace, fork, rewrite, or drop), each with what it would lose.
- Never plan to remove, stub, or disable custom functionality. Removal of a feature is planned only as an option for the user to choose.

## 4. Risks and compatibility

- `risks.md` from the template. Always include: every version fact the plan relies on that is not verified (secondary or unverified, named one by one); the documented risks of the selected path (for example a long data migration); each high-difficulty pattern; each handling option still marked hypothesis that the plan relies on; package decision points; integrations that cannot be tested locally; and detection limits (the unclassified files, and patterns the registry cannot detect statically).
- `compatibility.md`: add the package table from step 1 and, for each detected pattern, the impacts the upgrade crosses with their sources (`Get-PatternGuidance.ps1`).

## 5. Write the plan

`plan.md` from the template: summary, version facts with their status, the selected path with alternatives, gate 3 (done or what it will do), each phase with its step, owner skill, patterns, the approvals it will ask for, and its acceptance criteria (automated or manual, with the evidence each needs), the decisions the user must make, the risks summary, the rollback reference, and how execution works. Keep every file free of secrets and of code copied from the project.

## 6. Request approval

- Upgrade mode: `state.ps1 request-plan-approval -ProjectRoot "<root>"`. Give the user a short summary (phases, decisions needed, key risks) and ask, following the approval protocol. **Stop and wait.** Execution starts only after an explicit approval in chat (see the workflow skill).
- Plan mode: `state.ps1 request-plan-approval -ProjectRoot "<root>"` records the plan hash. Tell the user where the plan is and that approval and execution happen through `/umbraco-upgrade:start`. Stop.
