# Knowledge.psm1 - version knowledge: lookup order, schema validation, version arithmetic,
# canonical JSON output, fact listing, and a line diff for maintainers.
#
# Lookup order (per file): refreshed data in <plugin data>/knowledge/<kind>.json when it parses, its schema
# major version matches the baseline, it validates, and its verifiedAt is newer than the baseline's;
# otherwise the baseline shipped in <plugin root>/knowledge/<kind>.json.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'JsonSchema.psm1') -DisableNameChecking

$script:PluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Kinds = @('versions', 'paths', 'packages', 'sources')
$script:SupportedSchemaMajor = 1
$script:SchemaCache = $null

function Get-KnowledgeKinds { return $script:Kinds }
function Get-KnowledgePluginRoot { return $script:PluginRoot }

function Get-KnowledgeSchema {
    if ($null -eq $script:SchemaCache) {
        $script:SchemaCache = ConvertTo-PlainObject (Read-JsonFile (Join-Path $script:PluginRoot 'schemas/knowledge.schema.json'))
    }
    return $script:SchemaCache
}

function Test-KnowledgeDocument {
    # Returns schema errors for one knowledge document (empty when valid).
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][ValidateSet('versions', 'paths', 'packages', 'sources')][string]$Kind)
    $errs = New-Object System.Collections.ArrayList
    foreach ($e in (Test-JsonSchema -Value $Document -Schema (Get-KnowledgeSchema) -Definition ($Kind + 'File'))) { [void]$errs.Add($e) }
    if ($Document -is [System.Collections.IDictionary] -and $Document.Contains('kind') -and $Document['kind'] -ne $Kind) { [void]$errs.Add("`$.kind: expected '$Kind'") }
    return ,($errs.ToArray())
}

function Get-BaselineKnowledgePath { param([string]$Kind) return (Join-Path (Join-Path $script:PluginRoot 'knowledge') ($Kind + '.json')) }
function Get-RefreshedKnowledgeDir { param([Parameter(Mandatory)][string]$DataDir) return (Join-Path $DataDir 'knowledge') }

function Get-KnowledgeFile {
    # Applies the lookup order for one file. Returns kind, origin (baseline or refreshed), path, data, verifiedAt, reason.
    param([Parameter(Mandatory)][ValidateSet('versions', 'paths', 'packages', 'sources')][string]$Kind, [string]$DataDir = '')
    $basePath = Get-BaselineKnowledgePath $Kind
    $base = ConvertTo-PlainObject (Read-JsonFile $basePath)
    $baseErrors = Test-KnowledgeDocument -Document $base -Kind $Kind
    if ($baseErrors.Count -gt 0) { throw "Baseline knowledge $Kind.json is invalid: $($baseErrors -join '; ')" }
    $result = [ordered]@{ kind = $Kind; origin = 'baseline'; path = $basePath; schemaVersion = $base['schemaVersion']; verifiedAt = $base['verifiedAt']; knowledgeVersion = $base['knowledgeVersion']; baselineVerifiedAt = $base['verifiedAt']; reason = 'no refreshed data'; data = $base }
    if (-not $DataDir) { $result.reason = 'no plugin data directory given'; return $result }
    $refPath = Join-Path (Get-RefreshedKnowledgeDir $DataDir) ($Kind + '.json')
    if (-not [System.IO.File]::Exists($refPath)) { return $result }
    $ref = $null
    try { $ref = ConvertTo-PlainObject (Read-JsonFile $refPath) } catch { $result.reason = "refreshed file unreadable: $($_.Exception.Message)"; return $result }
    $ver = ''
    if ($ref -is [System.Collections.IDictionary] -and $ref.Contains('schemaVersion')) { $ver = [string]$ref['schemaVersion'] }
    if ($ver -notmatch '^(\d+)\.\d+\.\d+$' -or [int]$Matches[1] -ne $script:SupportedSchemaMajor) {
        $result.reason = "refreshed schema version '$ver' is not compatible with $($script:SupportedSchemaMajor).x; using the baseline"
        return $result
    }
    $errs = Test-KnowledgeDocument -Document $ref -Kind $Kind
    if ($errs.Count -gt 0) { $result.reason = "refreshed file is invalid ($($errs[0])); using the baseline"; return $result }
    if ([string]$ref['verifiedAt'] -le [string]$base['verifiedAt']) {
        $result.reason = "refreshed data ($($ref['verifiedAt'])) is not newer than the baseline ($($base['verifiedAt'])); using the baseline"
        return $result
    }
    $result.origin = 'refreshed'; $result.path = $refPath; $result.schemaVersion = $ver
    $result.verifiedAt = $ref['verifiedAt']; $result.knowledgeVersion = $ref['knowledgeVersion']
    $result.reason = 'refreshed data is newer than the baseline and compatible'
    $result.data = $ref
    return $result
}

function Get-Knowledge {
    # All knowledge files, each through the lookup order.
    param([string]$DataDir = '')
    $k = [ordered]@{}
    foreach ($kind in $script:Kinds) { $k[$kind] = Get-KnowledgeFile -Kind $kind -DataDir $DataDir }
    return $k
}

# ---------------------------------------------------------------- versions

function ConvertTo-VersionParts {
    # "13" -> 13,0,0 ; "13.9" -> 13,9,0 ; "13.9.1-rc" -> 13,9,1 (prerelease labels are dropped).
    param([Parameter(Mandatory)][string]$Version)
    $core = ($Version -split '[-+]')[0]
    if ($core -notmatch '^\d+(\.\d+){0,3}$') { throw "Not a version: '$Version'" }
    $p = @($core -split '\.' | ForEach-Object { [int]$_ })
    while ($p.Count -lt 3) { $p += 0 }
    return ,$p
}

function Compare-Version {
    # -1, 0, 1 on the numeric parts. A prerelease sorts before its release.
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    $pa = ConvertTo-VersionParts $A; $pb = ConvertTo-VersionParts $B
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { $x = $pa[$i] }
        if ($i -lt $pb.Count) { $y = $pb[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    $preA = $A.Contains('-'); $preB = $B.Contains('-')
    if ($preA -and -not $preB) { return -1 }
    if ($preB -and -not $preA) { return 1 }
    return 0
}

function Get-VersionMajor { param([Parameter(Mandatory)][string]$Version) return (ConvertTo-VersionParts $Version)[0] }

function Get-MajorEntry {
    param([Parameter(Mandatory)]$Versions, [Parameter(Mandatory)][int]$Major)
    foreach ($m in @($Versions['majors'])) { if ([int]$m['major'] -eq $Major) { return $m } }
    return $null
}

function Get-FactValue {
    # Value of a fact, or $null when the fact is absent.
    param($Entry, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Entry -or -not ($Entry -is [System.Collections.IDictionary]) -or -not $Entry.Contains($Name) -or $null -eq $Entry[$Name]) { return $null }
    return $Entry[$Name]['value']
}

# ---------------------------------------------------------------- facts

function Test-IsFact {
    param($Node)
    return ($Node -is [System.Collections.IDictionary] -and $Node.Contains('value') -and $Node.Contains('status') -and $Node.Contains('verifiedAt') -and $Node.Contains('source'))
}

function Get-FactList {
    # Walks a knowledge document and returns every fact with its JSON path.
    param([Parameter(Mandatory)]$Document)
    $list = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push(@('$', $Document))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $path = $item[0]; $node = $item[1]
        if (Test-IsFact $node) { [void]$list.Add([ordered]@{ path = $path; fact = $node }); continue }
        if ($node -is [System.Collections.IDictionary]) {
            $keys = @($node.Keys); [array]::Reverse($keys)
            foreach ($k in $keys) { $stack.Push(@("$path.$k", $node[$k])) }
        } elseif ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            $arr = @($node)
            for ($i = $arr.Count - 1; $i -ge 0; $i--) {
                $label = "$path[$i]"
                if ($arr[$i] -is [System.Collections.IDictionary]) {
                    foreach ($idKey in @('major', 'id', 'channel', 'from')) { if ($arr[$i].Contains($idKey)) { $label = "$path[$idKey=$($arr[$i][$idKey])]"; break } }
                }
                $stack.Push(@($label, $arr[$i]))
            }
        }
    }
    return ,($list.ToArray())
}

function Get-Today { return [DateTime]::UtcNow.ToString('yyyy-MM-dd') }

# ---------------------------------------------------------------- canonical JSON

function Add-JsonString {
    param([System.Text.StringBuilder]$Sb, [string]$Text)
    [void]$Sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        switch ($c) {
            0x22 { [void]$Sb.Append('\"'); continue }
            0x5C { [void]$Sb.Append('\\'); continue }
            0x0A { [void]$Sb.Append('\n'); continue }
            0x0D { [void]$Sb.Append('\r'); continue }
            0x09 { [void]$Sb.Append('\t'); continue }
            0x08 { [void]$Sb.Append('\b'); continue }
            0x0C { [void]$Sb.Append('\f'); continue }
            default {
                if ($c -lt 0x20 -or $c -gt 0x7E) { [void]$Sb.Append('\u' + $c.ToString('x4')) }
                else { [void]$Sb.Append($ch) }
            }
        }
    }
    [void]$Sb.Append('"')
}

function Add-JsonValue {
    param([System.Text.StringBuilder]$Sb, $Value, [int]$Indent)
    $pad = ' ' * ($Indent + 2)
    if ($null -eq $Value) { [void]$Sb.Append('null'); return }
    if ($Value -is [bool]) { if ($Value) { [void]$Sb.Append('true') } else { [void]$Sb.Append('false') }; return }
    if ($Value -is [string]) { Add-JsonString $Sb $Value; return }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { [void]$Sb.Append($Value.ToString([Globalization.CultureInfo]::InvariantCulture)); return }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        if ([Math]::Floor([double]$Value) -eq [double]$Value) { [void]$Sb.Append(([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)) }
        else { [void]$Sb.Append(([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)) }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { [void]$Sb.Append('{}'); return }
        [void]$Sb.Append("{`n")
        $first = $true
        foreach ($k in $Value.Keys) {
            if (-not $first) { [void]$Sb.Append(",`n") }
            $first = $false
            [void]$Sb.Append($pad)
            Add-JsonString $Sb ([string]$k)
            [void]$Sb.Append(': ')
            Add-JsonValue $Sb $Value[$k] ($Indent + 2)
        }
        [void]$Sb.Append("`n" + (' ' * $Indent) + '}')
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $arr = @($Value)
        if ($arr.Count -eq 0) { [void]$Sb.Append('[]'); return }
        [void]$Sb.Append("[`n")
        for ($i = 0; $i -lt $arr.Count; $i++) {
            if ($i -gt 0) { [void]$Sb.Append(",`n") }
            [void]$Sb.Append($pad)
            Add-JsonValue $Sb $arr[$i] ($Indent + 2)
        }
        [void]$Sb.Append("`n" + (' ' * $Indent) + ']')
        return
    }
    Add-JsonString $Sb ([string]$Value)
}

function ConvertTo-StableJson {
    # Deterministic JSON: two-space indent, one member per line, ASCII only (non-ASCII escaped), LF, final newline.
    # Same output on Windows PowerShell 5.1 and PowerShell 7, so refreshed files diff cleanly against the baseline.
    param([Parameter(Mandatory)]$InputObject)
    $sb = New-Object System.Text.StringBuilder
    Add-JsonValue $sb (ConvertTo-PlainObject $InputObject) 0
    [void]$sb.Append("`n")
    return $sb.ToString()
}

# ---------------------------------------------------------------- unified diff

function New-UnifiedDiff {
    # Line diff in unified format (3 lines of context) that git apply accepts. Returns '' when the texts are equal.
    param([AllowEmptyString()][string]$OldText, [AllowEmptyString()][string]$NewText, [Parameter(Mandatory)][string]$OldName, [Parameter(Mandatory)][string]$NewName, [int]$Context = 3)
    $a = @(([string]$OldText -replace "`r`n", "`n").TrimEnd("`n") -split "`n")
    $b = @(([string]$NewText -replace "`r`n", "`n").TrimEnd("`n") -split "`n")
    if (-not $OldText) { $a = @() }
    if (-not $NewText) { $b = @() }
    if (($a -join "`n") -ceq ($b -join "`n")) { return '' }
    # Trim the common prefix and suffix, then run an LCS on the middle.
    $pre = 0
    while ($pre -lt $a.Count -and $pre -lt $b.Count -and $a[$pre] -ceq $b[$pre]) { $pre++ }
    $suf = 0
    while ($suf -lt ($a.Count - $pre) -and $suf -lt ($b.Count - $pre) -and $a[$a.Count - 1 - $suf] -ceq $b[$b.Count - 1 - $suf]) { $suf++ }
    $n = $a.Count - $pre - $suf; $m = $b.Count - $pre - $suf
    $lcs = New-Object 'int[,]' ($n + 1), ($m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($a[$pre + $i] -ceq $b[$pre + $j]) { $lcs[$i, $j] = $lcs[($i + 1), ($j + 1)] + 1 }
            else { $x = $lcs[($i + 1), $j]; $y = $lcs[$i, ($j + 1)]; if ($x -ge $y) { $lcs[$i, $j] = $x } else { $lcs[$i, $j] = $y } }
        }
    }
    $ops = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $pre; $k++) { [void]$ops.Add(@(' ', $a[$k])) }
    $i = 0; $j = 0
    while ($i -lt $n -or $j -lt $m) {
        if ($i -lt $n -and $j -lt $m -and $a[$pre + $i] -ceq $b[$pre + $j]) { [void]$ops.Add(@(' ', $a[$pre + $i])); $i++; $j++ }
        elseif ($i -lt $n -and ($j -ge $m -or $lcs[($i + 1), $j] -ge $lcs[$i, ($j + 1)])) { [void]$ops.Add(@('-', $a[$pre + $i])); $i++ }
        else { [void]$ops.Add(@('+', $b[$pre + $j])); $j++ }
    }
    for ($k = $a.Count - $suf; $k -lt $a.Count; $k++) { [void]$ops.Add(@(' ', $a[$k])) }
    # Group changes into hunks.
    $changeIdx = @(); for ($k = 0; $k -lt $ops.Count; $k++) { if ($ops[$k][0] -ne ' ') { $changeIdx += $k } }
    $out = New-Object System.Text.StringBuilder
    [void]$out.Append("--- $OldName`n+++ $NewName`n")
    $h = 0
    while ($h -lt $changeIdx.Count) {
        $start = [Math]::Max(0, $changeIdx[$h] - $Context)
        $end = $changeIdx[$h]
        while ($h + 1 -lt $changeIdx.Count -and $changeIdx[$h + 1] - $end -le 2 * $Context) { $h++; $end = $changeIdx[$h] }
        $end = [Math]::Min($ops.Count - 1, $end + $Context)
        $oldBefore = 0; $newBefore = 0
        for ($k = 0; $k -lt $start; $k++) { if ($ops[$k][0] -ne '+') { $oldBefore++ }; if ($ops[$k][0] -ne '-') { $newBefore++ } }
        $oldCount = 0; $newCount = 0
        for ($k = $start; $k -le $end; $k++) { if ($ops[$k][0] -ne '+') { $oldCount++ }; if ($ops[$k][0] -ne '-') { $newCount++ } }
        $oldStart = $oldBefore + 1; if ($oldCount -eq 0) { $oldStart = $oldBefore }
        $newStart = $newBefore + 1; if ($newCount -eq 0) { $newStart = $newBefore }
        [void]$out.Append("@@ -$oldStart,$oldCount +$newStart,$newCount @@`n")
        for ($k = $start; $k -le $end; $k++) { [void]$out.Append($ops[$k][0] + $ops[$k][1] + "`n") }
        $h++
    }
    return $out.ToString()
}

Export-ModuleMember -Function Get-KnowledgeKinds, Get-KnowledgePluginRoot, Get-KnowledgeSchema, Test-KnowledgeDocument, Get-BaselineKnowledgePath, Get-RefreshedKnowledgeDir, Get-KnowledgeFile, Get-Knowledge, ConvertTo-VersionParts, Compare-Version, Get-VersionMajor, Get-MajorEntry, Get-FactValue, Test-IsFact, Get-FactList, Get-Today, ConvertTo-StableJson, New-UnifiedDiff
