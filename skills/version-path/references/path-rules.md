# Path rules and the knowledge model

## Knowledge files

Baseline files ship in `${CLAUDE_PLUGIN_ROOT}/knowledge/`; refreshed copies are written by `/umbraco-upgrade:update-knowledge` to `${CLAUDE_PLUGIN_DATA}/knowledge/`. Schema: `${CLAUDE_PLUGIN_ROOT}/schemas/knowledge.schema.json`.

**Lookup order, per file:** the refreshed copy when it parses, its schema major version matches, it validates, and its `verifiedAt` is newer than the baseline's; otherwise the baseline. `Get-VersionKnowledge.ps1` reports which copy it used and why.

| File | Holds |
|---|---|
| `versions.json` | Per major: release date, LTS, end of support, end of life, .NET target framework, latest known release, docs space, minimum version it can upgrade from (when documented), data migrations it runs, preparation steps. Also .NET channel support dates. |
| `paths.json` | Documented rules (closest-LTS stop, in-place majors and minors, documented hops, generation boundaries, engine constraints), the strategies, and the scoring heuristics. |
| `packages.json` | Core package per generation, old-to-new package IDs, packages without a successor. From public package metadata only. |
| `sources.json` | Allowed hosts, documentation spaces and URL templates, page paths per layout, NuGet and .NET endpoints, the LTS page, secondary sources. |

Every fact has `value`, `status`, `source` (URL), `sourceType`, `sourceVersion` (the docs or package version the source belongs to), `appliesTo` (the Umbraco versions it is about), `verifiedAt`, `verifiedBy`, and often `evidence` (a short phrase the source must still contain) and `note`.

| status | Meaning | Use |
|---|---|---|
| `verified` | Confirmed from a primary source on `verifiedAt` | May support a decision |
| `secondary` | From a secondary aggregator | Label it; ask the user to confirm on the official page |
| `unverified` | Not confirmed | Label it; it cannot satisfy a gate criterion |
| `needs-review` | The evidence phrase was not found when re-checked | Read the source page; treat as unverified |

## How candidates are built

1. **Generation boundaries (7 and 8).** No in-place upgrade from 7 to 8 or from 8 to 9 and later.
   - 7: minor update to the minimum the content migration accepts (if needed), then content migration into a new 8 installation (landing on the documented workaround minor), then minor updates within 8.
   - 8: minor update to the latest 8 (documented prerequisite), then the database reused in a new project of the boundary's landing major (10 when the target is 10 or later), with code and templates reimplemented.
2. **Documented hops** (for example 9 to 10) are followed as written.
3. **Closest-LTS rule** (from 10 on): stop at the closest LTS major before a later target.
4. **Minimum-from constraints** (`minUpgradeFrom` in `versions.json`): add a minor update or an extra stop when the current version is too old for the next step.
5. **Data migrations, removals, and preparation** of every major a step crosses are attached to that step with their sources.

Strategies:

| Strategy | When |
|---|---|
| `in-place` | Modern source (9 or later), one major step (or a minor update within the major) |
| `staged` | Modern source, several major steps in place |
| `rebuild-with-database-migration` | Source 7 or 8: new codebase, database carried through the boundary steps |
| `new-install-with-content-transfer` | Always offered as an alternative for a major upgrade. Tool support for the exact source and target is never assumed |

Risk = the strategy's base risk plus the scoring adjustments from discovery facts (patterns and database engine). The lowest risk among valid candidates is recommended. When the next one is within `closeThreshold`, both are presented and the user chooses. Scoring entries are plugin heuristics, not version facts.

Engine constraints: a database engine that a step does not support either invalidates the candidate (content migration to 8 with an unsupported engine) or adds a decision (SQL CE before 10: no official migration path; the documented options are listed). An unknown engine adds a decision to confirm it.

## Output fields of Select-UpgradePath.ps1

| Field | Meaning |
|---|---|
| `status` | `selected`, `needs-decision`, `future-unverified`, `unknown-target`, `no-valid-path`, `error` |
| `target` | requested, resolved exact version, how it was resolved (`nuget` with URL, `knowledge`, or offline), LTS, .NET, end of support and end of life (each with status and source), docs space |
| `candidates[]` | `id`, `strategy`, `steps[]`, `risk`, `riskDetail`, `valid`, `invalidBecause`, `decisions`, `preservesDatabase`, `preservesCode` |
| `steps[]` | `from`, `to`, `type` (`minor-in-place`, `major-in-place`, `content-migration-new-install`, `database-reuse-new-project`, `content-transfer-new-install`), `kind` (code, database, content), `codebase` (existing or new), `rules`, `prerequisites`, `dataMigrations`, `removals`, `preparation`, `resolvedBy` |
| `recommended`, `close` | Recommended candidate id; whether the next candidate is close |
| `alternatives` | Each rejected candidate (and a forbidden direct jump) with the reason |
| `mandatoryWork` | Work every strategy needs (for example rewriting AngularJS backoffice extensions for 14 and later) |
| `factsUsed`, `unverifiedFacts` | Every fact the result rests on, with status; with `-VerifyLive`, also `live`: confirmed, missing, unreachable, not-checkable |
| `gateBlockers` | What must be confirmed before gate 2 can pass (unknown targets) |
| `knowledge` | Which copy of each knowledge file was used |

## Unknown future versions

- Published on NuGet, not in the knowledge: `future-unverified`. The .NET framework comes from the package's nuspec (package metadata). LTS status, the minimum upgrade-from version, support dates, and any LTS stops among majors missing from the knowledge are unknown. The user confirms them from official pages (`-UserLts`, `-UserDotnet`, `-UserMinFrom`, `-UserSource`); suggest `/umbraco-upgrade:update-knowledge`.
- Not published (or only prereleases): `unknown-target`. Stop with the message.
