# Redaction.psm1 - secret detection and redaction, shared by scripts and hooks.
# Values are replaced; key names are kept so evidence stays readable.

Set-StrictMode -Version 2.0

$script:Mask = '***REDACTED***'

# Key names whose values are treated as secrets wherever they appear.
$script:SensitiveKeyPattern = '(?i)(pass(word|wd|phrase)?|pwd|secret|token|api[_.\-]?key|apikey|access[_.\-]?key|private[_.\-]?key|client[_.\-]?secret|connection[_.\-]?string|conn[_.\-]?str|credential|auth[_.\-]?(key|code|header)|sas|signature|validationkey|decryptionkey|machinekey|encryption[_.\-]?key|license[_.\-]?key|subscription[_.\-]?key|webhook[_.\-]?(url|secret))'

# Connection-string parts that carry credentials.
$script:CsSecretParts = @('password', 'pwd', 'user id', 'uid', 'user', 'username', 'accountkey', 'sharedaccesskey', 'sharedaccesssignature', 'access token', 'client secret')

function Test-SensitiveKey {
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    return [bool]($Name -match $script:SensitiveKeyPattern)
}

function Get-ShannonEntropy {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 0.0 }
    $counts = @{}
    foreach ($ch in $Value.ToCharArray()) {
        if ($counts.ContainsKey($ch)) { $counts[$ch]++ } else { $counts[$ch] = 1 }
    }
    $len = [double]$Value.Length
    $h = 0.0
    foreach ($c in $counts.Values) { $p = $c / $len; $h -= $p * [Math]::Log($p, 2) }
    return $h
}

function Test-HighEntropySecret {
    # Long token-like strings with mixed classes and high entropy. GUIDs and hex hashes stay below the bar.
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -lt 24) { return $false }
    if ($Value -notmatch '^[A-Za-z0-9+/=_\-\.~]+$') { return $false }
    if ($Value -notmatch '[A-Za-z]' -or $Value -notmatch '[0-9]') { return $false }
    if ($Value -match '^[0-9a-fA-F\-]+$') { return $false }
    # File paths with an extension are not tokens.
    if ($Value -match '[\\/]' -and $Value -match '\.[A-Za-z][A-Za-z0-9]{0,7}$') { return $false }
    if ($Value -match '^[A-Za-z]+([._\-][A-Za-z]+)*$') { return $false }
    return ((Get-ShannonEntropy $Value) -ge 4.2)
}

function Test-ConnectionStringLike {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return [bool]($Value -match '(?i)(^|;)\s*(server|data source|address|addr|network address|host|endpoint|accountname|initial catalog|database)\s*=')
}

function Protect-ConnectionString {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $parts = $Value -split ';'
    $out = foreach ($part in $parts) {
        $idx = $part.IndexOf('=')
        if ($idx -lt 1) { $part; continue }
        $k = $part.Substring(0, $idx).Trim()
        if ($script:CsSecretParts -contains $k.ToLowerInvariant()) { $part.Substring(0, $idx + 1) + $script:Mask }
        else { $part }
    }
    return ($out -join ';')
}

function Protect-Value {
    # Redacts one value given its key name.
    param([AllowEmptyString()][string]$Key, [AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value -eq $script:Mask) { return $Value }
    if (Test-ConnectionStringLike $Value) { return (Protect-ConnectionString $Value) }
    if ((Test-SensitiveKey $Key) -and $Value -notmatch '^(?i)(true|false|null|-?\d+)$') { return $script:Mask }
    if (Test-HighEntropySecret $Value) { return $script:Mask }
    return $Value
}

$script:TextRules = @(
    # Private key blocks (multi-line).
    @{ Pattern = '(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----'; Kind = 'whole' },
    # Well-known token formats.
    @{ Pattern = '\bAKIA[0-9A-Z]{16}\b'; Kind = 'whole' },
    @{ Pattern = '\bgh[pousr]_[A-Za-z0-9]{30,}\b'; Kind = 'whole' },
    @{ Pattern = '\bgithub_pat_[A-Za-z0-9_]{40,}\b'; Kind = 'whole' },
    @{ Pattern = '\bxox[abprs]-[A-Za-z0-9\-]{10,}'; Kind = 'whole' },
    @{ Pattern = '\bAIza[0-9A-Za-z\-_]{35}\b'; Kind = 'whole' },
    @{ Pattern = '\b(sk|rk)_live_[0-9A-Za-z]{16,}\b'; Kind = 'whole' },
    @{ Pattern = '\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}'; Kind = 'whole' },
    # Bearer and basic authorization values.
    @{ Pattern = '(?i)(\b(?:bearer|basic)\s+)([A-Za-z0-9\-\._~\+/]{12,}=*)'; Kind = 'group2' },
    # Credential parts inside connection strings: Password=...; User ID=...; AccountKey=...
    @{ Pattern = '(?i)(\b(?:password|pwd|user id|uid|accountkey|sharedaccesskey|sharedaccesssignature)\s*=\s*)("[^"]*"|''[^'']*''|[^;"''<>\r\n]+)'; Kind = 'group2' },
    # SAS signature query parameter.
    @{ Pattern = '(?i)([?&]sig=)([^&\s"''<>]+)'; Kind = 'group2' },
    # XML attributes: <add key="ApiKey" value="..."/>
    @{ Pattern = '(?i)(\bkey\s*=\s*"([^"]*)"\s+value\s*=\s*")([^"]*)(")'; Kind = 'xmlkv' },
    # XML attributes named like secrets: password="..." validationKey="..."
    @{ Pattern = '(?i)(\b([A-Za-z_][\w\.\-]*)\s*=\s*")([^"]*)(")'; Kind = 'attr' },
    # JSON or code assignments: "ApiKey": "...", ApiKey = "...", API_KEY=...
    @{ Pattern = '(?i)(["'']?([A-Za-z_][\w\.\-]*)["'']?\s*[:=]\s*)("([^"\\]|\\.)*"|''[^'']*'')'; Kind = 'assign' },
    @{ Pattern = '(?im)^(\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)([^\s#"''][^\r\n#]*)'; Kind = 'envline' }
)

function Protect-Text {
    # Redacts secrets in free text (config files, command output, code snippets).
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    foreach ($rule in $script:TextRules) {
        switch ($rule.Kind) {
            'whole' {
                $t = [regex]::Replace($t, $rule.Pattern, $script:Mask)
            }
            'group2' {
                $t = [regex]::Replace($t, $rule.Pattern, { param($m) $m.Groups[1].Value + $script:Mask })
            }
            'xmlkv' {
                $t = [regex]::Replace($t, $rule.Pattern, {
                    param($m)
                    $v = Protect-Value -Key $m.Groups[2].Value -Value $m.Groups[3].Value
                    $m.Groups[1].Value + $v + $m.Groups[4].Value
                })
            }
            'attr' {
                $t = [regex]::Replace($t, $rule.Pattern, {
                    param($m)
                    $name = $m.Groups[2].Value
                    if ($name -ieq 'key' -or $name -ieq 'value' -or $name -ieq 'name') { return $m.Value }
                    $v = Protect-Value -Key $name -Value $m.Groups[3].Value
                    $m.Groups[1].Value + $v + $m.Groups[4].Value
                })
            }
            'assign' {
                $t = [regex]::Replace($t, $rule.Pattern, {
                    param($m)
                    $raw = $m.Groups[3].Value
                    $q = $raw.Substring(0, 1)
                    $inner = $raw.Substring(1, $raw.Length - 2)
                    $v = Protect-Value -Key $m.Groups[2].Value -Value $inner
                    $m.Groups[1].Value + $q + $v + $q
                })
            }
            'envline' {
                $t = [regex]::Replace($t, $rule.Pattern, {
                    param($m)
                    $v = Protect-Value -Key $m.Groups[2].Value -Value $m.Groups[3].Value.TrimEnd()
                    $m.Groups[1].Value + $v
                })
            }
        }
    }
    return $t
}

function Protect-Object {
    # Redacts values in a plain object tree (ordered hashtables and arrays) by key name and shape.
    param($InputObject, [string]$KeyName = '')
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return (Protect-Value -Key $KeyName -Value $InputObject) }
    if ($InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = Protect-Object -InputObject $InputObject[$k] -KeyName ([string]$k) }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((Protect-Object -InputObject $item -KeyName $KeyName)) }
        return ,($list.ToArray())
    }
    return $InputObject
}

function Get-RedactionMask { return $script:Mask }

Export-ModuleMember -Function Test-SensitiveKey, Test-HighEntropySecret, Test-ConnectionStringLike, Protect-ConnectionString, Protect-Value, Protect-Text, Protect-Object, Get-ShannonEntropy, Get-RedactionMask
