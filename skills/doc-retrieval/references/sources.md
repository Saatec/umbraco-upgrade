# Sources

The data behind this page is `${CLAUDE_PLUGIN_ROOT}/knowledge/sources.json` (or its refreshed copy). The scripts contact only the hosts listed there:

- docs.umbraco.com (documentation site and its `llms.txt` index)
- raw.githubusercontent.com (UmbracoDocs branches for end-of-life and legacy versions)
- api.nuget.org (flat container, nuspec files, registration)
- builds.dotnet.microsoft.com and dotnetcli.blob.core.windows.net (.NET release metadata)
- releases.umbraco.com (release list and LTS labels)
- umbraco.com (the official LTS and end-of-life page; usually answers automated requests with a bot challenge)
- endoflife.date (secondary)
- learn.microsoft.com (read with WebFetch when needed)

## Documentation spaces

| Space | Versions (see `docsSpace` in versions.json) | URL |
|---|---|---|
| `latest` | the newest major | `https://docs.umbraco.com/<product>/<path>.md` |
| `versioned` | other supported majors (`<n>.latest`) | `https://docs.umbraco.com/<product>/<n>.latest/<path>.md` |
| `eol` | end-of-life majors from 10 on | `https://raw.githubusercontent.com/umbraco/UmbracoDocs/umbraco-eol-versions/<n>/<product>/<path>.md` |
| `legacy` | 7 and 8 | `https://raw.githubusercontent.com/umbraco/UmbracoDocs/legacy-docs/<path>` |
| `github-main` | probing majors not in the knowledge | `https://raw.githubusercontent.com/umbraco/UmbracoDocs/main/<n>/<product>/<path>.md` |

Docs for an end-of-life major leave the site one to three months after its end of life. The site then redirects that major's `<n>.latest` URLs to another version, which is why `Get-Doc.ps1` checks the final URL and the page's own Markdown link. Umbraco 9 has no docs space on any branch; its upgrade notes are in the newer find-your-upgrade-path page.

Page layouts differ by version: `get-started/upgrading-and-migrating/...` from 17, `fundamentals/setup/upgrading/...` for 10 to 16. On GitHub branches, folder pages are `README.md`.

## Page keys

| Key | Page |
|---|---|
| `upgrade-details` | Upgrade your project (major and minor upgrade steps, CMS to .NET table) |
| `breaking-changes` | Breaking changes and version-specific notes |
| `find-upgrade-path` | Find your upgrade path (17 and later layout; covers 7 to latest) |
| `upgrade-from-8` | Upgrade from Umbraco 8 to the latest version |
| `migrate-content-8` | Migrate content to Umbraco 8 |
| `migrate-content-15` | Migrate content to Umbraco 15 |
| `migrate-backoffice-angularjs` | Migrate backoffice extensions from AngularJS |
| `migrate-property-editors-14` | Migrate custom property editors to 14 and later |
| `minor-upgrades-7`, `minor-upgrades-8` | Minor upgrades within 7 and 8 |

Other add-on products (Forms, Deploy, Commerce, Workflow, UI Builder, Engage) are versioned with the CMS major: pass `-Product umbraco-forms` and so on, with `-Path` from that product's index (`-Index -Find`).

## Other primary sources

- .NET support dates: `https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json` (the official release metadata; the blob storage URL in the dotnet/core README serves the same file)
- NuGet: `https://api.nuget.org/v3-flatcontainer/<id>/index.json` (versions), `.../<id>/<version>/<id>.nuspec` (frameworks, dependencies), `https://api.nuget.org/v3/registration5-gz-semver2/<id>/index.json` (publication, deprecation, vulnerabilities)
- Release notes: `https://releases.umbraco.com/`
