# Contributing

This plugin gets better when people report what it got wrong on real upgrades. You can help in three ways:

1. [Report a problem](#report-a-problem): open an issue. No coding needed.
2. [Send version information](#send-version-information) when a new Umbraco or .NET release comes out.
3. [Send a fix](#send-a-fix): open a pull request.

## Keep client data out

Issues, pull requests, and commits on GitHub are public. Most people use this plugin on client or company projects, so read this first.

Never post:

- project, client, company, or server names
- code, views, or configuration copied from a real project
- connection strings, keys, passwords, tokens, or host names
- names of private NuGet packages or private package feeds
- files from `.umbraco-upgrade/` as they are. The plugin redacts secrets in that folder, but its files still hold project names, file paths, and package lists.

Instead:

- describe the problem in general terms, for example "a surface controller that inherits from a custom base class"
- write a short example from scratch with placeholder names such as `SampleSite` or `Sample.Web`
- copy only the lines of script output you need, and replace the names in them

Public NuGet package ids (for example `Umbraco.Forms`) and public documentation links are fine.

## Report a problem

Open an issue and pick the form that fits:

| Form | Use it when |
|---|---|
| Missed or wrong customization | Discovery missed custom code, reported stock or package files as custom, or put something in the wrong group |
| Wrong version or package information | A version fact (LTS status, support dates, .NET version), an upgrade path, or a package compatibility result is wrong or out of date |
| Bug | A command, script, or safety hook did something wrong or stopped with an error |

Every form asks for:

- the plugin version (`claude plugin list`)
- the Claude Code version (`claude --version`)
- your operating system and PowerShell version
- the source and target Umbraco versions
- what happened, and what you expected

### Security problems: report them privately

Do not open a public issue if:

- a safety hook let through an operation it should block (for example a force push, a history rewrite, or a production database command)
- the plugin printed or wrote a secret (a password, key, or connection string)

Report these privately on the repository's **Security** tab with **Report a vulnerability**.

## Send version information

When a new Umbraco or .NET version comes out, the plugin's version facts need an update:

1. Run `/umbraco-upgrade:update-knowledge`. It reads public sources only and never touches a project.
2. It writes `refresh-report.md` and `maintainer.patch` to the plugin data directory (see [Plugin data directory](README.md#plugin-data-directory) in the README).
3. Open an issue with the **Wrong version or package information** form and attach `maintainer.patch`. The patch holds public facts only.

## Send a fix

Fixes must be **generic**: they must help any Umbraco site, not only one project. Something that exists in one project only (a client's own library, naming, or vendor code) does not belong in the plugin. The plugin already reports such code as "unclassified" or as an unresolved item for the user to decide.

1. Fork the repository and create a branch.
2. Load your clone in Claude Code with `claude --plugin-dir <path to your clone>`.
3. Read [docs/architecture.md](docs/architecture.md). Its **Extending the plugin** section says how to add a customization pattern, a version fact, or a guard rule. Its **Conventions** section lists the coding rules: scripts run on Windows PowerShell 5.1, ASCII source files only, and no em dashes.
4. Add a test for your change. Test fixtures are written from scratch with placeholder names (`SampleSite`, `Sample.*`). Never copy files from a real project into `tests/fixtures/`. Fake secrets carry the marker `FAKE-SECRET-FOR-TESTS`.
5. Cite your sources. An upgrade impact or handling option cites the official documentation page (URL, the docs version, the date you read it). If no official page confirms it, mark it `hypothesis`.
6. Run the checks:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
   claude plugin validate . --strict
   ```

7. Add a line about your change to the newest section of [CHANGELOG.md](CHANGELOG.md).
8. Open a pull request. Say what you changed, why, and how you tested it.

## What happens next

The maintainer reviews every issue and pull request, and may ask questions or for changes. Accepted fixes ship in the next release. Users get them when they update the plugin (`claude plugin update umbraco-upgrade@umbraco-upgrade`, see [Install](README.md#install)).
