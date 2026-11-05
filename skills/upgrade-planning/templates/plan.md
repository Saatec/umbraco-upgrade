# Upgrade plan: <project name>

Status: awaiting approval | approved | plan only
Mode: upgrade | plan
Created: <UTC date> by umbraco-upgrade <plugin version>

## Summary

- Source: Umbraco <version> (<how determined>)
- Target: Umbraco <exact version> (requested: <target>; resolved from <NuGet or knowledge>)
- Upgrade path: <strategy>, <number> steps (decision <D-xxx>)
- Customizations detected: <count> patterns; baseline signals: <list>
- Phases: <count> (<count> of them high difficulty)
- Decisions you need to make: <count> (see "Decisions needed")
- Approvals execution will ask for: <list of approval actions>

## Version facts

| Fact | Value | Status | Source |
|---|---|---|---|
| LTS status of target | <true or false> | <verified, secondary, unverified> | <URL, version, date> |
| .NET version of target | <tfm> | <status> | <source> |
| End of support of target | <date> | <status> | <source> |

Secondary and unverified facts are not relied on without your confirmation. Details: `compatibility.md` and `decisions.md`.

## Upgrade path

| Step | From | To | Type | Codebase | Data migrations | Rules and sources |
|---|---|---|---|---|---|---|
| S1 | <version> | <version> | <type> | existing or new | <ids> | <rule ids, URLs> |

Alternatives considered: <strategy: reason rejected>.

Code port: <ported at the first step that breaks it (in place) | ported once onto the final codebase (new codebase on the path)>. Alternative: <the other option and when it fits>.

## Gate 3: safety setup

<Upgrade mode: branch, base commit, guard self-test result, local database copy declared yes or no.>
<Plan mode: what gate 3 will check and create when /umbraco-upgrade:start runs.>

Rollback: see `rollback.md`.

## Phases

Proposed by `Get-PhaseComposition.ps1` (details: `evidence/planning/phase-composition.json`). <Any merge, rename, or reorder of the proposal, with its reason.>

### P1 <title> (<area>, step <S1>)

- Owner skill: <migrate-...>
- Patterns: <ids, or "mandatory step">
- Why this phase: <reasons from the proposal>
- Work: <short description, including the handling options under consideration and the documentation to consult>
- Approvals it will ask for: <none, or actions and scopes>
- Acceptance criteria:
  - P1-AC1 <criterion> (automated | manual; evidence: <what>)
- Ends with: a checkpoint commit on the upgrade branch (`New-Checkpoint.ps1`)

<repeat per phase>

## Decisions needed

| Unresolved id | Pattern | Question for you | Options (with sources) |
|---|---|---|---|

## Unresolved items

| ID | Item | Proposed approach | Status |
|---|---|---|---|

## Key risks

See `risks.md`. The main ones: <three to five, one line each>.

## How execution works

- Phases run in this order. Each one starts only when the earlier ones are done or deferred.
- Each phase ends with a checkpoint commit on the upgrade branch and a record in `state.json`.
- Approval-tier actions (database snapshot and migration on the local copy, package removal or replacement, CI or deployment changes, writes outside the project, removing a feature) are asked for one by one and recorded.
- Custom functionality is never removed, stubbed, or disabled to make the project build. What cannot be migrated directly becomes an unresolved item with a proposal and a question.
- Nothing is deployed, force-pushed, or run against a non-local database.
- After the last phase, gate 5 runs the final verification (automated checks, an independent review, and a manual checklist for you) and writes `report.md`, which separates what was verified automatically, what you verified manually, and what was not verified.

## On approval

Approval is recorded in `state.json` and bound to this file's SHA-256 hash. Any later edit invalidates it.
