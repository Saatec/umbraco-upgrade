---
name: version-path
description: Internal gate 2 (version and path) for the umbraco-upgrade workflow. Records source and target versions. Loaded by the upgrade-workflow skill.
user-invocable: false
---

# Gate 2: Version and path

In this plugin version gate 2 is minimal. Version knowledge, upgrade path selection, and documentation retrieval arrive in a later version. Until then:

- the source version comes from discovery (or from the user, when signals conflict)
- the target comes from the command argument
- **every version fact is unverified**
- **path selection is pending**

Do not state LTS status, .NET requirements, support dates, minimum upgrade-from versions, or an upgrade path as facts, even when you believe you know them. If you mention one, label it "unverified, not checked against current documentation".

## Steps

1. `state.ps1 gate -ProjectRoot "<root>" -Gate versionPath -Status in-progress`
2. **Source version.**
   - Read `state.ps1 get -Field source`.
   - If `confidence` is `conflict`, `low`, or `none`, or discovery reported conflicts: show the signals and ask the user for the installed version. Record it: `state.ps1 set -Section source -Set "umbraco=<x.y.z>;major=<n>;confidence=confirmed-by-user"`.
3. **Target.** The requested target is in state (`target.requested`). Leave `target.resolved`, `target.dotnet`, `target.lts`, and `target.supportEnds` empty and `target.verified` false.
4. **Decisions.** Allocate two ids with `state.ps1 decision -Gate versionPath` and write them to `.umbraco-upgrade/decisions.md` from `${CLAUDE_PLUGIN_ROOT}/skills/upgrade-planning/templates/decisions.md`:
   - source version: value, how it was determined (evidence files, or user confirmation), status unverified
   - requested target: value from the command, status unverified; exact version resolution pending
5. **Compatibility.** Write `.umbraco-upgrade/compatibility.md` from the template. Fill known values from discovery (CMS version, target frameworks, database engine, detected patterns). Every row that needs version knowledge says "unverified" or "pending".
6. **Record and pass.** `state.ps1 gate-fields -ProjectRoot "<root>" -Gate versionPath -Set "pathSelection=pending;factsVerified=false"`, then `state.ps1 gate -ProjectRoot "<root>" -Gate versionPath -Status passed -Evidence "compatibility.md,decisions.md"`.

If the requested target major is lower than the source, stop: argument validation should have caught it.
