# Example prompts

Prompts for common scenarios, with what to expect. The project names and paths are placeholders. Start Claude Code in the project you upgrade (or pass its path), with the plugin enabled at project or local scope there.

## Look before you change anything

Plan only, for the project in the current folder:

```
/umbraco-upgrade:plan 17
```

Expect: discovery, version and path selection, and a plan in `.umbraco-upgrade/plan.md`, with `inventory.md`, `compatibility.md`, `risks.md`, and `decisions.md`. The plugin asks only what it cannot find out itself, such as where `.umbraco-upgrade/` should go in Git, which version to trust when the project files disagree, or a choice between close upgrade paths. Nothing outside `.umbraco-upgrade/` changes and no branch is created.

For a project in another folder:

```
/umbraco-upgrade:plan 17 C:\src\SampleSite
```

## Upgrade a near-default site

A site on Umbraco 13 with few customizations, to the latest 17 release:

```
/umbraco-upgrade:start 17
```

Expect: gates 1 to 3 (the plugin stops if you have uncommitted changes; it creates the branch `umbraco-upgrade/13-to-17` and runs a guard self-test), then a short plan, often one or two phases, and a stop for your approval. Reply:

```
approve
```

The plugin then works phase by phase on the upgrade branch, with a checkpoint commit per phase, and ends with gate 5: automated checks, an independent review, a manual checklist for you, and `report.md`.

To change the plan instead, describe what you want (for example "split the package updates into their own phase"); the plugin rewrites the plan and asks again. Reply `reject` to stop.

## Upgrade to a specific release

```
/umbraco-upgrade:start 17.8.0
```

A bare major (`17`) means the latest released version of that major; a full version pins the release.

## Cross several majors

A site on Umbraco 13 to the latest 18:

```
/umbraco-upgrade:plan 18
```

Expect a staged path through the closest LTS major (17), with the alternatives it rejected and the official pages behind the rules in `decisions.md`. The phases are grouped per stop, and the plan names each stop's preparation steps.

## Plan a legacy upgrade

A site on Umbraco 7 or 8 to 17:

```
/umbraco-upgrade:plan 17
```

Expect a path that is not in place: the code is rebuilt on a new codebase and the database is carried through intermediate versions, or content is moved into a new installation. The plan lists every customization with its handling options and records the items that need your decision (for example backoffice extensions that must be rewritten). Use the plan to estimate the work before you run `start`.

## Answer the plugin's questions

When the plugin asks, answer in plain words. Examples:

```
Commit the .umbraco-upgrade folder with the upgrade branch.
```

```
I restored a copy of the site's database to LocalDB on this machine. The local appsettings point to it.
```

```
For the export feature, port it to the new API. Do not remove it.
```

## Ask for a shortcut

```
Just make it build. Remove whatever does not compile.
```

Expect: the plugin keeps the custom feature, records an unresolved item with a proposal (port, replace, or redesign), and asks how you want to proceed. It never removes, stubs, or disables custom functionality to make a build pass. Retiring a feature is your decision, recorded as a `remove-custom-feature` approval that names the files.

## Continue after an interruption

After a closed session, a usage limit, or a machine restart:

```
/umbraco-upgrade:resume
```

Expect: a comparison of the recorded state with the repository (branch, HEAD, checkpoint commits, uncommitted changes, the plan, the files the state cites, the CMS version). If anything differs, the plugin reports it with options and waits for your decision; it never repairs or repeats a phase on its own. If everything agrees, it continues where the upgrade stopped.

## Check progress or verify the result

During the upgrade, an interim check that records nothing:

```
/umbraco-upgrade:verify
```

After the last phase, the same command runs gate 5. Answer the manual checks one by one, for example:

```
V-07 verified: logged in to the backoffice as an editor and as an administrator on the local copy; both see the expected sections.
V-09 not verified: the payment sandbox is not reachable from this machine.
```

## Regenerate the report

```
/umbraco-upgrade:report
```

The report separates what was verified automatically, what you verified manually, and what was not verified, with reasons, risks, and next steps.

## Tell the maintainer what the plugin got wrong

After an upgrade, whether the plugin ran it or you did it by hand after `/umbraco-upgrade:plan`:

```
/umbraco-upgrade:feedback
```

Expect a comparison of the plan with what changed since the upgrade started, questions about each difference (a miss, normal upgrade work, or specific to your project), and a draft issue in `.umbraco-upgrade/feedback.md` with names removed. Read it and post it yourself; the plugin never posts anything.

## Refresh version knowledge

Before planning, when a new Umbraco release may have appeared:

```
/umbraco-upgrade:update-knowledge
```

Expect a summary of changed facts, new majors (their LTS status, support dates, and path rules stay unverified until checked on official pages), upcoming majors (prereleases and pre-release documentation), and facts that need review.
