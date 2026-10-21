# Docs.psm1 - official documentation retrieval with version labels, response validation, and a cache.
#
# Version spaces (knowledge/sources.json): the unversioned docs site is the latest major, "<n>.latest" spaces
# hold other supported majors, end-of-life majors live on the UmbracoDocs "umbraco-eol-versions" branch, and
# 7 and 8 on the "legacy-docs" branch. The docs site answers a missing page with HTTP 200 and a "Page Not Found"
# body, and redirects an unpublished "<n>.latest" space to another version, so every response is checked
# against the space that was asked for.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Http.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Knowledge.psm1') -DisableNameChecking

# ---------------------------------------------------------------- spaces and URLs

function Get-SpaceTemplate {
    param([Parameter(Mandatory)]$Sources, [Parameter(Mandatory)][string]$SpaceId)
    foreach ($s in @($Sources['docs']['spaces'])) { if ($s['id'] -eq $SpaceId) { return $s } }
    throw "Unknown docs space '$SpaceId' in sources.json."
}

function Resolve-DocSpace {
    # Docs space for a major from versions.json. Majors not in the knowledge return space 'unknown'.
    param([Parameter(Mandatory)][int]$Major, [Parameter(Mandatory)]$Versions)
    $entry = Get-MajorEntry -Versions $Versions -Major $Major
    if ($null -eq $entry) { return [ordered]@{ major = $Major; space = 'unknown'; fact = $null } }
    $value = [string]$entry['docsSpace']['value']
    $space = $value
    if ($value -match '^\d+\.latest$') { $space = 'versioned' }
    return [ordered]@{ major = $Major; space = $space; fact = $entry['docsSpace'] }
}

function Get-DocLayout {
    param([Parameter(Mandatory)]$Sources, [Parameter(Mandatory)][int]$Major)
    foreach ($l in @($Sources['docs']['layouts'])) {
        $min = $l['minMajor']; $max = $l['maxMajor']
        if (($null -eq $min -or $Major -ge [int]$min) -and ($null -eq $max -or $Major -le [int]$max)) { return [string]$l['id'] }
    }
    return $null
}

function Resolve-DocPagePath {
    # Site path of a page key for a major's layout. GitHub branches keep folder pages as README.md (githubPath).
    param([Parameter(Mandatory)]$Sources, [Parameter(Mandatory)][string]$Page, [Parameter(Mandatory)][int]$Major, [string]$Space = '')
    $layout = Get-DocLayout -Sources $Sources -Major $Major
    foreach ($p in @($Sources['docs']['pages']['entries'])) {
        if ($p['key'] -ne $Page) { continue }
        foreach ($lp in @($p['paths'])) {
            if ($lp['layout'] -ne $layout) { continue }
            if ($lp.Contains('minMajor') -and $Major -lt [int]$lp['minMajor']) { continue }
            if ($lp.Contains('maxMajor') -and $Major -gt [int]$lp['maxMajor']) { continue }
            if ($Space -in @('eol', 'github-main') -and $lp.Contains('githubPath')) { return [string]$lp['githubPath'] }
            return [string]$lp['path']
        }
        throw "Page '$Page' has no known path for Umbraco $Major (layout '$layout'). Use -Index to search the index for that version."
    }
    throw "Unknown page key '$Page'. Known keys: $(@($Sources['docs']['pages']['entries'] | ForEach-Object { $_['key'] }) -join ', ')."
}

function Expand-UrlTemplate {
    param([Parameter(Mandatory)][string]$Template, [string]$Product, [int]$Major, [string]$Path)
    $u = $Template.Replace('{product}', $Product).Replace('{major}', [string]$Major).Replace('{path}', $Path.TrimStart('/'))
    return $u
}

function Resolve-DocUrl {
    # URL for a page or path of a product in the space of a major. Space 'github-main' is used for probing.
    param([Parameter(Mandatory)]$Sources, [Parameter(Mandatory)][string]$Space, [Parameter(Mandatory)][int]$Major, [string]$Product = 'umbraco-cms', [Parameter(Mandatory)][string]$Path)
    if ($Space -in @('unavailable', 'unknown')) { throw "No documentation space is known for Umbraco $Major." }
    $t = Get-SpaceTemplate -Sources $Sources -SpaceId $Space
    $p = $Path
    if ($Space -ne 'legacy' -and $p.EndsWith('.md')) { $p = $p.Substring(0, $p.Length - 3) }
    return (Expand-UrlTemplate -Template ([string]$t['urlTemplate']) -Product $Product -Major $Major -Path $p)
}

function Get-UrlSpace {
    # Reads the space a URL points to: docs site (latest or <n>.latest) or a GitHub branch with its major folder.
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -match '^https://docs\.umbraco\.com/([a-z0-9\-]+)/(\d+)\.latest/') { return [ordered]@{ host = 'docs'; product = $Matches[1]; space = 'versioned'; major = [int]$Matches[2] } }
    if ($Url -match '^https://docs\.umbraco\.com/([a-z0-9\-]+)/') { return [ordered]@{ host = 'docs'; product = $Matches[1]; space = 'latest'; major = $null } }
    if ($Url -match '^https://raw\.githubusercontent\.com/umbraco/UmbracoDocs/umbraco-eol-versions/(\d+)/([a-z0-9\-]+)/') { return [ordered]@{ host = 'github'; product = $Matches[2]; space = 'eol'; major = [int]$Matches[1] } }
    if ($Url -match '^https://raw\.githubusercontent\.com/umbraco/UmbracoDocs/main/(\d+)/([a-z0-9\-]+)/') { return [ordered]@{ host = 'github'; product = $Matches[2]; space = 'github-main'; major = [int]$Matches[1] } }
    if ($Url -match '^https://raw\.githubusercontent\.com/umbraco/UmbracoDocs/legacy-docs/') { return [ordered]@{ host = 'github'; product = 'umbraco-cms'; space = 'legacy'; major = $null } }
    return [ordered]@{ host = 'other'; product = $null; space = 'other'; major = $null }
}

# ---------------------------------------------------------------- validation

function Test-ChallengePage {
    param([Parameter(Mandatory)]$Response)
    $b = [string]$Response.body
    if ($Response.status -in @(403, 429, 503) -and ($b -match '(?i)<title>\s*Just a moment|challenge-platform|cf-chl|captcha')) { return $true }
    return $false
}

function Test-DocResponse {
    # 'ok', 'not-found', 'blocked', 'version-mismatch', or 'http-<status>' for a docs response.
    param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)]$Sources)
    if (Test-ChallengePage $Response) { return 'blocked' }
    if ($Response.status -eq 404) { return 'not-found' }
    if ($Response.status -ne 200) { return ('http-' + $Response.status) }
    $v = $Sources['docs']['validation']
    $body = [string]$Response.body
    if ($body.TrimStart().StartsWith([string]$v['softNotFoundMarker'])) { return 'not-found' }
    $want = Get-UrlSpace $Response.url
    $got = Get-UrlSpace $Response.finalUrl
    if ($want.space -ne $got.space -or $want.major -ne $got.major -or $want.product -ne $got.product) { return 'version-mismatch' }
    if ($want.host -eq 'docs') {
        $m = [regex]::Match($body.Substring(0, [Math]::Min(2000, $body.Length)), [string]$v['selfLinkPattern'])
        if ($m.Success) {
            $self = Get-UrlSpace $m.Groups['url'].Value
            if ($self.space -ne $want.space -or $self.major -ne $want.major -or $self.product -ne $want.product) { return 'version-mismatch' }
        }
    }
    return 'ok'
}

function Get-DocPage {
    # Fetches one page through the cache. Labels it with the version it applies to.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)]$Sources,
        [string]$DataDir = '',
        [string]$AppliesTo = '',
        [Nullable[int]]$Major = $null,
        [string]$SpaceLabel = '',
        [double]$MaxAgeDays = 7,
        [switch]$Refresh
    )
    $u = Get-UrlSpace $Url
    $maj = $Major
    if ($null -eq $maj -and $null -ne $u.major) { $maj = $u.major }
    $space = $SpaceLabel
    if (-not $space) { $space = $u.space }
    $label = [ordered]@{ sourceType = 'official-docs'; product = $u.product; major = $maj; space = $space; appliesTo = $AppliesTo }
    $validator = { param($resp, $ctx) Test-DocResponse -Response $resp -Sources $ctx }
    $r = Invoke-CachedGet -Url $Url -DataDir $DataDir -MaxAgeDays $MaxAgeDays -Refresh:$Refresh -Validator $validator -ValidatorContext $Sources -Label $label
    $out = [ordered]@{
        ok = ($r.status -eq 'ok'); status = $r.status; url = $Url; finalUrl = $null; product = $u.product; major = $maj; space = $space; appliesTo = $AppliesTo
        fromCache = $r.fromCache; stale = $r.stale; fetchedAt = $null; httpStatus = $null; sha256 = $null; bytes = $null; bodyPath = $null; error = $r.error
    }
    if ($r.response) { $out.httpStatus = $r.response.status; $out.finalUrl = $r.response.finalUrl }
    if ($r.status -eq 'ok') {
        $m = $r.meta
        $out.finalUrl = $m['finalUrl']; $out.fetchedAt = $m['fetchedAt']; $out.httpStatus = $m['httpStatus']; $out.sha256 = $m['sha256']; $out.bytes = $m['bytes']; $out.bodyPath = $m['bodyPath']
    }
    $out['body'] = $r.body
    return $out
}

function Find-DocSpaceByProbe {
    # For a major that is not in the knowledge: GitHub main branch, then the end-of-life branch. Unverified by definition.
    param([Parameter(Mandatory)][int]$Major, [Parameter(Mandatory)]$Sources, [string]$Product = 'umbraco-cms', [string]$DataDir = '')
    foreach ($space in @('github-main', 'eol')) {
        $t = Get-SpaceTemplate -Sources $Sources -SpaceId $space
        $idx = Expand-UrlTemplate -Template ([string]$t['indexTemplate']) -Product $Product -Major $Major -Path ''
        $r = Get-DocPage -Url $idx -Sources $Sources -DataDir $DataDir -AppliesTo 'probe' -Major $Major -SpaceLabel $space -MaxAgeDays 1
        if ($r.ok) { return [ordered]@{ space = $space; indexUrl = $idx; verified = $false } }
    }
    return [ordered]@{ space = 'unavailable'; indexUrl = $null; verified = $false }
}

function Get-DocIndex {
    # Pages of one product and version, from llms.txt (docs site) or SUMMARY.md (GitHub branches), filtered by text.
    param([Parameter(Mandatory)][int]$Major, [Parameter(Mandatory)]$Sources, [Parameter(Mandatory)]$Versions, [string]$Product = 'umbraco-cms', [string]$Find = '', [string]$DataDir = '')
    $res = Resolve-DocSpace -Major $Major -Versions $Versions
    $space = $res.space
    if ($space -eq 'unknown') { $space = (Find-DocSpaceByProbe -Major $Major -Sources $Sources -Product $Product -DataDir $DataDir).space }
    if ($space -in @('unavailable', 'unknown')) { return [ordered]@{ ok = $false; status = 'unavailable'; major = $Major; space = $space; entries = @() } }
    $t = Get-SpaceTemplate -Sources $Sources -SpaceId $space
    $idxUrl = Expand-UrlTemplate -Template ([string]$t['indexTemplate']) -Product $Product -Major $Major -Path ''
    $page = Get-DocPage -Url $idxUrl -Sources $Sources -DataDir $DataDir -AppliesTo 'index' -Major $Major -SpaceLabel $space -MaxAgeDays 7
    if (-not $page.ok) { return [ordered]@{ ok = $false; status = $page.status; major = $Major; space = $space; indexUrl = $idxUrl; entries = @() } }
    $entries = New-Object System.Collections.ArrayList
    foreach ($line in ([string]$page.body -split "`n")) {
        $m = [regex]::Match($line, '\[(?<title>[^\]]+)\]\((?<href>[^)\s]+)\)')
        if (-not $m.Success) { continue }
        $title = $m.Groups['title'].Value; $href = $m.Groups['href'].Value
        $url = $null
        if ($space -in @('latest', 'versioned')) {
            $prefix = 'https://docs.umbraco.com/' + $Product + '/'
            if ($space -eq 'versioned') { $prefix += "$Major.latest/" }
            if (-not $href.StartsWith($prefix)) { continue }
            if ($space -eq 'latest' -and $href -match ('^' + [regex]::Escape('https://docs.umbraco.com/' + $Product + '/') + '\d+\.latest/')) { continue }
            $url = $href
        } else {
            if ($href -match '^https?://') { continue }
            $base = $idxUrl.Substring(0, $idxUrl.LastIndexOf('/') + 1)
            $url = $base + $href
        }
        if ($Find -and -not ($title -match [regex]::Escape($Find) -or $url -match [regex]::Escape($Find))) { continue }
        [void]$entries.Add([ordered]@{ title = $title; url = $url })
    }
    return [ordered]@{ ok = $true; status = 'ok'; major = $Major; space = $space; indexUrl = $idxUrl; fromCache = $page.fromCache; fetchedAt = $page.fetchedAt; entries = @($entries) }
}

# ---------------------------------------------------------------- LTS and end-of-life dates

function Get-LtsInfo {
    # Official LTS and EOL page first. When it is blocked (it answers automated requests with a bot challenge),
    # fall back to the secondary aggregator, labelled as secondary, and require the user to confirm in a browser.
    param([Parameter(Mandatory)][int]$Major, [Parameter(Mandatory)]$Sources, [string]$DataDir = '', [switch]$Refresh)
    $lts = $Sources['lts']
    $out = [ordered]@{ ok = $false; major = $Major; officialUrl = [string]$lts['official']; officialStatus = $null; source = $null; sourceType = $null; label = $null; needsUserConfirmation = $true; confirmUrl = [string]$lts['official']; data = $null; bodyPath = $null; error = $null }
    $off = Get-DocPage -Url ([string]$lts['official']) -Sources $Sources -DataDir $DataDir -AppliesTo "lts-eol $Major" -MaxAgeDays 7 -Refresh:$Refresh
    $out.officialStatus = $off.status
    if ($off.ok) {
        # The official page is reachable: dates must be read from it (no parser; the layout is not stable).
        $out.ok = $true; $out.source = [string]$lts['official']; $out.sourceType = 'official'; $out.bodyPath = $off.bodyPath
        $out.label = 'Official page fetched. Read the dates for this major from the page body and cite it.'
        $out.needsUserConfirmation = $false
        return $out
    }
    $secUrl = [string]$lts['secondary']
    $sec = Invoke-CachedGet -Url $secUrl -DataDir $DataDir -MaxAgeDays 1 -Refresh:$Refresh -Label ([ordered]@{ sourceType = 'secondary' })
    if ($sec.status -ne 'ok') { $out.error = "Official page: $($off.status). Secondary source: $($sec.status) $($sec.error)"; return $out }
    $rows = ConvertFrom-JsonText ([string]$sec.body)
    $row = $null
    foreach ($x in @($rows)) { if ([string]$x.cycle -eq [string]$Major) { $row = $x } }
    $out.source = $secUrl; $out.sourceType = 'secondary'
    $out.label = [string]$lts['secondaryLabel']
    if ($null -eq $row) { $out.error = "The secondary source has no entry for Umbraco $Major."; return $out }
    $get = { param($o, $n) if ($o.PSObject.Properties[$n]) { return $o.$n } else { return $null } }
    $out.data = [ordered]@{ lts = (& $get $row 'lts'); releaseDate = (& $get $row 'releaseDate'); endOfSupport = (& $get $row 'support'); endOfLife = (& $get $row 'eol'); latest = (& $get $row 'latest'); fetchedAt = $sec.meta['fetchedAt'] }
    $out.ok = $true
    return $out
}

# ---------------------------------------------------------------- fact evidence

function ConvertTo-EvidenceText {
    # Normalizes page text for evidence matching: tags stripped from HTML, Markdown emphasis and code marks removed,
    # quotes straightened, whitespace collapsed, lower case.
    param([AllowEmptyString()][string]$Text, [switch]$Html)
    $t = [string]$Text
    if ($Html -or $t -match '^\s*<(!doctype\s+html|html)') {
        $t = [regex]::Replace($t, '(?is)<(script|style)\b.*?</\1>', ' ')
        $t = [regex]::Replace($t, '<[^>]+>', ' ')
        $t = $t.Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&nbsp;', ' ')
    }
    $t = $t.Replace([string][char]0x2019, "'").Replace([string][char]0x2018, "'").Replace([string][char]0x201C, '"').Replace([string][char]0x201D, '"').Replace([string][char]0x00A0, ' ')
    $t = $t -replace '[\*`\\]', ''
    $t = [regex]::Replace($t, '\s+', ' ')
    return $t.ToLowerInvariant()
}

function Test-FactEvidence {
    # Re-checks one fact against its source: 'confirmed' (evidence phrase found), 'missing' (page reachable, phrase
    # absent), 'unreachable' (network, blocked, or page gone), or 'not-checkable' (no evidence phrase or no source).
    param([Parameter(Mandatory)]$Fact, [Parameter(Mandatory)]$Sources, [string]$DataDir = '', [double]$MaxAgeDays = 7, [switch]$Refresh)
    if ($null -eq $Fact -or -not $Fact.Contains('evidence') -or -not $Fact['evidence'] -or -not $Fact['source']) { return [ordered]@{ result = 'not-checkable'; detail = 'no evidence phrase or source' } }
    $url = [string]$Fact['source']
    $u = Get-UrlSpace $url
    if ($u.host -ne 'other') { $r = Get-DocPage -Url $url -Sources $Sources -DataDir $DataDir -AppliesTo 'evidence' -MaxAgeDays $MaxAgeDays -Refresh:$Refresh; $status = $r.status; $body = $r.body; $ct = '' }
    else {
        $c = Invoke-CachedGet -Url $url -DataDir $DataDir -MaxAgeDays $MaxAgeDays -Refresh:$Refresh -Label ([ordered]@{ sourceType = [string]$Fact['sourceType'] })
        $status = $c.status; $body = $c.body; $ct = ''
        if ($c.meta) { $ct = [string]$c.meta['contentType'] }
    }
    if ($status -eq 'not-found') { return [ordered]@{ result = 'missing'; detail = 'source page not found' } }
    if ($status -ne 'ok') { return [ordered]@{ result = 'unreachable'; detail = $status } }
    $hay = ConvertTo-EvidenceText -Text ([string]$body) -Html:($ct -match 'html')
    $needle = ConvertTo-EvidenceText -Text ([string]$Fact['evidence'])
    if ($hay.Contains($needle.Trim())) { return [ordered]@{ result = 'confirmed'; detail = $url } }
    return [ordered]@{ result = 'missing'; detail = 'evidence phrase not found on the source page' }
}

Export-ModuleMember -Function Get-SpaceTemplate, Expand-UrlTemplate, Resolve-DocSpace, Get-DocLayout, Resolve-DocPagePath, Resolve-DocUrl, Get-UrlSpace, Test-ChallengePage, Test-DocResponse, Get-DocPage, Find-DocSpaceByProbe, Get-DocIndex, Get-LtsInfo, ConvertTo-EvidenceText, Test-FactEvidence
