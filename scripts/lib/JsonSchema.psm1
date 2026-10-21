# JsonSchema.psm1 - validation against a subset of JSON Schema (Windows PowerShell 5.1 has no Test-Json).
# Supported keywords: type, properties, required, additionalProperties (false), items, enum, const,
# pattern, minLength, format date-time, and local $ref (#/$defs/<name>).
# Values are the plain trees produced by ConvertTo-PlainObject (ordered hashtables and object[] arrays).

Set-StrictMode -Version 2.0

function Get-JsonType {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { return 'integer' }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        if ([Math]::Floor([double]$Value) -eq [double]$Value) { return 'integer' }
        return 'number'
    }
    if ($Value -is [System.Collections.IDictionary]) { return 'object' }
    if ($Value -is [System.Collections.IEnumerable]) { return 'array' }
    return 'unknown'
}

function Resolve-SchemaRef {
    param($Schema, $Root)
    if ($Schema -is [System.Collections.IDictionary] -and $Schema.Contains('$ref')) {
        $ref = [string]$Schema['$ref']
        if ($ref -notmatch '^#/\$defs/(.+)$') { throw "Unsupported schema reference: $ref" }
        return $Root['$defs'][$Matches[1]]
    }
    return $Schema
}

function Test-SchemaNode {
    param($Value, $Schema, $Root, [string]$Path, [System.Collections.ArrayList]$Errors)
    $Schema = Resolve-SchemaRef $Schema $Root
    $t = Get-JsonType $Value
    if ($Schema.Contains('const')) {
        if ($Value -ne $Schema['const']) { [void]$Errors.Add("${Path}: must be '$($Schema['const'])'") }
        return
    }
    if ($Schema.Contains('enum')) {
        $ok = $false
        foreach ($e in $Schema['enum']) { if (($null -eq $e -and $null -eq $Value) -or ($null -ne $Value -and $null -ne $e -and $Value -is [string] -and $Value -ceq $e)) { $ok = $true; break } }
        if (-not $ok) { [void]$Errors.Add("${Path}: value '$Value' is not one of: $(@($Schema['enum']) -join ', ')") }
        return
    }
    if ($Schema.Contains('type')) {
        $types = @($Schema['type'])
        $match = ($types -contains $t) -or ($t -eq 'integer' -and $types -contains 'number')
        if (-not $match) { [void]$Errors.Add("${Path}: expected $($types -join '|'), found $t"); return }
    }
    if ($t -eq 'string') {
        if ($Schema.Contains('minLength') -and $Value.Length -lt [int]$Schema['minLength']) { [void]$Errors.Add("${Path}: shorter than $($Schema['minLength'])") }
        if ($Schema.Contains('pattern') -and $Value -cnotmatch [string]$Schema['pattern']) { [void]$Errors.Add("${Path}: does not match $($Schema['pattern'])") }
        if ($Schema.Contains('format') -and $Schema['format'] -eq 'date-time' -and $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+\-]\d{2}:\d{2})$') { [void]$Errors.Add("${Path}: not an ISO 8601 date-time") }
    }
    if ($t -eq 'object') {
        if ($Schema.Contains('required')) {
            foreach ($r in $Schema['required']) { if (-not $Value.Contains($r)) { [void]$Errors.Add("${Path}: missing required property '$r'") } }
        }
        $props = @{}
        if ($Schema.Contains('properties')) { $props = $Schema['properties'] }
        foreach ($k in @($Value.Keys)) {
            if ($props.Contains($k)) { Test-SchemaNode -Value $Value[$k] -Schema $props[$k] -Root $Root -Path "$Path.$k" -Errors $Errors }
            elseif ($Schema.Contains('additionalProperties') -and $Schema['additionalProperties'] -is [bool] -and -not $Schema['additionalProperties']) {
                [void]$Errors.Add("${Path}: unexpected property '$k'")
            }
        }
    }
    if ($t -eq 'array' -and $Schema.Contains('items')) {
        $i = 0
        foreach ($item in $Value) { Test-SchemaNode -Value $item -Schema $Schema['items'] -Root $Root -Path "$Path[$i]" -Errors $Errors; $i++ }
    }
}

function Test-JsonSchema {
    # Validates $Value against $Schema (a plain tree). $Definition picks a $defs entry as the root, so one
    # schema file can describe several document kinds. Returns an array of error strings; empty means valid.
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)]$Schema, [string]$Definition = '')
    $errors = New-Object System.Collections.ArrayList
    $node = $Schema
    if ($Definition) {
        if (-not $Schema.Contains('$defs') -or -not $Schema['$defs'].Contains($Definition)) { throw "Schema has no definition '$Definition'." }
        $node = $Schema['$defs'][$Definition]
    }
    Test-SchemaNode -Value $Value -Schema $node -Root $Schema -Path '$' -Errors $errors
    return ,($errors.ToArray())
}

Export-ModuleMember -Function Get-JsonType, Resolve-SchemaRef, Test-SchemaNode, Test-JsonSchema
