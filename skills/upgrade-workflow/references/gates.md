# Gates

| Gate | Entry | Work | Exit criteria | Writes |
|---|---|---|---|---|
| 1 Discovery | Arguments valid | `state.ps1 init` (takes the git status snapshot before writing anything), then read-only discovery scripts | Inventory written; every detector result recorded as evidence; unclassified Umbraco usage listed; source version signals reviewed | `.umbraco-upgrade/` only |
| 2 Version and path | Gate 1 passed | Source version from discovery (user confirms when signals conflict); target resolved from NuGet; version knowledge and live documentation; path selection (`version-path` skill) | Exact target, its LTS status and .NET version recorded (user-confirmed from an official page when not in the knowledge); path selected with alternatives; every fact cites its source, the version it applies to, and a date, and keeps its status (verified, secondary, unverified) | `compatibility.md`, `decisions.md`, `evidence/version-path/`, state |
| 3 Safety | Gate 2 passed; upgrade mode only | Git checks; state folder policy; upgrade branch; backup and local database plan; rollback document; guard self-test | Clean tree outside `.umbraco-upgrade/`, branch created, guard proven active, rollback documented | branch, `rollback.md`, state |
| 4 Plan approval | Gate 3 passed (or skipped in plan mode) | Package compatibility from NuGet metadata; phases composed from discovery and the selected path; acceptance criteria, risks, decisions, unresolved items | Plan written; approval requested; **stop and wait** | `plan.md`, `inventory.md`, `compatibility.md`, `risks.md`, `evidence/planning/`, state |
| Execution | Gate 4 approved; upgrade mode only | Phases in plan order through their `migrate-*` skills ([phase-execution.md](phase-execution.md)) | Each phase: criteria met or waived with evidence, checkpoint commit recorded | project files on the upgrade branch, `evidence/<phase>/`, state |
| 5 Final verification | Later plugin version | | | |

## Git status ordering

Gate 1 writes into `.umbraco-upgrade/` before gate 3 checks git status. To keep the check meaningful:

- `state.ps1 init` records a read-only `git status` snapshot before it writes anything (`evidence/discovery/git-status-at-start.json`).
- Gate 3 ignores only paths under `.umbraco-upgrade/` and stops on any other change.

## What each gate must never do

- Gate 1: change any file outside `.umbraco-upgrade/`, connect to a database, build or run the project.
- Gate 2: invent version facts, upgrade paths, or package replacements; present a secondary or unverified fact as verified; choose between close candidates for the user.
- Gate 3: stash, reset, checkout, clean, or commit the user's changes; create a branch when the tree is dirty.
- Gate 4: start executing the plan before the user approves it.
- Execution: remove, stub, or disable custom functionality; run an approval-tier action without a recorded approval; touch any database except the declared local copy.
