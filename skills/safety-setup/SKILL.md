---
name: safety-setup
description: Internal gate 3 (safety setup) for /umbraco-upgrade:start. Git checks, upgrade branch, backup and rollback plan, guard self-test. Loaded by the upgrade-workflow skill.
user-invocable: false
---

# Gate 3: Safety setup (upgrade mode only)

Scripts are run as `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<Script>" ...`.

1. `state.ps1 gate -ProjectRoot "<root>" -Gate safety -Status in-progress`
2. **Check git.** `Test-SafetyPreconditions.ps1 -ProjectRoot "<root>"`.
   - If `problems` is not empty, show each problem and **stop and ask**. For uncommitted changes, list the paths and ask the user to commit or set them aside themselves.
   - **Never** stash, reset, checkout, restore, clean, commit, or discard the user's changes on their behalf.
   - Changes inside `.umbraco-upgrade/` are expected and ignored.
3. **State folder policy.** If `project.stateFolderPolicy` is still `undecided`, ask now (see the workflow skill, "First run") and run `Set-StateFolderPolicy.ps1`. For `gitignore`, apply it in step 8, after the gate passes.
4. **Create the upgrade branch.** `New-UpgradeBranch.ps1 -ProjectRoot "<root>"` (default name `umbraco-upgrade/<source-major>-to-<target>`). If the name exists, ask the user for another and pass `-Branch`.
5. **Backup and local database plan.** Ask the user:
   - whether a restored **local** copy of the site's database exists for the upgrade, and whether it is the database the project's local configuration points to
   - where their production backup lives (only "exists" or "does not exist" is recorded; no paths or names of servers)
   Record the answer with `state.ps1 set -Section source -Set "database.localCopyDeclared=true|false"`. Do not take a snapshot or connect to any database in gate 3: health counts and snapshots happen in the database phase of plan execution, the snapshot with its own approval.
6. **Rollback document.** Write `.umbraco-upgrade/rollback.md`: base branch and commit (from `state.ps1 get -Field gitBaseline`), how to return (`git switch <base-branch>`; the upgrade branch stays for inspection), and how to restore the local database copy from the user's backup. Record it: `state.ps1 gate-fields -ProjectRoot "<root>" -Gate safety -Set "rollbackDoc=rollback.md"`.
7. **Guard self-test.**
   1. `Test-Guard.ps1 -ProjectRoot "<root>" -Issue`. It prints a harmless canary command.
   2. Run exactly that command with your normal shell tool, from the project root. Expect it to be blocked with `umbraco-upgrade guard [guard.canary]`.
   3. `Test-Guard.ps1 -ProjectRoot "<root>" -Verify`.
   4. If the result is `failed`: say "Safety hooks are not active; the upgrade cannot proceed." Run `state.ps1 gate -Gate safety -Status failed -Notes "guard self-test failed"` and stop. Do not continue to gate 4.
8. **Pass the gate.** `state.ps1 gate -ProjectRoot "<root>" -Gate safety -Status passed -Evidence "rollback.md"`. If the folder policy is `gitignore`, now run `Set-StateFolderPolicy.ps1 -ProjectRoot "<root>" -Policy gitignore`.
