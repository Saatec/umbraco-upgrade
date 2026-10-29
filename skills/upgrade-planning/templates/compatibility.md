# Compatibility: <project name>

Every fact below gives its status (verified, secondary, unverified, needs-review, hypothesis) and its source: URL, the version the source applies to, and the verification or fetch date. A fact without a primary source is **unverified**.

## Versions

| Item | Source (current) | Target | Status | Source of fact |
|---|---|---|---|---|
| Umbraco CMS | <version> | <exact target> | <status> | discovery evidence / user; NuGet URL and date |
| .NET target framework | <tfm> | <tfm> | <status> | <source> |
| Database engine | <engine> | <supported or decision needed> | <status> | <rule and source> |
| LTS status of target | | <true or false> | <status> | <source> |
| End of support of target | | <date> | <status> | <source> |
| End of life of target | | <date> | <status> | <source> |
| Upgrade path | | <strategy> | selected | decision <D-xxx> |

## Upgrade path steps

| Step | From | To | Type | Data migrations | Removals and preparation | Sources |
|---|---|---|---|---|---|---|

## Documented steps not covered above

| Version | Step | Phase that covers it | Source |
|---|---|---|---|

## Packages

From `evidence/planning/package-compatibility.json` (NuGet metadata, fetched <date>).

| Package | Current version | Class | Version for the target, or decision | Notes and source |
|---|---|---|---|---|
| <id> | <version> | compatible, no-target-version, framework-only, not-cms-specific, not-found, platform, cms-dependency | <version or "decision U-xxx"> | <dependency range, deprecation, NuGet URL> |

## Detected customizations and target impact

From `Get-PatternGuidance.ps1` for each detected pattern.

| Pattern | Impact at target (crossings) | Difficulty | Status | Sources | Phase |
|---|---|---|---|---|---|
| <id> | <crosses N: summary> | <low, medium, high> | <verified or hypothesis> | <URLs with versions and dates> | <P...> |

## Baseline signals

| Signal | What it adds to the plan | Source |
|---|---|---|
