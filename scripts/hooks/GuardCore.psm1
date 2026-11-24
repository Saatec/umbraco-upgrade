# GuardCore.psm1 - command analysis and rule evaluation for the PreToolUse guard.
# Loaded only inside upgrade projects. The tokenizer is best-effort against deliberate obfuscation;
# commands that cannot be analyzed in scope raise an error, which the guard turns into a block.

Set-StrictMode -Version 2.0
$libDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
Import-Module (Join-Path $libDir 'Compat.psm1') -DisableNameChecking
Import-Module (Join-Path $libDir 'Redaction.psm1') -DisableNameChecking
Import-Module (Join-Path $libDir 'Git.psm1') -DisableNameChecking
Import-Module (Join-Path $libDir 'ConnectionInfo.psm1') -DisableNameChecking

$script:RulesDoc = $null
$script:RuleMap = @{}

function Get-GuardRules {
    if ($null -eq $script:RulesDoc) {
        $script:RulesDoc = Read-JsonFile (Join-Path $PSScriptRoot 'rules.json')
        foreach ($r in $script:RulesDoc.rules) { $script:RuleMap[$r.id] = $r }
    }
    return $script:RulesDoc
}

function Get-GuardList { param([string]$Name) return @((Get-GuardRules).lists.$Name) }

function New-GuardDecision {
    param([string]$RuleId, [string]$Detail = '')
    [void](Get-GuardRules)
    $r = $script:RuleMap[$RuleId]
    if ($null -eq $r) { throw "Unknown guard rule '$RuleId'." }
    $reason = [string]$r.reason
    if ($Detail) { $reason = $reason + ' (' + $Detail + ')' }
    return [ordered]@{ decision = [string]$r.decision; ruleId = $RuleId; reason = $reason }
}

# ================================================================== tokenizer

function Find-ClosingBracket {
    # $Start points at the opening bracket. Returns the index of the matching closer, or the last index.
    param([string]$Text, [int]$Start, [char]$Open = '(', [char]$Close = ')')
    $depth = 0; $i = $Start; $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq "'") { $j = $Text.IndexOf("'", $i + 1); if ($j -lt 0) { return $n - 1 }; $i = $j + 1; continue }
        if ($c -eq '"') {
            $j = $i + 1
            while ($j -lt $n -and $Text[$j] -ne '"') { if ($Text[$j] -eq '\' -or $Text[$j] -eq '`') { $j++ }; $j++ }
            $i = $j + 1; continue
        }
        if ($c -eq $Open) { $depth++ }
        elseif ($c -eq $Close) { $depth--; if ($depth -eq 0) { return $i } }
        $i++
    }
    return $n - 1
}

function Split-CommandText {
    # Splits shell text into simple commands. Returns records: words, inputs (input redirect targets), dialect, dynamic.
    # Nested $( ), backticks (bash), <( ) are analyzed recursively and returned as their own records.
    param([AllowEmptyString()][string]$Text, [ValidateSet('bash', 'powershell', 'cmd')][string]$Dialect = 'bash', [int]$Depth = 0)
    if ($Depth -gt 8) { throw 'Command nesting is too deep to analyze.' }
    $commands = New-Object System.Collections.ArrayList
    $words = New-Object System.Collections.ArrayList
    $inputs = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $st = @{ inWord = $false; redirect = 0; dynamic = $false; heredocs = (New-Object System.Collections.ArrayList) }
    if ($null -eq $Text) { $Text = '' }
    $n = $Text.Length; $i = 0

    function local:FlushWord {
        if ($st.inWord) {
            $w = $sb.ToString(); [void]$sb.Clear(); $st.inWord = $false
            if ($st.redirect -eq 1) { $st.redirect = 0 }
            elseif ($st.redirect -eq 2) { [void]$inputs.Add($w); $st.redirect = 0 }
            elseif ($st.redirect -eq 3) { [void]$st.heredocs.Add($w); $st.redirect = 0 }
            else { [void]$words.Add($w) }
        }
    }
    function local:FlushCommand {
        FlushWord
        if ($words.Count -gt 0 -or $inputs.Count -gt 0) {
            [void]$commands.Add([ordered]@{ words = @($words.ToArray()); inputs = @($inputs.ToArray()); dialect = $Dialect; dynamic = $st.dynamic })
        }
        $words.Clear(); $inputs.Clear(); $st.dynamic = $false; $st.redirect = 0
    }
    function local:AddNested([string]$Inner, [string]$NestedDialect) {
        foreach ($c in (Split-CommandText -Text $Inner -Dialect $NestedDialect -Depth ($Depth + 1))) { [void]$commands.Add($c) }
        $st.dynamic = $true
    }

    while ($i -lt $n) {
        $c = $Text[$i]
        $nx = [char]0; if (($i + 1) -lt $n) { $nx = $Text[$i + 1] }

        # Line continuations.
        if (($Dialect -eq 'bash' -and $c -eq '\') -or ($Dialect -eq 'powershell' -and $c -eq '`') -or ($Dialect -eq 'cmd' -and $c -eq '^')) {
            if ($nx -eq "`n") { $i += 2; continue }
            if ($nx -eq "`r" -and ($i + 2) -lt $n -and $Text[$i + 2] -eq "`n") { $i += 3; continue }
        }
        if ($c -eq ' ' -or $c -eq "`t") { FlushWord; $i++; continue }
        if ($c -eq "`r" -or $c -eq "`n") {
            FlushCommand
            $i++
            if ($st.heredocs.Count -gt 0 -and $c -eq "`n") {
                foreach ($delim in @($st.heredocs)) {
                    while ($i -lt $n) {
                        $eol = $Text.IndexOf("`n", $i); if ($eol -lt 0) { $eol = $n }
                        $line = $Text.Substring($i, $eol - $i).Trim()
                        $i = $eol + 1
                        if ($line -eq $delim) { break }
                    }
                }
                $st.heredocs.Clear()
            }
            continue
        }
        if ($c -eq '#' -and -not $st.inWord -and $Dialect -ne 'cmd') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq ';') { FlushCommand; $i++; continue }
        if ($c -eq '|') { FlushCommand; $i++; if ($nx -eq '|') { $i++ }; continue }
        if ($c -eq '&') {
            if ($nx -eq '&') { FlushCommand; $i += 2; continue }
            FlushCommand; $i++; continue
        }
        if (($c -eq '$' -or ($c -eq '@' -and $Dialect -eq 'powershell')) -and $nx -eq '(' -and $Dialect -ne 'cmd') {
            $end = Find-ClosingBracket -Text $Text -Start ($i + 1)
            AddNested $Text.Substring($i + 2, [Math]::Max(0, $end - $i - 2)) $Dialect
            [void]$sb.Append('$()'); $st.inWord = $true
            $i = $end + 1; continue
        }
        if ($c -eq '$' -and $nx -eq '{' -and $Dialect -ne 'cmd') {
            $end = $Text.IndexOf('}', $i + 2); if ($end -lt 0) { $end = $n - 1 }
            [void]$sb.Append($Text.Substring($i, $end - $i + 1)); $st.inWord = $true; $st.dynamic = $true
            $i = $end + 1; continue
        }
        if ($c -eq '$' -and $Dialect -ne 'cmd' -and ($nx -match '[A-Za-z_]')) { $st.dynamic = $true }
        if ($c -eq '%' -and $Dialect -eq 'cmd') { $st.dynamic = $true }
        if ($c -eq '(' -or $c -eq ')') { FlushCommand; $i++; continue }
        if ($c -eq '{' -or $c -eq '}') {
            if ($Dialect -eq 'cmd') { [void]$sb.Append($c); $st.inWord = $true; $i++; continue }
            FlushCommand; $i++; continue
        }
        if ($c -eq '<' -and $Dialect -eq 'powershell' -and $nx -eq '#') {
            $end = $Text.IndexOf('#>', $i + 2); if ($end -lt 0) { $i = $n } else { $i = $end + 2 }
            continue
        }
        if ($c -eq '<' -and $Dialect -eq 'bash' -and $nx -eq '(') {
            $end = Find-ClosingBracket -Text $Text -Start ($i + 1)
            AddNested $Text.Substring($i + 2, [Math]::Max(0, $end - $i - 2)) 'bash'
            $i = $end + 1; continue
        }
        if ($c -eq '>' -or $c -eq '<') {
            if ($st.inWord -and $sb.ToString() -match '^\d+$|^\*$') { [void]$sb.Clear(); $st.inWord = $false } else { FlushWord }
            $isInput = ($c -eq '<')
            $i++
            if ($isInput -and $i -lt $n -and $Text[$i] -eq '<') {
                $i++
                if ($i -lt $n -and $Text[$i] -eq '<') { $i++; $st.redirect = 1; continue }   # here-string: skip the word
                if ($i -lt $n -and $Text[$i] -eq '-') { $i++ }
                $st.redirect = 3; continue                                                 # heredoc delimiter
            }
            if ($i -lt $n -and $Text[$i] -eq '>') { $i++ }
            if ($i -lt $n -and $Text[$i] -eq '&') {
                $i++
                while ($i -lt $n -and ($Text[$i] -match '[\d\-]')) { $i++ }
                continue
            }
            $st.redirect = $(if ($isInput) { 2 } else { 1 })
            continue
        }
        if ($c -eq "'" -and $Dialect -ne 'cmd') {
            $j = $i + 1
            while ($j -lt $n) {
                if ($Text[$j] -eq "'") {
                    if ($Dialect -eq 'powershell' -and ($j + 1) -lt $n -and $Text[$j + 1] -eq "'") { [void]$sb.Append("'"); $j += 2; continue }
                    break
                }
                [void]$sb.Append($Text[$j]); $j++
            }
            $st.inWord = $true; $i = $j + 1; continue
        }
        if ($c -eq '"') {
            $j = $i + 1
            while ($j -lt $n) {
                $d = $Text[$j]
                $dn = [char]0; if (($j + 1) -lt $n) { $dn = $Text[$j + 1] }
                if ($d -eq '"') {
                    if ($Dialect -eq 'powershell' -and $dn -eq '"') { [void]$sb.Append('"'); $j += 2; continue }
                    break
                }
                if ($Dialect -eq 'bash' -and $d -eq '\' -and ($dn -eq '"' -or $dn -eq '$' -or $dn -eq '`' -or $dn -eq '\')) { [void]$sb.Append($dn); $j += 2; continue }
                if ($Dialect -eq 'powershell' -and $d -eq '`' -and $dn -ne [char]0) { [void]$sb.Append($dn); $j += 2; continue }
                if ($Dialect -ne 'cmd' -and $d -eq '$' -and $dn -eq '(') {
                    $end = Find-ClosingBracket -Text $Text -Start ($j + 1)
                    AddNested $Text.Substring($j + 2, [Math]::Max(0, $end - $j - 2)) $Dialect
                    [void]$sb.Append('$()'); $j = $end + 1; continue
                }
                if ($Dialect -eq 'bash' -and $d -eq '`') {
                    $end = $Text.IndexOf('`', $j + 1); if ($end -lt 0) { $end = $n - 1 }
                    AddNested $Text.Substring($j + 1, [Math]::Max(0, $end - $j - 1)) 'bash'
                    $j = $end + 1; continue
                }
                if ($d -eq '$' -and $Dialect -ne 'cmd') { $st.dynamic = $true }
                if ($d -eq '%' -and $Dialect -eq 'cmd') { $st.dynamic = $true }
                [void]$sb.Append($d); $j++
            }
            $st.inWord = $true; $i = $j + 1; continue
        }
        if ($Dialect -eq 'bash' -and $c -eq '\') {
            if ($nx -ne [char]0) { [void]$sb.Append($nx) }
            $st.inWord = $true; $i += 2; continue
        }
        if ($Dialect -eq 'powershell' -and $c -eq '`') {
            if ($nx -ne [char]0) { [void]$sb.Append($nx) }
            $st.inWord = $true; $i += 2; continue
        }
        if ($Dialect -eq 'cmd' -and $c -eq '^') {
            if ($nx -ne [char]0) { [void]$sb.Append($nx) }
            $st.inWord = $true; $i += 2; continue
        }
        if ($Dialect -eq 'bash' -and $c -eq '`') {
            $end = $Text.IndexOf('`', $i + 1); if ($end -lt 0) { $end = $n - 1 }
            AddNested $Text.Substring($i + 1, [Math]::Max(0, $end - $i - 1)) 'bash'
            [void]$sb.Append('$()'); $st.inWord = $true
            $i = $end + 1; continue
        }
        [void]$sb.Append($c); $st.inWord = $true; $i++
    }
    FlushCommand
    return ,($commands.ToArray())
}

# ================================================================== normalization and wrappers

$script:PsAliases = @{
    'gc' = 'get-content'; 'gci' = 'get-childitem'; 'ls' = 'get-childitem'; 'dir' = 'get-childitem'; 'gi' = 'get-item'
    'sls' = 'select-string'; 'iex' = 'invoke-expression'; 'sl' = 'set-location'; 'cd' = 'set-location'; 'chdir' = 'set-location'
    'pushd' = 'push-location'; 'saps' = 'start-process'; 'start' = 'start-process'; 'fhx' = 'format-hex'; 'type' = 'get-content'; 'cat' = 'get-content'
}
$script:PassThroughPrefixes = @('sudo', 'doas', 'command', 'builtin', 'exec', 'nohup', 'time', 'nice', 'ionice', 'stdbuf', 'unbuffer', 'call', 'xargs')
$script:Shells = @('bash', 'sh', 'zsh', 'dash', 'ksh', 'ash', 'fish')
$script:PowerShells = @('powershell', 'pwsh', 'powershell_ise')

function Get-CommandName {
    param([AllowEmptyString()][string]$Word)
    if ([string]::IsNullOrEmpty($Word)) { return '' }
    $base = ($Word -split '[\\/]')[-1]
    $base = $base.ToLowerInvariant()
    $base = $base -replace '\.(exe|cmd|bat|com)$', ''
    return $base
}

function Resolve-CommandAlias {
    param([string]$Name, [string]$Dialect)
    if ($Dialect -eq 'powershell' -and $script:PsAliases.ContainsKey($Name)) { return $script:PsAliases[$Name] }
    if ($Name -eq 'cd' -or $Name -eq 'chdir') { return 'set-location' }
    if ($Name -eq 'pushd') { return 'push-location' }
    return $Name
}

function Test-EncodedCommandSwitch { param([string]$Arg) return [bool]($Arg -match '^(?i)[-/](e|ec|en|enc|enco|encod|encode|encoded|encodedc|encodedco|encodedcom|encodedcomm|encodedcomma|encodedcomman|encodedcommand)$') }
function Test-CommandSwitch { param([string]$Arg) return [bool]($Arg -match '^(?i)[-/](c|co|com|comm|comma|comman|command)$') }
function Test-FileSwitch { param([string]$Arg) return [bool]($Arg -match '^(?i)[-/](f|fi|fil|file)$') }

function Expand-CommandRecord {
    # Normalizes one record: strips prefixes and assignments, unwraps shells and Invoke-Expression, resolves aliases.
    param($Record, [int]$Depth = 0)
    if ($Depth -gt 8) { throw 'Command wrapping is too deep to analyze.' }
    $out = New-Object System.Collections.ArrayList
    $words = New-Object System.Collections.ArrayList
    foreach ($w in @($Record.words)) { [void]$words.Add([string]$w) }
    $dialect = [string]$Record.dialect

    while ($words.Count -gt 0) {
        $w0 = [string]$words[0]
        if ($dialect -ne 'powershell' -and $w0 -match '^[A-Za-z_][A-Za-z0-9_]*=') { $words.RemoveAt(0); continue }
        if ($w0 -eq '.' -or $w0 -eq '&') { $words.RemoveAt(0); continue }
        $nm = Get-CommandName $w0
        if ($script:PassThroughPrefixes -contains $nm) {
            $words.RemoveAt(0)
            while ($words.Count -gt 0 -and ([string]$words[0]).StartsWith('-')) { $words.RemoveAt(0) }
            continue
        }
        if ($nm -eq 'timeout' -and $dialect -ne 'cmd') {
            $words.RemoveAt(0)
            while ($words.Count -gt 0 -and ([string]$words[0]).StartsWith('-')) { $words.RemoveAt(0) }
            if ($words.Count -gt 0) { $words.RemoveAt(0) }
            continue
        }
        if ($nm -eq 'env') {
            $j = 1
            while ($j -lt $words.Count -and (([string]$words[$j]).StartsWith('-') -or [string]$words[$j] -match '^[A-Za-z_][A-Za-z0-9_]*=')) {
                if ([string]$words[$j] -in @('-u', '--unset', '-C', '--chdir', '-S', '--split-string')) { $j++ }
                $j++
            }
            if ($j -lt $words.Count) { $words.RemoveRange(0, $j); continue }
        }
        if ($nm -eq 'wsl') {
            $words.RemoveAt(0)
            while ($words.Count -gt 0 -and ([string]$words[0]).StartsWith('-')) {
                $o = [string]$words[0]; $words.RemoveAt(0)
                if ($o -in @('-d', '--distribution', '-u', '--user', '--cd') -and $words.Count -gt 0) { $words.RemoveAt(0) }
            }
            $dialect = 'bash'
            continue
        }
        break
    }
    if ($words.Count -eq 0) { return ,($out.ToArray()) }

    $name = Resolve-CommandAlias -Name (Get-CommandName ([string]$words[0])) -Dialect $dialect
    $argList = @(); if ($words.Count -gt 1) { $argList = @($words.GetRange(1, $words.Count - 1).ToArray()) }

    # Shell wrappers: bash -c "...".
    if ($script:Shells -contains $name) {
        for ($k = 0; $k -lt $argList.Count; $k++) {
            $a = [string]$argList[$k]
            if ($a -match '^-[A-Za-z]*c[A-Za-z]*$' -and ($k + 1) -lt $argList.Count) {
                foreach ($r in (Split-CommandText -Text ([string]$argList[$k + 1]) -Dialect 'bash' -Depth ($Depth + 1))) {
                    foreach ($e in (Expand-CommandRecord -Record $r -Depth ($Depth + 1))) { [void]$out.Add($e) }
                }
                return ,($out.ToArray())
            }
            if (-not $a.StartsWith('-')) { break }
        }
    }
    # PowerShell wrappers: powershell -Command "...", -EncodedCommand, or a bare command.
    if ($script:PowerShells -contains $name) {
        $valueOptions = '^(?i)[-/](ex|ep|executionpolicy|w|windowstyle|v|version|psc|psconsolefile|of|outputformat|if|inputformat|config|configurationname|wd|workingdirectory|settingsfile|custompipename)$'
        for ($k = 0; $k -lt $argList.Count; $k++) {
            $a = [string]$argList[$k]
            if (Test-EncodedCommandSwitch $a) {
                [void]$out.Add([ordered]@{ name = $name; args = $argList; dialect = $dialect; dynamic = $true; encoded = $true; inputs = @($Record.inputs) })
                return ,($out.ToArray())
            }
            if (Test-FileSwitch $a) { break }
            if (Test-CommandSwitch $a) {
                $script = (@($argList[($k + 1)..($argList.Count - 1)]) -join ' ')
                if (($k + 1) -ge $argList.Count) { $script = '' }
                foreach ($r in (Split-CommandText -Text $script -Dialect 'powershell' -Depth ($Depth + 1))) {
                    foreach ($e in (Expand-CommandRecord -Record $r -Depth ($Depth + 1))) { [void]$out.Add($e) }
                }
                return ,($out.ToArray())
            }
            if ($a -match $valueOptions) { $k++; continue }
            if ($a.StartsWith('-') -or $a.StartsWith('/')) { continue }
            # First positional argument: PowerShell treats the rest as a command.
            $script = (@($argList[$k..($argList.Count - 1)]) -join ' ')
            foreach ($r in (Split-CommandText -Text $script -Dialect 'powershell' -Depth ($Depth + 1))) {
                foreach ($e in (Expand-CommandRecord -Record $r -Depth ($Depth + 1))) { [void]$out.Add($e) }
            }
            return ,($out.ToArray())
        }
    }
    # cmd /c "..."
    if ($name -eq 'cmd') {
        for ($k = 0; $k -lt $argList.Count; $k++) {
            $a = [string]$argList[$k]
            if ($a -match '^(?i)/[ck]$') {
                $script = (@($argList[($k + 1)..($argList.Count - 1)]) -join ' ')
                if (($k + 1) -ge $argList.Count) { $script = '' }
                foreach ($r in (Split-CommandText -Text $script -Dialect 'cmd' -Depth ($Depth + 1))) {
                    foreach ($e in (Expand-CommandRecord -Record $r -Depth ($Depth + 1))) { [void]$out.Add($e) }
                }
                return ,($out.ToArray())
            }
        }
    }
    # Invoke-Expression "..."
    if ($name -eq 'invoke-expression') {
        $parts = @($argList | Where-Object { $_ -notmatch '^(?i)-command$' })
        foreach ($r in (Split-CommandText -Text ($parts -join ' ') -Dialect 'powershell' -Depth ($Depth + 1))) {
            foreach ($e in (Expand-CommandRecord -Record $r -Depth ($Depth + 1))) { [void]$out.Add($e) }
        }
        return ,($out.ToArray())
    }
    # Start-Process git -ArgumentList "push --force"
    if ($name -eq 'start-process' -and $dialect -eq 'powershell') {
        $file = $null; $argText = ''; $pos = @()
        for ($k = 0; $k -lt $argList.Count; $k++) {
            $a = [string]$argList[$k]
            if ($a -match '^(?i)-(filepath|fp|path)$' -and ($k + 1) -lt $argList.Count) { $file = [string]$argList[$k + 1]; $k++; continue }
            if ($a -match '^(?i)-(argumentlist|args)$' -and ($k + 1) -lt $argList.Count) { $argText = [string]$argList[$k + 1]; $k++; continue }
            if ($a.StartsWith('-')) { if ($a -match '^(?i)-(workingdirectory|wd|redirectstandard\w+|windowstyle|verb|credential)$') { $k++ }; continue }
            $pos += $a
        }
        if (-not $file -and $pos.Count -gt 0) { $file = $pos[0]; if ($pos.Count -gt 1 -and -not $argText) { $argText = ($pos[1..($pos.Count - 1)] -join ' ') } }
        if ($file) {
            $synthetic = [ordered]@{ words = @(@($file) + @((Split-CommandText -Text $argText -Dialect 'bash' -Depth ($Depth + 1)) | ForEach-Object { $_.words })); inputs = @(); dialect = 'bash'; dynamic = $Record.dynamic }
            foreach ($e in (Expand-CommandRecord -Record $synthetic -Depth ($Depth + 1))) { [void]$out.Add($e) }
            return ,($out.ToArray())
        }
    }
    [void]$out.Add([ordered]@{ name = $name; args = $argList; dialect = $dialect; dynamic = [bool]$Record.dynamic; encoded = $false; inputs = @($Record.inputs) })
    return ,($out.ToArray())
}

function Get-AnalyzedCommands {
    param([AllowEmptyString()][string]$Text, [string]$Dialect = 'bash')
    $list = New-Object System.Collections.ArrayList
    foreach ($r in (Split-CommandText -Text $Text -Dialect $Dialect)) {
        foreach ($e in (Expand-CommandRecord -Record $r)) { [void]$list.Add($e) }
    }
    return ,($list.ToArray())
}

# ================================================================== directories named by commands

function Resolve-CommandPath {
    param([string]$Base, [string]$PathText)
    if ([string]::IsNullOrWhiteSpace($PathText)) { return $null }
    $p = $PathText.Trim()
    if ($p -match '\$|%|\*|\?') { return $null }
    if ($p -match '^/([a-zA-Z])/(.*)$') { $p = $Matches[1] + ':/' + $Matches[2] }        # Git Bash /c/path
    elseif ($p -match '^/([a-zA-Z])$') { $p = $Matches[1] + ':/' }
    if ($p.StartsWith('~')) { $p = (Join-Path $HOME $p.Substring(1).TrimStart('/', '\')) }
    try {
        if ([System.IO.Path]::IsPathRooted($p) -and $p -notmatch '^[\\/][^\\/]') { return [System.IO.Path]::GetFullPath($p) }
        if (-not $Base) { return $null }
        return [System.IO.Path]::GetFullPath((Join-Path $Base $p))
    } catch { return $null }
}

function Get-FirstPositional {
    param([object[]]$ArgList, [string[]]$ValueOptions = @())
    for ($k = 0; $k -lt $ArgList.Count; $k++) {
        $a = [string]$ArgList[$k]
        if ($a -eq '--') { if (($k + 1) -lt $ArgList.Count) { return [string]$ArgList[$k + 1] }; return $null }
        if ($a.StartsWith('-')) { if ($ValueOptions -contains $a.ToLowerInvariant()) { $k++ }; continue }
        return $a
    }
    return $null
}

function Get-OptionValue {
    # Value of -Name value, -Name=value, --name value, --name=value, /Name:value.
    param([object[]]$ArgList, [string[]]$Names)
    for ($k = 0; $k -lt $ArgList.Count; $k++) {
        $a = [string]$ArgList[$k]
        foreach ($nm in $Names) {
            if ($a -ieq $nm -and ($k + 1) -lt $ArgList.Count) { return [string]$ArgList[$k + 1] }
            if ($a.StartsWith($nm + '=', [System.StringComparison]::OrdinalIgnoreCase)) { return $a.Substring($nm.Length + 1) }
            if ($a.StartsWith($nm + ':', [System.StringComparison]::OrdinalIgnoreCase) -and $nm.StartsWith('/')) { return $a.Substring($nm.Length + 1) }
        }
    }
    return $null
}

function Get-CommandDirectories {
    # Directories a command sequence works in: cd/Set-Location/pushd targets, git -C, dotnet --project.
    param([object[]]$Records, [string]$Cwd)
    $dirs = New-Object System.Collections.ArrayList
    $cur = $Cwd
    foreach ($r in $Records) {
        if ($r.name -in @('set-location', 'push-location')) {
            $t = Get-OptionValue -ArgList $r.args -Names @('-Path', '-LiteralPath')
            if (-not $t) { $t = Get-FirstPositional -ArgList $r.args }
            $d = Resolve-CommandPath -Base $cur -PathText $t
            if ($d) { $cur = $d; [void]$dirs.Add($d) }
        } elseif ($r.name -eq 'git') {
            $g = Get-GitInvocation -ArgList $r.args
            if ($g.dir) { $d = Resolve-CommandPath -Base $cur -PathText $g.dir; if ($d) { [void]$dirs.Add($d) } }
        } elseif ($r.name -eq 'dotnet') {
            foreach ($v in @((Get-OptionValue -ArgList $r.args -Names @('--project', '-p')), (Get-OptionValue -ArgList $r.args -Names @('--startup-project', '-s')))) {
                if ($v) { $d = Resolve-CommandPath -Base $cur -PathText $v; if ($d) { if ([System.IO.File]::Exists($d)) { $d = [System.IO.Path]::GetDirectoryName($d) }; [void]$dirs.Add($d) } }
            }
        }
        $r['cwd'] = $cur
    }
    return ,($dirs.ToArray())
}

# ================================================================== git analysis

$script:GitKnown = @('add', 'am', 'annotate', 'apply', 'archive', 'bisect', 'blame', 'branch', 'bundle', 'cat-file', 'check-ignore', 'check-ref-format', 'checkout', 'cherry', 'cherry-pick', 'citool', 'clean', 'clone', 'commit', 'commit-tree', 'config', 'count-objects', 'credential', 'describe', 'diff', 'difftool', 'fetch', 'filter-branch', 'filter-repo', 'for-each-ref', 'format-patch', 'fsck', 'gc', 'grep', 'gui', 'hash-object', 'help', 'init', 'lfs', 'log', 'ls-files', 'ls-remote', 'ls-tree', 'maintenance', 'merge', 'merge-base', 'mergetool', 'mktag', 'mktree', 'mv', 'name-rev', 'notes', 'prune', 'pull', 'push', 'range-diff', 'read-tree', 'rebase', 'reflog', 'remote', 'repack', 'replace', 'request-pull', 'reset', 'restore', 'rev-list', 'rev-parse', 'revert', 'rm', 'send-email', 'shortlog', 'show', 'show-branch', 'show-ref', 'sparse-checkout', 'stash', 'status', 'submodule', 'subtree', 'switch', 'symbolic-ref', 'tag', 'update-index', 'update-ref', 'var', 'verify-commit', 'verify-tag', 'version', 'whatchanged', 'worktree', 'write-tree')

function Get-GitInvocation {
    param([object[]]$ArgList)
    $res = [ordered]@{ dir = $null; sub = $null; args = @(); configs = @() }
    $k = 0
    while ($k -lt $ArgList.Count) {
        $a = [string]$ArgList[$k]
        if ($a -eq '-C' -and ($k + 1) -lt $ArgList.Count) { $res.dir = [string]$ArgList[$k + 1]; $k += 2; continue }
        if ($a -eq '-c' -and ($k + 1) -lt $ArgList.Count) { $res.configs += [string]$ArgList[$k + 1]; $k += 2; continue }
        if ($a -match '^--(git-dir|work-tree|namespace|exec-path|config-env|super-prefix|list-cmds)=') { $k++; continue }
        if ($a -in @('--git-dir', '--work-tree', '--namespace', '--config-env')) { $k += 2; continue }
        if ($a.StartsWith('-')) { $k++; continue }
        $res.sub = $a.ToLowerInvariant()
        if (($k + 1) -lt $ArgList.Count) { $res.args = @($ArgList[($k + 1)..($ArgList.Count - 1)]) }
        break
    }
    return $res
}

function Test-ShortFlag {
    # True when -x or a short cluster such as -fu contains the letter.
    param([string]$Arg, [string]$Letters)
    if ($Arg -notmatch '^-[A-Za-z0-9]+$') { return $false }
    foreach ($ch in $Letters.ToCharArray()) { if ($Arg.Substring(1).IndexOf($ch) -ge 0) { return $true } }
    return $false
}

function Test-GitLocalChanges {
    param([string]$Dir)
    $r = Invoke-GitCommand -Root $Dir -Arguments @('status', '--porcelain', '--untracked-files=no')
    if ($r.exitCode -ne 0) { return $true }   # cannot tell: treat as changes (fail-closed)
    return (@($r.stdout).Count -gt 0)
}

function Test-GitHeadPushed {
    param([string]$Dir)
    $r = Invoke-GitCommand -Root $Dir -Arguments @('branch', '-r', '--contains', 'HEAD')
    if ($r.exitCode -ne 0) { return $true }
    return (@($r.stdout).Count -gt 0)
}

function Resolve-GitAlias {
    param([string]$Dir, [string]$Name)
    if (-not $Dir) { return $null }
    $r = Invoke-GitCommand -Root $Dir -Arguments @('config', '--get', "alias.$Name")
    if ($r.exitCode -ne 0 -or @($r.stdout).Count -eq 0) { return $null }
    return ($r.stdout -join ' ')
}

function Test-GitCommand {
    param($Record, $Context, [int]$Depth = 0)
    $g = Get-GitInvocation -ArgList $Record.args
    if (-not $g.sub) { return $null }
    $dir = $Record['cwd']
    if ($g.dir) { $d = Resolve-CommandPath -Base $dir -PathText $g.dir; if ($d) { $dir = $d } }
    if (-not $dir) { $dir = $Context.projectRoot }
    $sub = $g.sub
    $a = @($g.args | ForEach-Object { [string]$_ })

    if ($script:GitKnown -notcontains $sub -and $Depth -lt 3) {
        $alias = Resolve-GitAlias -Dir $dir -Name $sub
        if ($alias) {
            if ($alias.StartsWith('!')) { $text = $alias.Substring(1) + ' ' + ($a -join ' ') }
            else { $text = 'git ' + $alias + ' ' + ($a -join ' ') }
            foreach ($rec in (Get-AnalyzedCommands -Text $text -Dialect 'bash')) {
                $rec['cwd'] = $dir
                $d2 = Test-OneCommand -Record $rec -Context $Context -Depth ($Depth + 1)
                if ($d2) { return $d2 }
            }
            return $null
        }
    }
    switch ($sub) {
        'push' {
            foreach ($x in $a) {
                if ($x -in @('--force', '--mirror', '--force-if-includes') -or $x.StartsWith('--force-with-lease') -or (Test-ShortFlag $x 'f')) {
                    return (New-GuardDecision 'git.force-push' "git push $x")
                }
            }
            if ($a -contains '--delete' -or @($a | Where-Object { Test-ShortFlag $_ 'd' }).Count -gt 0) { return (New-GuardDecision 'git.delete-branch' 'git push --delete') }
            $positional = @($a | Where-Object { -not $_.StartsWith('-') })
            foreach ($p in ($positional | Select-Object -Skip 1)) {
                if ($p.StartsWith('+')) { return (New-GuardDecision 'git.force-push' "refspec $p") }
                if ($p.StartsWith(':')) { return (New-GuardDecision 'git.delete-branch' "refspec $p") }
            }
            return (New-GuardDecision 'approval.git-push')
        }
        { $_ -in @('rebase', 'filter-branch', 'filter-repo') } { return (New-GuardDecision 'git.rewrite-history' "git $sub") }
        'replace' {
            if (@($a | Where-Object { $_ -in @('-l', '--list') -or $_ -like '--format*' }).Count -gt 0 -and @($a | Where-Object { $_ -in @('-d', '--delete', '-f', '--force', '--edit', '--graft', '--convert-graft-file') }).Count -eq 0) { return $null }
            return (New-GuardDecision 'git.rewrite-history' 'git replace')
        }
        'update-ref' {
            if ($a -contains '-d' -or $a -contains '--delete' -or $a -contains '--stdin') { return (New-GuardDecision 'git.rewrite-history' 'git update-ref -d') }
        }
        'commit' {
            if (@($a | Where-Object { $_ -eq '--amend' -or $_.StartsWith('--amend') }).Count -gt 0) {
                if (Test-GitHeadPushed -Dir $dir) { return (New-GuardDecision 'git.rewrite-history' 'amending a commit that exists on a remote') }
            }
        }
        'pull' {
            foreach ($x in $a) { if (($x -eq '--rebase' -or $x -eq '-r' -or ($x.StartsWith('--rebase=') -and $x -ne '--rebase=false'))) { return (New-GuardDecision 'git.rewrite-history' "git pull $x") } }
            if (-not ($a -contains '--no-rebase' -or $a -contains '--ff-only')) {
                $cfg = Invoke-GitCommand -Root $dir -Arguments @('config', '--get', 'pull.rebase')
                if ($cfg.exitCode -eq 0 -and @($cfg.stdout).Count -gt 0 -and $cfg.stdout[0] -notin @('false', '0', 'no', 'off')) { return (New-GuardDecision 'git.rewrite-history' 'git pull with pull.rebase set') }
            }
        }
        'branch' {
            foreach ($x in $a) { if ($x -eq '--delete' -or (Test-ShortFlag $x 'dD')) { return (New-GuardDecision 'git.delete-branch' "git branch $x") } }
        }
        'reset' {
            if ($a -contains '--hard') { return (New-GuardDecision 'git.discard-changes' 'git reset --hard') }
            if ($a -contains '--keep' -and (Test-GitLocalChanges -Dir $dir)) { return (New-GuardDecision 'git.discard-changes' 'git reset --keep with local changes') }
        }
        'checkout' {
            if ($a -contains '-f' -or $a -contains '--force' -or @($a | Where-Object { Test-ShortFlag $_ 'f' }).Count -gt 0) { return (New-GuardDecision 'git.discard-changes' 'git checkout --force') }
            $dd = [array]::IndexOf($a, '--')
            $paths = @()
            if ($dd -ge 0) { if ($dd + 1 -lt $a.Count) { $paths = @($a[($dd + 1)..($a.Count - 1)]) } }
            else {
                foreach ($x in @($a | Where-Object { -not $_.StartsWith('-') })) {
                    if ($x -eq '.') { $paths += $x; continue }
                    $isRef = Invoke-GitCommand -Root $dir -Arguments @('rev-parse', '--verify', '--quiet', "$x^{commit}")
                    if ($isRef.exitCode -ne 0 -and (Test-Path -LiteralPath (Join-Path $dir $x))) { $paths += $x }
                }
            }
            if ($paths.Count -gt 0 -and (Test-GitLocalChanges -Dir $dir)) { return (New-GuardDecision 'git.discard-changes' 'git checkout of paths with local changes') }
        }
        'restore' {
            $staged = @($a | Where-Object { $_ -in @('--staged', '-S') -or (Test-ShortFlag $_ 'S') }).Count -gt 0
            $worktree = @($a | Where-Object { $_ -in @('--worktree', '-W') -or (Test-ShortFlag $_ 'W') }).Count -gt 0
            if (-not $staged -or $worktree) { return (New-GuardDecision 'git.discard-changes' 'git restore of the working tree') }
        }
        'clean' {
            $dry = @($a | Where-Object { $_ -in @('-n', '--dry-run') -or (Test-ShortFlag $_ 'n') }).Count -gt 0
            $force = @($a | Where-Object { $_ -eq '--force' -or (Test-ShortFlag $_ 'f') }).Count -gt 0
            if ($force -and -not $dry) { return (New-GuardDecision 'git.discard-changes' 'git clean -f') }
        }
        'stash' {
            $op = @($a | Where-Object { -not $_.StartsWith('-') } | Select-Object -First 1)
            if ($op.Count -gt 0 -and $op[0] -in @('drop', 'clear')) { return (New-GuardDecision 'git.discard-changes' "git stash $($op[0])") }
        }
        'switch' {
            if ($a -contains '-f' -or $a -contains '--force' -or $a -contains '--discard-changes') { return (New-GuardDecision 'git.discard-changes' 'git switch --force') }
        }
        'rm' {
            if (@($a | Where-Object { $_ -in @('-n', '--dry-run') -or (Test-ShortFlag $_ 'n') }).Count -gt 0) { return $null }
            $dd = [array]::IndexOf($a, '--')
            $paths = $(if ($dd -ge 0) { @($a | Select-Object -Skip ($dd + 1)) } else { @($a | Where-Object { -not $_.StartsWith('-') }) })
            return (Test-ProjectDelete -PathArgs $paths -Cwd $dir -Context $Context)
        }
    }
    return $null
}

# ================================================================== other rule families

function Test-SecretFileName {
    param([string]$PathText)
    if ([string]::IsNullOrWhiteSpace($PathText)) { return $false }
    $name = ($PathText.Trim('"', "'") -split '[\\/]')[-1]
    if (-not $name) { return $false }
    foreach ($ex in (Get-GuardList 'secretFileExceptions')) { if ($name -ieq $ex) { return $false } }
    foreach ($glob in (Get-GuardList 'secretFileGlobs')) { if ($name -match (ConvertTo-GlobRegex $glob)) { return $true } }
    return $false
}

function Test-LocalTarget {
    # Returns $true, $false, or $null (unknown) for a server name or a connection string.
    param([string]$Server, [string]$ConnectionString)
    if ($ConnectionString) { return (Get-DataSourceInfo -ConnectionString $ConnectionString).isLocal }
    if (-not $Server) { return $true }   # client default is the local default instance
    $info = Get-DataSourceInfo -ConnectionString ("Server=" + $Server)
    return $info.isLocal
}

function Get-ProjectDirForDotnet {
    param($Record, $Context)
    $cwd = $Record['cwd']; if (-not $cwd) { $cwd = $Context.projectRoot }
    $p = Get-OptionValue -ArgList $Record.args -Names @('--project', '-p')
    if ($p) {
        $d = Resolve-CommandPath -Base $cwd -PathText $p
        if ($d -and [System.IO.File]::Exists($d)) { return [System.IO.Path]::GetDirectoryName($d) }
        return $d
    }
    return $cwd
}

function Test-ApprovalRecorded {
    param($Context, [string]$Action)
    foreach ($ap in @($Context.state['approvals'])) {
        if ($ap['action'] -eq $Action -and $ap['decision'] -eq 'approved' -and -not $ap['consumed']) { return $true }
    }
    return $false
}

# ================================================================== deleting project files

function Get-DeletePathArgs {
    # Path arguments of rm, Remove-Item, and their aliases; options and their values are skipped.
    param([object[]]$ArgList)
    $pathOptions = @('-path', '-literalpath', '-lp', '-pspath')
    $valueOptions = @('-filter', '-include', '-exclude', '-erroraction', '-ea', '-stream', '-credential', '-warningaction', '-wa', '-informationaction', '-infa', '-errorvariable', '-ev', '-outvariable', '-ov')
    $paths = @()
    $endOfOptions = $false
    for ($k = 0; $k -lt $ArgList.Count; $k++) {
        $a = [string]$ArgList[$k]
        if (-not $endOfOptions -and $a -eq '--') { $endOfOptions = $true; continue }
        if (-not $endOfOptions -and $a.Length -gt 1 -and $a.StartsWith('-')) {
            $low = $a.ToLowerInvariant().TrimEnd(':')
            if ($pathOptions -contains $low -and ($k + 1) -lt $ArgList.Count) { $paths += [string]$ArgList[$k + 1]; $k++ }
            elseif ($valueOptions -contains $low) { $k++ }
            continue
        }
        $paths += $a
    }
    return @($paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
}

function Test-RemovalApproved {
    # True when a recorded, unused remove-custom-feature approval names the path or a folder that contains it.
    param($Context, [string]$Path)
    foreach ($ap in @($Context.state['approvals'])) {
        if ($ap['action'] -ne 'remove-custom-feature' -or $ap['decision'] -ne 'approved' -or $ap['consumed']) { continue }
        foreach ($s in (([string]$ap['scope']) -split ';')) {
            $s2 = $s.Trim().Trim('/').Replace('\', '/')
            if ($s2 -and ($Path -ieq $s2 -or $Path.StartsWith($s2 + '/', [System.StringComparison]::OrdinalIgnoreCase))) { return $true }
        }
    }
    return $false
}

function Test-ProjectDelete {
    # Deleting tracked project files: denied where project files may not change, and otherwise asked for unless a
    # remove-custom-feature approval names every file. Build output and the state folder are not checked.
    param([string[]]$PathArgs, [string]$Cwd, $Context)
    $root = $Context.projectRoot
    $base = $(if ($Cwd) { $Cwd } else { $root })
    $prefixRun = Invoke-GitCommand -Root $root -Arguments @('rev-parse', '--show-prefix')
    if ($prefixRun.exitCode -ne 0) { return $null }
    $prefix = $(if (@($prefixRun.stdout).Count -gt 0) { [string]$prefixRun.stdout[0] } else { '' })
    $uncovered = @()
    foreach ($p in $PathArgs) {
        if ($p -match '\$|`|%') { $uncovered += "a computed path ($p)"; continue }
        $target = $p.Replace('\', '/')
        if ($target -match '^/([a-zA-Z])/(.*)$') { $target = $Matches[1] + ':/' + $Matches[2] }
        # git expands the path and any wildcard into the tracked files it names (paths from the repository top).
        $r = Invoke-GitCommand -Root $base -Arguments @('ls-files', '--full-name', '--', $target)
        if ($r.exitCode -ne 0) { continue }
        foreach ($f in @($r.stdout | Where-Object { $_ })) {
            $rel = [string]$f
            if ($prefix) { if (-not $rel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }; $rel = $rel.Substring($prefix.Length) }
            if ($rel -match '(?i)^\.umbraco-upgrade/' -or $rel -match '(?i)(^|/)(bin|obj)/') { continue }
            if (-not (Test-RemovalApproved -Context $Context -Path $rel)) { $uncovered += $rel }
        }
    }
    if ($uncovered.Count -eq 0) { return $null }
    $state = $Context.state
    if ($state['mode'] -eq 'plan') { return (New-GuardDecision 'project.plan-mode-write') }
    if ($state['gates']['safety']['status'] -ne 'passed' -or $state['gates']['planApproval']['status'] -ne 'approved') { return (New-GuardDecision 'project.write-before-approval') }
    $branch = Get-CurrentBranchFast -Root $root
    if ($state['gitBaseline']['upgradeBranch'] -and $branch -ne $state['gitBaseline']['upgradeBranch']) { return (New-GuardDecision 'project.write-off-branch' "current branch: $branch") }
    $list = @($uncovered | Select-Object -First 5) -join ', '
    if ($uncovered.Count -gt 5) { $list += " and $($uncovered.Count - 5) more" }
    return (New-GuardDecision 'approval.project-file-delete' $list)
}

function Test-OneCommand {
    param($Record, $Context, [int]$Depth = 0)
    $name = [string]$Record.name
    $a = @($Record.args | ForEach-Object { [string]$_ })
    $lower = @($a | ForEach-Object { $_.ToLowerInvariant() })

    if ($Record.encoded) { return (New-GuardDecision 'shell.encoded-command' $name) }

    # Connection strings passed on any command line.
    foreach ($x in $a) {
        if ($x -match '(?i)\b(server|data source|address|addr)\s*=\s*[^;''"\s]+\s*;') {
            if ((Test-LocalTarget -ConnectionString $x) -ne $true) { return (New-GuardDecision 'db.non-local' "$name with a connection string") }
        }
    }

    if ($name -eq 'git') { return (Test-GitCommand -Record $Record -Context $Context -Depth $Depth) }

    # Secrets: environment dumps.
    if ($name -in @('env', 'printenv') -and @($a | Where-Object { -not $_.StartsWith('-') }).Count -eq 0) { return (New-GuardDecision 'secrets.print' $name) }
    if ($name -eq 'set' -and $a.Count -eq 0 -and $Record.dialect -ne 'powershell') { return (New-GuardDecision 'secrets.print' 'set') }
    if ($name -eq 'export' -and ($a.Count -eq 0 -or $a -contains '-p')) { return (New-GuardDecision 'secrets.print' 'export -p') }
    if ($name -eq 'declare' -and @($a | Where-Object { -not $_.StartsWith('-') }).Count -eq 0 -and ($a -contains '-x' -or $a -contains '-p')) { return (New-GuardDecision 'secrets.print' 'declare') }
    if ($name -in @('get-childitem', 'get-item')) {
        foreach ($x in $a) { if ($x -match '^(?i)env:') { return (New-GuardDecision 'secrets.print' "$name env:") } }
    }
    # Secrets: dumping secret-bearing files.
    if ((Get-GuardList 'fileDumpCommands') -contains $name) {
        foreach ($x in @($a + @($Record.inputs))) {
            if ($x.StartsWith('-') -and $x -notmatch '^--include=') { continue }
            $v = $x -replace '^--include=', ''
            if (Test-SecretFileName $v) { return (New-GuardDecision 'secrets.print' "$name $v") }
        }
    }
    if ($name -eq 'dotnet' -and $lower.Count -ge 2 -and $lower[0] -eq 'user-secrets' -and $lower -contains 'list') { return (New-GuardDecision 'secrets.print' 'dotnet user-secrets list') }
    if ($name -eq 'az') {
        $joined = ($lower | Where-Object { -not $_.StartsWith('-') }) -join ' '
        foreach ($p in (Get-GuardList 'azSecretPrefixes')) { if ($joined.StartsWith($p)) { return (New-GuardDecision 'secrets.print' "az $p") } }
        foreach ($p in (Get-GuardList 'azDeployPrefixes')) { if ($joined.StartsWith($p)) { return (New-GuardDecision 'deploy.any' "az $p") } }
    }
    if ((Get-GuardList 'psSecretCommands') -contains $name) { return (New-GuardDecision 'secrets.print' $name) }
    $joinedAll = ($name + ':' + (($lower | Where-Object { -not $_.StartsWith('-') }) -join ' '))
    foreach ($p in (Get-GuardList 'otherSecretCommands')) { if ($joinedAll.StartsWith($p)) { return (New-GuardDecision 'secrets.print' ($p -replace ':', ' ')) } }

    # Deployments.
    foreach ($p in (Get-GuardList 'deployCommands')) {
        if ($p.Contains(':')) {
            $parts = $p -split ':', 2
            $first = @($lower | Where-Object { -not $_.StartsWith('-') } | Select-Object -First 1)
            if ($name -eq $parts[0] -and $first.Count -gt 0 -and $first[0] -eq $parts[1]) { return (New-GuardDecision 'deploy.any' "$name $($parts[1])") }
        } elseif ($name -eq $p) { return (New-GuardDecision 'deploy.any' $name) }
    }
    if ($name -eq 'func' -and ($lower -join ' ') -match '^azure functionapp publish') { return (New-GuardDecision 'deploy.any' 'func azure functionapp publish') }
    if ($name -eq 'docker' -and ($lower -join ' ') -match '^(compose\s+)?push\b') { return (New-GuardDecision 'deploy.any' 'docker push') }
    if ($name -eq 'rsync' -and @($a | Where-Object { $_ -match '^[^/\\\s]+:' -and $_ -notmatch '^[A-Za-z]:' }).Count -gt 0) { return (New-GuardDecision 'deploy.any' 'rsync to a remote host') }
    if ($name -eq 'curl' -and ($lower -contains '-t' -or $lower -contains '--upload-file' -or @($lower | Where-Object { $_ -like 'ftp://*' -or $_ -like 'ftps://*' -or $_ -like 'sftp://*' }).Count -gt 0)) { return (New-GuardDecision 'deploy.any' 'curl upload') }
    if ($name -in @('dotnet', 'msbuild')) {
        $isPublish = ($name -eq 'msbuild') -or ($lower.Count -gt 0 -and $lower[0] -eq 'publish')
        if ($isPublish -or ($name -eq 'dotnet' -and $lower.Count -gt 0 -and $lower[0] -in @('build', 'msbuild'))) {
            $props = @{}
            foreach ($x in $a) {
                if ($x -match '^(?i)[-/]p(roperty)?:(.+)$') {
                    foreach ($pair in ($Matches[2] -split ';')) { $kv = $pair -split '=', 2; if ($kv.Count -eq 2) { $props[$kv[0].Trim().ToLowerInvariant()] = $kv[1].Trim() } }
                }
            }
            if ($props.ContainsKey('webpublishmethod') -and $props['webpublishmethod'] -ine 'FileSystem') { return (New-GuardDecision 'deploy.any' ('WebPublishMethod=' + $props['webpublishmethod'])) }
            if ($props.ContainsKey('deployonbuild') -and $props['deployonbuild'] -ieq 'true' -and -not $props.ContainsKey('publishprofile')) { return (New-GuardDecision 'deploy.any' 'DeployOnBuild without a file system profile') }
            if ($props.ContainsKey('publishurl') -and $props['publishurl'] -match '^(?i)(ftp|ftps|https?)://|^\\\\') { return (New-GuardDecision 'deploy.any' 'remote PublishUrl') }
            if ($props.ContainsKey('publishprofile')) {
                $projDir = Get-ProjectDirForDotnet -Record $Record -Context $Context
                $profName = $props['publishprofile']
                $found = $null
                if ($projDir) {
                    foreach ($cand in @((Join-Path $projDir "Properties/PublishProfiles/$profName.pubxml"), (Join-Path $projDir "Properties/PublishProfiles/$profName"), (Join-Path $projDir $profName))) {
                        if ([System.IO.File]::Exists($cand)) { $found = $cand; break }
                    }
                }
                if (-not $found) { return (New-GuardDecision 'deploy.any' "publish profile '$profName' could not be inspected") }
                $method = $null
                if ((Read-TextFile $found) -match '<WebPublishMethod>\s*([^<\s]+)\s*</WebPublishMethod>') { $method = $Matches[1] }
                if ($method -ine 'FileSystem') { return (New-GuardDecision 'deploy.any' "publish profile '$profName' uses $method") }
            }
        }
    }

    # Databases.
    if ((Get-GuardList 'sqlCommands') -contains $name) {
        $server = $null; $cs = $null
        if ($name -eq 'invoke-sqlcmd') {
            $server = Get-OptionValue -ArgList $a -Names @('-ServerInstance', '-HostName')
            $cs = Get-OptionValue -ArgList $a -Names @('-ConnectionString')
        } elseif ($name -eq 'sqlpackage') {
            foreach ($nm in @('/TargetServerName', '/tsn', '/SourceServerName', '/ssn')) { $v = Get-OptionValue -ArgList $a -Names @($nm); if ($v) { $server = $v } }
            foreach ($nm in @('/TargetConnectionString', '/tcs', '/SourceConnectionString', '/scs')) { $v = Get-OptionValue -ArgList $a -Names @($nm); if ($v) { $cs = $v } }
        } else {
            for ($k = 0; $k -lt $a.Count; $k++) {
                if ($a[$k] -ceq '-S' -and ($k + 1) -lt $a.Count) { $server = $a[$k + 1] }
                elseif ($a[$k] -cmatch '^-S(.+)$') { $server = $Matches[1] }
            }
        }
        $local = Test-LocalTarget -Server $server -ConnectionString $cs
        if ($local -ne $true) { return (New-GuardDecision 'db.non-local' $name) }
        return $null
    }
    if ($name -in @('dotnet', 'dotnet-ef')) {
        $l = $lower; if ($name -eq 'dotnet' -and $l.Count -gt 0 -and $l[0] -eq 'ef') { $l = @($l | Select-Object -Skip 1) }
        if (($name -eq 'dotnet-ef' -or ($lower.Count -gt 0 -and $lower[0] -eq 'ef')) -and $l.Count -gt 0 -and $l[0] -eq 'database') {
            $cs = Get-OptionValue -ArgList $a -Names @('--connection')
            if (-not $cs) {
                $projDir = Get-ProjectDirForDotnet -Record $Record -Context $Context
                $startup = Get-OptionValue -ArgList $a -Names @('--startup-project', '-s')
                if ($startup) { $projDir = Resolve-CommandPath -Base $Record['cwd'] -PathText $startup; if ($projDir -and [System.IO.File]::Exists($projDir)) { $projDir = [System.IO.Path]::GetDirectoryName($projDir) } }
                if ($projDir) { $cs = (Get-EffectiveConnectionString -ProjectDir $projDir).connectionString }
            }
            if ((Test-LocalTarget -ConnectionString $cs) -ne $true -or -not $cs) { return (New-GuardDecision 'db.non-local' 'dotnet ef database: target not verified as local') }
            if (-not (Test-ApprovalRecorded -Context $Context -Action 'db-migration-local')) { return (New-GuardDecision 'approval.db-migration') }
            return $null
        }
    }
    $isSiteStart = ($name -eq 'dotnet' -and $lower.Count -gt 0 -and $lower[0] -in @('run', 'watch')) -or ((Get-GuardList 'siteStartCommands') -contains $name)
    if ($isSiteStart) {
        $projDir = Get-ProjectDirForDotnet -Record $Record -Context $Context
        $envName = Get-OptionValue -ArgList $a -Names @('--environment')
        $profile = Get-OptionValue -ArgList $a -Names @('--launch-profile', '-lp')
        $eff = $null
        if ($projDir) { $eff = Get-EffectiveConnectionString -ProjectDir $projDir -Environment $envName -LaunchProfile $profile -NoLaunchProfile:($lower -contains '--no-launch-profile') }
        if ($eff -and $eff.connectionString) {
            $info = Get-DataSourceInfo -ConnectionString $eff.connectionString -ProviderName $eff.providerName
            if ($info.isLocal -eq $false) { return (New-GuardDecision 'db.non-local' "site start uses a non-local database ($($eff.source))") }
            if ($info.isLocal -eq $true -and (Test-ApprovalRecorded -Context $Context -Action 'db-migration-local')) { return $null }
        }
        return (New-GuardDecision 'approval.site-start')
    }

    # Package removal.
    if ($name -eq 'dotnet' -and $lower.Count -ge 2 -and (($lower[0] -eq 'remove' -and $lower -contains 'package') -or ($lower[0] -eq 'package' -and $lower[1] -eq 'remove'))) { return (New-GuardDecision 'approval.package-removal' 'dotnet remove package') }
    if ((Get-GuardList 'packageRemoval') -contains $name) { return (New-GuardDecision 'approval.package-removal' $name) }

    # Deleting tracked project files.
    if ((Get-GuardList 'deleteCommands') -contains $name) {
        $d = Test-ProjectDelete -PathArgs (Get-DeletePathArgs -ArgList $a) -Cwd $Record['cwd'] -Context $Context
        if ($d) { return $d }
    }

    return $null
}

function Get-StrongestDecision {
    param([object[]]$Decisions)
    $deny = @($Decisions | Where-Object { $_ -and $_.decision -eq 'deny' })
    if ($deny.Count -gt 0) { return $deny[0] }
    $ask = @($Decisions | Where-Object { $_ -and $_.decision -eq 'ask' })
    if ($ask.Count -gt 0) { return $ask[0] }
    return $null
}

function Test-ShellToolInput {
    # Context: projectRoot, state, cwd. Returns a decision or $null (allow).
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$ToolName, [Parameter(Mandatory)]$Context)
    $dialect = $(if ($ToolName -eq 'PowerShell') { 'powershell' } else { 'bash' })
    if ($Command -match '(?i)\[\s*(System\.)?Environment\s*\]::GetEnvironmentVariables') { return (New-GuardDecision 'secrets.print' 'GetEnvironmentVariables') }
    $records = Get-AnalyzedCommands -Text $Command -Dialect $dialect
    [void](Get-CommandDirectories -Records $records -Cwd $Context.cwd)
    $decisions = foreach ($r in $records) { Test-OneCommand -Record $r -Context $Context }
    return (Get-StrongestDecision @($decisions))
}

function Test-WriteToolInput {
    param([Parameter(Mandatory)]$HookInput, [Parameter(Mandatory)]$Context)
    $ti = $HookInput.tool_input
    $path = $null
    foreach ($nm in @('file_path', 'notebook_path', 'path')) { if ($ti.PSObject.Properties[$nm] -and $ti.$nm) { $path = [string]$ti.$nm; break } }
    if (-not $path) { return $null }
    $full = Resolve-CommandPath -Base $Context.cwd -PathText $path
    if (-not $full) { return $null }
    $root = $Context.projectRoot
    $stateDir = Join-Path $root '.umbraco-upgrade'
    $content = ''
    foreach ($nm in @('content', 'new_string', 'new_source')) { if ($ti.PSObject.Properties[$nm] -and $null -ne $ti.$nm) { $content += [string]$ti.$nm + "`n" } }
    if (Test-PathUnder -Root $stateDir -Path $full) {
        if ($full -ieq [System.IO.Path]::GetFullPath((Join-Path $stateDir 'state.json'))) {
            return (New-GuardDecision 'state.direct-write')
        }
        if ($content -and (Protect-Text $content) -ne $content) { return (New-GuardDecision 'state.secret-write') }
        return $null
    }
    if (Test-PathUnder -Root $root -Path $full) {
        $state = $Context.state
        if ($state['mode'] -eq 'plan') { return (New-GuardDecision 'project.plan-mode-write') }
        if ($state['gates']['safety']['status'] -ne 'passed' -or $state['gates']['planApproval']['status'] -ne 'approved') { return (New-GuardDecision 'project.write-before-approval') }
        $branch = Get-CurrentBranchFast -Root $root
        if ($state['gitBaseline']['upgradeBranch'] -and $branch -ne $state['gitBaseline']['upgradeBranch']) { return (New-GuardDecision 'project.write-off-branch' "current branch: $branch") }
        $rel = Get-RelativePathCompat -BasePath $root -Path $full
        if (Test-GlobMatch -RelativePath $rel -Globs (Get-GuardList 'ciDeployFileGlobs')) {
            if (-not (Test-ApprovalRecorded -Context $Context -Action 'ci-deploy-config-change')) { return (New-GuardDecision 'approval.ci-deploy-file' $rel) }
        }
        return $null
    }
    foreach ($allowed in @($HookInput.PSObject.Properties | Where-Object { $_.Name -eq 'scratchpad_dir' } | ForEach-Object { $_.Value }) + @($env:CLAUDE_PLUGIN_DATA)) {
        if ($allowed -and (Test-PathUnder -Root ([string]$allowed) -Path $full)) { return $null }
    }
    return (New-GuardDecision 'approval.outside-project' $full)
}

function Get-CurrentBranchFast {
    # Reads .git/HEAD directly (no process start). Falls back to git for worktrees.
    param([string]$Root)
    $dir = $Root
    while ($dir) {
        $gitPath = Join-Path $dir '.git'
        if ([System.IO.Directory]::Exists($gitPath)) {
            $head = Join-Path $gitPath 'HEAD'
            if ([System.IO.File]::Exists($head)) {
                $t = (Read-TextFile $head).Trim()
                if ($t -match '^ref:\s*refs/heads/(.+)$') { return $Matches[1] }
                return $null
            }
        }
        if ([System.IO.File]::Exists($gitPath)) {
            $r = Invoke-GitCommand -Root $Root -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
            if ($r.exitCode -eq 0 -and @($r.stdout).Count -gt 0) { return $r.stdout[0] }
            return $null
        }
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Test-McpToolInput {
    param([Parameter(Mandatory)]$Context)
    $db = $Context.state['source']['database']
    if ($db -and $db['localCopyDeclared']) { return (New-GuardDecision 'approval.mcp-database') }
    return (New-GuardDecision 'mcp.database')
}

function Write-CanaryEvidence {
    param([string]$ProjectRoot, [string]$Command, [string]$SessionId)
    $marker = [string](Get-GuardRules).canaryMarker
    if ($Command -notmatch ([regex]::Escape($marker) + '([0-9a-f]{6,64})')) { return $null }
    $nonce = $Matches[1]
    $path = Join-Path $ProjectRoot ".umbraco-upgrade/evidence/safety/guard-canary-$nonce.json"
    Write-TextFile -Path $path -Content (ConvertTo-JsonText -InputObject ([ordered]@{ nonce = $nonce; blockedAt = (Get-UtcTimestamp); sessionId = $SessionId; rule = 'guard.canary' }))
    return $nonce
}

Export-ModuleMember -Function Get-GuardRules, New-GuardDecision, Get-StrongestDecision, Split-CommandText, Expand-CommandRecord, Get-AnalyzedCommands, Get-CommandDirectories, Get-GitInvocation, Test-OneCommand, Test-ShellToolInput, Test-WriteToolInput, Test-McpToolInput, Write-CanaryEvidence, Test-SecretFileName, Resolve-CommandPath, Get-CurrentBranchFast
