# Feedback for the umbraco-upgrade plugin

Draft written by /umbraco-upgrade:feedback. GitHub issues are public: read every line before you post it.
Open https://github.com/Saatec/umbraco-upgrade/issues/new/choose, pick the form each section names, and copy its fields. One issue per section.

- Plugin version used for the upgrade: <plugin.usedForUpgrade>
- Plugin version now: <plugin.now>
- Umbraco versions: <source> to <target>
- Upgrade strategy: <strategy>

<!-- One section per confirmed problem. Keep only the sections you need, with the fields of the form they name. -->

## Issue 1: <short title>

**Form:** Missed or wrong customization

- **What went wrong:** <Missed: custom code was not reported | False positive: stock or package files were reported as custom | Wrong group: reported under the wrong pattern>
- **Plugin version:** <version>
- **Umbraco versions:** <source> to <target>
- **The customization:** <what it is, in general terms>
- **Where it is:** <file types and generic folders, for example App_Plugins/<folder>/package.manifest>
- **What the plugin reported:** <the pattern id, "unclassified", or nothing>
- **Short example:**

```text
<a few lines written from scratch with placeholder names>
```

## Issue 2: <short title>

**Form:** Wrong version or package information

- **What is wrong:** <Version fact | Upgrade path | Package compatibility | New Umbraco or .NET version | Other>
- **Plugin version:** <version>
- **Umbraco versions:** <source> to <target>
- **What the plugin says:** <the claim>
- **What is correct:** <the correct fact>
- **Source:** <official page the user named, or "not known">

## Issue 3: <short title>

**Form:** Bug

- **Plugin version:** <version>
- **Umbraco versions:** <source> to <target>
- **Command:** <start | plan | resume | verify | report | update-knowledge | feedback | Not during a command>
- **Gate or phase:** <for example gate 4, or P3>
- **What happened:** <in general terms>
- **What you expected:** <expected behavior>
- **Steps to reproduce:** <steps with placeholder names>
- **Error message or script output:** <only the lines needed, names replaced>

The Bug form also asks for the Claude Code version (`claude --version`) and the operating system and PowerShell version. Fill those in on the form.
