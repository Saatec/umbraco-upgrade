# Compat.psm1 - helpers that behave the same on Windows PowerShell 5.1 and PowerShell 7.
# Rules: no 7-only syntax, explicit UTF-8 for every file read and write.

Set-StrictMode -Version 2.0

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-IoPath {
    # Windows PowerShell 5.1 cannot open a file or folder whose full path has about 260 characters or more unless the
    # path carries the \\?\ prefix. Long full paths get the prefix on Windows; every other path is returned unchanged.
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::DirectorySeparatorChar -ne [char]'\' -or $Path.Length -lt 240 -or $Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertFrom-IoPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    # Detects a UTF-8 or UTF-16 BOM; otherwise reads as UTF-8.
    return [System.IO.File]::ReadAllText((ConvertTo-IoPath (Resolve-FullPath $Path)), $script:Utf8NoBom)
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content = '')
    $full = Resolve-FullPath $Path
    $dir = ConvertTo-IoPath ([System.IO.Path]::GetDirectoryName($full))
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText((ConvertTo-IoPath $full), $Content, $script:Utf8NoBom)
}

function Write-AtomicTextFile {
    # Writes to a temp file in the same directory, then swaps it into place.
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content = '')
    $full = Resolve-FullPath $Path
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if (-not [System.IO.Directory]::Exists((ConvertTo-IoPath $dir))) { [void][System.IO.Directory]::CreateDirectory((ConvertTo-IoPath $dir)) }
    # The temporary name adds about 40 characters, so a path well below the limit can still need the prefix.
    $tmp = ConvertTo-IoPath (Join-Path $dir ('.' + [System.IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.tmp'))
    $full = ConvertTo-IoPath $full
    [System.IO.File]::WriteAllText($tmp, $Content, $script:Utf8NoBom)
    try {
        if ([System.IO.File]::Exists($full)) {
            [System.IO.File]::Replace($tmp, $full, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tmp, $full)
        }
    } finally {
        if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) }
    }
}

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Get-RelativePathCompat {
    # [IO.Path]::GetRelativePath does not exist on .NET Framework (5.1).
    param([Parameter(Mandatory)][string]$BasePath, [Parameter(Mandatory)][string]$Path)
    $base = (Resolve-FullPath $BasePath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $full = Resolve-FullPath $Path
    if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($full.Substring($base.Length) -replace '\\', '/')
    }
    if ($full.TrimEnd('\', '/') -ieq $base.TrimEnd('\', '/')) { return '.' }
    $baseUri = New-Object System.Uri($base)
    $uri = New-Object System.Uri($full)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($uri).ToString())
}

function Test-PathUnder {
    # True when $Path equals $Root or lies below it (case-insensitive, separator-agnostic).
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $r = (Resolve-FullPath $Root).TrimEnd('\', '/') -replace '/', '\'
    $p = (Resolve-FullPath $Path).TrimEnd('\', '/') -replace '/', '\'
    if ($p -ieq $r) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-JsonComments {
    # Strips // and /* */ comments and trailing commas outside strings (appsettings.json style).
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $Text.Length; $inString = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
            if ($c -eq '"') { $inString = $false }
            $i++; continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '*') {
            $i += 2
            while (($i + 1) -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
            $i += 2; continue
        }
        if ($c -eq ',') {
            $j = $i + 1
            while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
            if ($j -lt $n -and ($Text[$j] -eq '}' -or $Text[$j] -eq ']')) { $i++; continue }
            # A comment may sit between the comma and the closing bracket.
            if (($j + 1) -lt $n -and $Text[$j] -eq '/' -and ($Text[$j + 1] -eq '/' -or $Text[$j + 1] -eq '*')) {
                $rest = Remove-JsonComments ($Text.Substring($j))
                $k = 0
                while ($k -lt $rest.Length -and [char]::IsWhiteSpace($rest[$k])) { $k++ }
                if ($k -lt $rest.Length -and ($rest[$k] -eq '}' -or $rest[$k] -eq ']')) { $i++; continue }
            }
        }
        [void]$sb.Append($c); $i++
    }
    return $sb.ToString()
}

function ConvertFrom-JsonText {
    # Parses JSON that may contain comments and trailing commas. Returns PSCustomObject trees.
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $clean = Remove-JsonComments $Text
    return ($clean | ConvertFrom-Json)
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return ConvertFrom-JsonText (Read-TextFile $Path)
}

function ConvertTo-PlainObject {
    # Converts PSCustomObject trees into ordered hashtables and object[] arrays (no -AsHashtable on 5.1).
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    # PowerShell 7 turns ISO date strings into DateTime; keep them as UTC strings so state round-trips.
    if ($InputObject -is [DateTime]) { return $InputObject.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-PlainObject $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainObject $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-PlainObject $item)) }
        return ,($list.ToArray())
    }
    return $InputObject
}

function ConvertTo-JsonText {
    param($InputObject, [int]$Depth = 64, [switch]$Compress)
    if ($Compress) { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress }
    else { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth }
    # Windows PowerShell escapes ' < > & as \uXXXX; restore them for readability (still valid JSON).
    $json = [regex]::Replace($json, '(?<=(?:^|[^\\])(?:\\\\)*)\\u(0027|003c|003e|0026)', {
        param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16)
    })
    return $json
}

function Write-JsonOutput {
    # Prints one JSON document to stdout as UTF-8.
    param($InputObject, [switch]$Compress)
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-JsonText -InputObject $InputObject -Compress:$Compress) + [Environment]::NewLine)
    $stream = [Console]::OpenStandardOutput()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Read-XmlFile {
    # Safe XML load: no DTD processing, no external resolution.
    param([Parameter(Mandatory)][string]$Path)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $text = Read-TextFile $Path
    $sr = New-Object System.IO.StringReader($text)
    $reader = [System.Xml.XmlReader]::Create($sr, $settings)
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        return $doc
    } finally {
        $reader.Close()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-IoPath (Resolve-FullPath $Path)))
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-UtcTimestamp {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

$script:DefaultExcludedDirs = @('.git', '.vs', '.vscode', '.idea', 'node_modules', 'bin', 'obj', 'packages', '.umbraco-upgrade', 'TestResults')

function Get-ProjectFiles {
    # Enumerates files below $Root, skipping build output, dependency folders, and temp data.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludeDirs = $script:DefaultExcludedDirs,
        # Matched at the root and below it (a web project in a subfolder). App_Data/NuGetBackup holds the copies of
        # configuration and backoffice folders that the Umbraco 7 core package's install script makes on each update.
        [string[]]$ExcludeRelative = @('App_Data/TEMP', 'umbraco/Data/TEMP', 'umbraco/Logs', 'App_Data/Logs', 'App_Data/NuGetBackup')
    )
    $rootFull = (Resolve-FullPath $Root).TrimEnd('\', '/')
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)
    $result = New-Object System.Collections.Generic.List[string]
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        $io = ConvertTo-IoPath $dir
        try {
            foreach ($f in [System.IO.Directory]::GetFiles($io)) { $result.Add((ConvertFrom-IoPath $f)) }
            foreach ($d0 in [System.IO.Directory]::GetDirectories($io)) {
                $d = ConvertFrom-IoPath $d0
                $name = [System.IO.Path]::GetFileName($d)
                if ($ExcludeDirs -contains $name) { continue }
                $rel = $d.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
                $skip = $false
                foreach ($x in $ExcludeRelative) { if ($rel -ieq $x -or $rel.EndsWith('/' + $x, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break } }
                if ($skip) { continue }
                $attr = [System.IO.File]::GetAttributes((ConvertTo-IoPath $d))
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($d)
            }
        } catch [System.UnauthorizedAccessException] { continue } catch [System.IO.IOException] { continue }
    }
    return ,($result.ToArray())
}

function ConvertTo-GlobRegex {
    # Converts a glob (**, *, ?) on forward-slash relative paths to an anchored regex.
    param([Parameter(Mandatory)][string]$Glob)
    $g = $Glob -replace '\\', '/'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*' -and ($i + 1) -lt $g.Length -and $g[$i + 1] -eq '*') {
            if (($i + 2) -lt $g.Length -and $g[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
            [void]$sb.Append('.*'); $i += 2; continue
        }
        if ($c -eq '*') { [void]$sb.Append('[^/]*'); $i++; continue }
        if ($c -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
        [void]$sb.Append([regex]::Escape([string]$c)); $i++
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

function Test-GlobMatch {
    param([Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][string[]]$Globs)
    $p = $RelativePath -replace '\\', '/'
    foreach ($g in $Globs) {
        if ($p -match (ConvertTo-GlobRegex $g)) { return $true }
    }
    return $false
}

Export-ModuleMember -Function *
