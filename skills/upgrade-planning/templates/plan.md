# Upgrade plan: <project name>

Status: awaiting approval | approved | plan only
Mode: upgrade | plan
Created: <UTC date> by umbraco-upgrade <plugin version>

## Summary

- Source: Umbraco <version> (<how determined>)
- Target: Umbraco <exact version> (requested: <target>; resolved from <NuGet or knowledge>)
- Upgrade path: <strategy> (decision <D-xxx>)
- Phases: <count>
- Unresolved items: <count>

## Version facts

| Fact | Value | Status | Source |
|---|---|---|---|
| LTS status of target | <true or false> | <verified, secondary, unverified> | <URL, version, date> |
| .NET version of target | <tfm> | <status> | <source> |
| End of support of target | <date> | <status> | <source> |

Secondary and unverified facts are not relied on without confirmation. Details: `compatibility.md` and `decisions.md`.

## Upgrade path

| Step | From | To | Type | Rules and sources |
|---|---|---|---|---|
| S1 | <version> | <version> | <type> | <rule ids, URLs> |

Alternatives considered: <strategy: reason rejected>.

## Gate 3: safety setup

<Upgrade mode: branch, base commit, guard self-test result, local database copy declared yes or no.>
<Plan mode: what gate 3 will check and create when /umbraco-upgrade:start runs.>

Rollback: see `rollback.md`.

## Phases

### P1 <title> (<area>)

- Patterns: <ids, or "always required">
- Work: <short description>
- Acceptance criteria:
  - P1-AC1 <criterion> (automated | manual; evidence: <what>)

<repeat per phase>

## Unresolved items

| ID | Item | Proposed approach | Question for you |
|---|---|---|---|

## On approval

Approval is recorded in `state.json` and bound to this file's SHA-256 hash. Any later edit invalidates it.
Plan execution is not available in this plugin version.
