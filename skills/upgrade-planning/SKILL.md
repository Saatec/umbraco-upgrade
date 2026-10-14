---
name: upgrade-planning
description: Internal gate 4 (plan approval) for the umbraco-upgrade workflow. Composes phases, acceptance criteria, and risks, writes the plan, and requests approval. Loaded by the upgrade-workflow skill.
user-invocable: false
---

# Gate 4: Plan approval

Templates (minimal in this plugin version): `${CLAUDE_PLUGIN_ROOT}/skills/upgrade-planning/templates/` (`plan.md`, `inventory.md`, `compatibility.md`, `risks.md`, `decisions.md`). Write the filled files into `.umbraco-upgrade/`.

## 1. Compose the phases

Phases come from discovery, not from a fixed list.

1. **Include an area** only when a detector in that area fired, or the upgrade has a step that applies to every project (the core packages and target framework always change in a major upgrade). Areas: `application-framework`, `content-database`, `custom-code`, `packages-backoffice`, `config-auth-integrations`, `build-tests`, `functional-verification`, `deployment-rehearsal`.
2. **Order** by dependency: application and framework, then packages, then custom code, then backoffice, then configuration and integrations, then build and tests, then functional verification, then deployment rehearsal. Database steps go where the selected path puts them; while path selection is pending, place one provisional database phase after the framework phase and say so.
3. **Split** an area when it contains a high-difficulty pattern (AngularJS backoffice code going to v14 or later gets its own phase) or when its hits exceed 25 occurrences or 15 files.
4. **Acceptance criteria** for each phase: from the pattern handling, from generic build and runtime checks, and (later) from the documented steps for the versions involved. Mark each criterion `automated` or `manual` and name the evidence it needs. A successful build alone never satisfies a phase.
5. **Unresolved items.** Anything that cannot be migrated directly gets `state.ps1 unresolved -Item "<text>" -Pattern <id> -Proposal port|replace|redesign` and a question in the plan. Never plan to remove, stub, or disable custom functionality.

A near-default project (no customization detectors fired) gets few phases. A heavily customized project gets more.

Write the phases as JSON to `.umbraco-upgrade/tmp/phases.json` (an array of objects with `id`, `title`, `area`, `patterns`, `acceptanceCriteria` [`id`, `text`, `verification`]) and record them: `state.ps1 phases -ProjectRoot "<root>" -JsonFile "<root>/.umbraco-upgrade/tmp/phases.json"`.

## 2. Write the plan files

- `plan.md`: summary, source and target (unverified), **"Path selection: pending (not available in this plugin version)"**, phases with acceptance criteria, gate 3 summary (upgrade mode) or what gate 3 will do (plan mode), rollback reference (`rollback.md`), unresolved items with questions, and what happens on approval.
- `risks.md`: one row per risk with likelihood, impact, mitigation, and owner phase. Always include: unverified version facts, path selection pending, patterns this version does not detect.
- Update `inventory.md`, `compatibility.md`, and `decisions.md` if anything changed.

Keep every file free of secrets and of code copied from the project.

## 3. Request approval

- Upgrade mode: `state.ps1 request-plan-approval -ProjectRoot "<root>"`. Then give the user a short summary (phases, unresolved items, key risks) and ask, following the approval protocol in the workflow skill. **Stop and wait.**
- Plan mode: `state.ps1 request-plan-approval -ProjectRoot "<root>"` records the plan hash. Tell the user where the plan is and that approval and execution happen through `/umbraco-upgrade:start`. Stop.

Plan execution is not available in this plugin version. Never start a phase.
