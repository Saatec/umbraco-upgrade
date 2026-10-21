# Recorded responses

The mock sets in this folder hold HTTP responses recorded on 2026-10-14 for the plugin's tests (label: mocked). Each set has an `index.json` that maps a URL to its recorded status, final URL, content type, and body file. Entries marked `trimmed` keep only part of the body; entries marked `derived` were changed on purpose (for example a synthetic future major version) and are described in the set's `description`.

| Set | Contents |
|---|---|
| `m.docs` | Umbraco documentation pages, UmbracoDocs branch files, the docs index, release and LTS sources, .NET release metadata, the NuGet service index |
| `m.nuget` | NuGet v3 flat container indexes, nuspec files, and registration entries |
| `m.nuget.future-major` | Derived: an Umbraco.Cms index with a synthetic major 25 and its nuspec |
| `m.nuget.future-prerelease` | Derived: an Umbraco.Cms index with a synthetic 25.0.0-rc1 only |
| `m.docs.changed` | Derived: an upgrade page with one sentence removed |

The scripts use these sets only when the environment variable `UMBRACO_UPGRADE_HTTP_MOCK` names them; then no request leaves the machine.

## Sources and licenses

- Umbraco documentation (docs.umbraco.com and github.com/umbraco/UmbracoDocs): MIT License, Copyright (c) 2013-present Umbraco.
- .NET release metadata and release notes (github.com/dotnet/core): MIT License, Copyright (c) .NET Foundation and Contributors.
- endoflife.date API data (github.com/endoflife-date/endoflife.date): MIT License.
- NuGet package metadata (api.nuget.org) of Umbraco packages published under the MIT License by Umbraco HQ.
- releases.umbraco.com and umbraco.com: short excerpts (the current-releases section, and the title of a bot-challenge page) used only to test parsing and blocked-page handling.

## MIT License (as published by the copyright holders above)

Copyright (c) 2013-present Umbraco
Copyright (c) .NET Foundation and Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
