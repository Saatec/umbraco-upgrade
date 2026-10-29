# Execution policy

| Tier | Examples | Rule | Enforcement |
|---|---|---|---|
| Read-only | Inspecting files, running discovery scripts, reading documentation | Always allowed | none needed |
| Reversible | Code and configuration changes on the upgrade branch | Allowed only after gate 3 has passed **and** the plan is approved, on the upgrade branch | The safety hook blocks Write and Edit on project files otherwise |
| Requires approval | Starting plan execution; database snapshots and migrations on the local copy; removing or replacing a package or custom feature; changing CI or deployment configuration; acting outside the project path | Ask first; record the approval in state | `state.ps1 approve`; `Invoke-DatabaseSnapshot.ps1`, `Copy-ConfigValue.ps1`, and `New-Checkpoint.ps1` refuse without their approval; the safety hook asks for several of these |
| Prohibited | Connecting to production or other non-local databases; deploying; force-pushing; rewriting history; deleting branches; discarding uncommitted changes; printing secrets | Never | The safety hook blocks them (exit code 2) |

## When the safety hook blocks something

The tool result starts with `umbraco-upgrade guard [<rule-id>]`. Do not try another way to do the same thing (another shell, a wrapper, a script, an alias). Tell the user what was blocked and why, and ask how they want to proceed.

## Local database

Database work happens only on a local, restored copy that the user declares. The plugin records only `local` or `non-local`, never a connection string.

## Scripts that act during execution

`Test-Build.ps1`, `Copy-ConfigValue.ps1`, `Invoke-DatabaseSnapshot.ps1`, and `New-Checkpoint.ps1` refuse unless the plan is approved and unchanged, gate 3 passed, the project is on the upgrade branch, and the phase is in progress. `Write-Evidence.ps1` writes only under `.umbraco-upgrade/evidence/`, with secrets redacted.
