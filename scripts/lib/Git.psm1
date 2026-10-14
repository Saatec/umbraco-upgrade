# Git.psm1 - runs git as a child process with captured output. Read-only helpers plus branch creation.

Set-StrictMode -Version 2.0

function ConvertTo-CommandLineArgument {
    # Quotes one argument for CreateProcess (MSVCRT rules).
    param([AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($backslashes * 2 + 1)); [void]$sb.Append('"'); $backslashes = 0; continue }
        if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-GitCommand {
    # Returns @{ exitCode; stdout (string[]); stderr (string) }. exitCode -1 when git cannot start.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $all = @('-C', $Root, '-c', 'core.quotepath=off', '--no-pager') + $Arguments
    $psi.Arguments = (($all | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $psi.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() } catch { return @{ exitCode = -1; stdout = @(); stderr = $_.Exception.Message } }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        return @{ exitCode = -2; stdout = @(); stderr = 'git timed out' }
    }
    $p.WaitForExit()
    $out = $outTask.Result
    $lines = @()
    if ($out) { $lines = @($out -split "`r?`n" | Where-Object { $_ -ne '' }) }
    return @{ exitCode = $p.ExitCode; stdout = $lines; stderr = $errTask.Result }
}

function Get-GitRepoInfo {
    # Read-only snapshot of the repository that contains $Root.
    param([Parameter(Mandatory)][string]$Root)
    $info = [ordered]@{ isRepo = $false; repoRoot = $null; prefix = ''; branch = $null; head = $null; detached = $false; gitAvailable = $true }
    $r = Invoke-GitCommand -Root $Root -Arguments @('rev-parse', '--is-inside-work-tree', '--show-toplevel', '--show-prefix')
    if ($r.exitCode -eq -1) { $info.gitAvailable = $false; return $info }
    if ($r.exitCode -ne 0 -or $r.stdout.Count -lt 2 -or $r.stdout[0] -ne 'true') { return $info }
    $info.isRepo = $true
    $info.repoRoot = $r.stdout[1]
    if ($r.stdout.Count -ge 3) { $info.prefix = $r.stdout[2] }
    $b = Invoke-GitCommand -Root $Root -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($b.exitCode -eq 0 -and $b.stdout.Count -gt 0) { $info.branch = $b.stdout[0] } else { $info.detached = $true }
    $h = Invoke-GitCommand -Root $Root -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')
    if ($h.exitCode -eq 0 -and $h.stdout.Count -gt 0) { $info.head = $h.stdout[0] }
    return $info
}

function Get-GitStatusEntries {
    # Porcelain v1 entries for the whole repository, with a flag for paths inside the project's state folder.
    param([Parameter(Mandatory)][string]$Root, [string]$Prefix = '')
    $r = Invoke-GitCommand -Root $Root -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    if ($r.exitCode -ne 0) { throw ('git status failed: ' + $r.stderr) }
    $stateDir = ($Prefix + '.umbraco-upgrade/')
    $entries = foreach ($line in $r.stdout) {
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2)
        $path = $line.Substring(3)
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = $path.Trim('"')
        [ordered]@{ code = $code; path = $path; inStateFolder = $path.StartsWith($stateDir, [System.StringComparison]::OrdinalIgnoreCase) }
    }
    return ,(@($entries))
}

function Get-GitOperationInProgress {
    param([Parameter(Mandatory)][string]$Root)
    $r = Invoke-GitCommand -Root $Root -Arguments @('rev-parse', '--git-dir')
    if ($r.exitCode -ne 0 -or $r.stdout.Count -eq 0) { return $null }
    $gitDir = $r.stdout[0]
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Root $gitDir }
    $markers = @{ 'rebase-merge' = 'rebase'; 'rebase-apply' = 'rebase'; 'MERGE_HEAD' = 'merge'; 'CHERRY_PICK_HEAD' = 'cherry-pick'; 'REVERT_HEAD' = 'revert'; 'BISECT_LOG' = 'bisect' }
    foreach ($k in $markers.Keys) { if (Test-Path -LiteralPath (Join-Path $gitDir $k)) { return $markers[$k] } }
    return $null
}

Export-ModuleMember -Function ConvertTo-CommandLineArgument, Invoke-GitCommand, Get-GitRepoInfo, Get-GitStatusEntries, Get-GitOperationInProgress
