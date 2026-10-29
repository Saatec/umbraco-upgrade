# Upgrade report: <project name>

Generated: <UTC date> by umbraco-upgrade <plugin version>
Status: <complete | partial: phases open | stopped>

This report separates what was verified automatically, what you verified manually, and what was not verified. A successful build alone is never counted as verification.

## Summary

- Source: Umbraco <version> on <tfm>
- Target: Umbraco <exact version> on <tfm>
- Path: <strategy>, steps <S1...> (decision <D-xxx>)
- Upgrade branch: <branch>, base commit <sha>, last checkpoint <sha>
- Phases: <done> done, <deferred> deferred, <open> open
- Unresolved items: <count> open

## Phases

| Phase | Title | Status | Checkpoint commit | Criteria met / waived / open | Evidence |
|---|---|---|---|---|---|

## Verified automatically

| Check | Result | Evidence |
|---|---|---|
| <build with views precompiled> | <passed or failed> | <evidence/P.../build-....json> |

## Verified manually (by you)

| Check | Who and when | Result | Evidence |
|---|---|---|---|

## Not verified

| Check | Why not | Risk | Suggested next step |
|---|---|---|---|

## Decisions

| ID | Decision | Alternatives rejected | Sources (URL, version, date) |
|---|---|---|---|

## Unresolved items

| ID | Pattern | Item | Proposal | Status |
|---|---|---|---|---|

## Deviations from the plan

| Phase | Deviation | Reason | Approved by |
|---|---|---|---|

## Manual follow-ups

- <checklist items for you, for example the deployment rehearsal and production configuration>

## Rollback

See `rollback.md`: return to <base branch> at <base commit>; restore the local database copy from <snapshot evidence>.

## Evidence index

- `evidence/discovery/`, `evidence/version-path/`, `evidence/safety/`, `evidence/planning/`, `evidence/P1/` ...
