---
name: feedback
description: After an Umbraco upgrade, compare what the plugin planned with what really changed, go through the differences with you, and write a draft GitHub issue for the plugin maintainer with project and client names removed. Never posts anything.
argument-hint: [project-path]
arguments: [path]
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# /umbraco-upgrade:feedback

Arguments as typed: `$ARGUMENTS`

Outside Claude Code (GitHub Copilot, OpenAI Codex, Cursor), first read [other-tools.md](../upgrade-workflow/references/other-tools.md).

This command helps the plugin improve from real upgrades. It compares the plan and discovery with what changed in the project since the upgrade started, asks the user what each difference means, and writes `.umbraco-upgrade/feedback.md`: a draft for the plugin's GitHub issue forms. It works for an upgrade run with this plugin and for one done by hand after `/umbraco-upgrade:plan`. It writes nothing outside `.umbraco-upgrade/`, and it never posts, opens, or sends anything: the user decides what to post.

## 1. Validate the arguments

If more than one argument was given, stop and print the usage line below.

Run (from the session's working directory):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-UpgradeArguments.ps1" -Command feedback -Path "$path"
```

If no project path was given, leave out `-Path` and its empty value: Windows PowerShell drops an empty argument, and the script then stops with a missing-argument error.

- If `ok` is false, show each error message exactly, show the usage line, and stop.
- Show any warnings to the user before continuing.
- Use `projectRoot` from the output as the project path for every later step.

Usage: `/umbraco-upgrade:feedback [project-path]`, for example `/umbraco-upgrade:feedback`.

## 2. Compare

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Compare-UpgradeOutcome.ps1" -ProjectRoot "<projectRoot>"
```

If `ok` is false, show `error` and stop. Show each warning. The full result is in `outFile`; read it when the summary is not enough.

Tell the user in a few lines: the base commit, that the comparison is with the files as they are now (committed or not), the version now against the target, and the counts per category. The categories are explained in the script's synopsis. The script only proposes candidates. A difference is a plugin problem only when the user says so.

## 3. Go through the differences with the user

Take one group at a time, in this order, and skip empty groups. Keep each question short, give the answer options, and do not decide for the user. To see what changed in a file, run the script again with `-ShowDiff "<file as listed>"`.

1. **Not found** (`notFoundGroups`): changed or deleted files that discovery did not report. For each group, show the folder, the file count, and what changed. Ask which it is:
   - the plugin should have found it (a missed customization)
   - normal upgrade work any project needs
   - specific to this project only

   Only the first goes into the draft. For a miss, ask what kind of customization it is in general terms and what broke on the target (the API, feature, or file format).
2. **Planned, nothing changed** (`plannedUnchanged`): patterns the plan covered whose files did not change. Ask whether no change was needed (a false alarm), the work happened outside these files (database, backoffice settings, deployment), or it is not done yet. Only false alarms go into the draft.
3. **Found, not planned** (`foundNotPlannedChanged`): discovery found the pattern and its files changed, but no phase covered it. Ask whether the plan should have had a phase for it.
4. **Packages** (`packageFlags`):
   - `compatible-but-removed`: ask why it was removed. "It did not work on the target" means the compatibility result was wrong.
   - `no-target-version-but-kept`: ask whether a version for the target exists. If it does, the package information was wrong.
   - `successor-not-used`: ask what was used instead of the named successor.
   - `no-claim`: the plugin could not read the package metadata; ask whether the package worked.

   A package marked `private` is not on nuget.org. Never name it in the draft, or describe it in a way that identifies it. Packages in `packagesAdded` are not in the summary by name: name one in the draft only when the user confirms it is public on nuget.org.
5. **Phases and unresolved items** (`phasesWithFailures`, `phasesNotDone`, `openUnresolved`): ask whether any of them was caused by the plugin, for example a wrong instruction, a script error, or a safety hook that blocked a legitimate step. Those are bugs.
6. Last, ask one open question: did the plugin get anything else wrong, or make anything hard?

If the user confirms no problem, say that no issue is needed, write no draft, and stop.

## 4. Write the draft

Write `.umbraco-upgrade/feedback.md` from `${CLAUDE_PLUGIN_ROOT}/skills/feedback/templates/feedback.md`. Add one section per confirmed problem. Each section names its issue form and fills that form's fields. Take the plugin versions, the Umbraco versions, and the strategy from the comparison.

Rules for the text. GitHub issues are public:

- Describe in general terms: "a surface controller that inherits from a custom base class", not the project's class names.
- Use placeholder names only: `SampleSite`, `Sample.Web`, `SampleController`.
- Write short examples from scratch. Never copy code, views, or configuration from the project, not even a few lines.
- Leave out client, company, project, server, and people names, host names, links other than official documentation and nuget.org, file paths beyond generic folders such as `App_Plugins/<folder>`, connection strings, and secrets.
- Public package ids (on nuget.org) are fine.
- For wrong version or package information, cite the official page the user names. Do not invent a source.

## 5. Check the draft

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Test-FeedbackDraft.ps1" -ProjectRoot "<projectRoot>"
```

If `ok` is false, show `error` and stop. If `clean` is false, reword each finding (`line`, `text`, `source`) and run the check again until it is clean. If a finding is a common word that does not identify the project, ask the user before keeping it. The check knows only the names it can find in the project, git, and the evidence, so also read the whole draft once more yourself.

## 6. Hand over

Tell the user:

- where `feedback.md` is, and how many issues it holds
- to read every line before posting: issues are public, and the user is the last check
- to open https://github.com/Saatec/umbraco-upgrade/issues/new/choose, pick the form each section names, and copy its fields: one issue per section
- that a security problem (a safety hook let a blocked operation through, or the plugin printed or wrote a secret) must not go into a public issue: report it on the repository's **Security** tab with **Report a vulnerability**

## Rules

- Never post, open, or send the draft or the comparison anywhere: no `gh`, no browser, no web request. The user posts it.
- Write only `.umbraco-upgrade/feedback.md`. Never change `state.json` or any project file.
- The user's answers are the truth about the project. The comparison only proposes.
