# Repository hygiene: scripts stay ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI),
# JSON files parse, skills have the frontmatter the commands rely on.
# Label: fixture-based (checks the repository's own files).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force -DisableNameChecking
    $script:root = Get-RepoRoot
    $script:files = Get-ChildItem -LiteralPath $script:root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
}

Describe 'Repository files' -Tag 'fixture-based' {
    It 'every PowerShell file is ASCII' {
        foreach ($f in ($script:files | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $f.FullName
        }
    }
    It 'no file contains an em dash' {
        foreach ($f in ($script:files | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.md', '.json', '.cs', '.cshtml', '.js', '.config') })) {
            ([System.IO.File]::ReadAllText($f.FullName)).IndexOf([char]0x2014) | Should -Be -1 -Because $f.FullName
        }
    }
    It 'every JSON file parses' {
        Import-Module (Join-Path $script:root 'scripts/lib/Compat.psm1') -Force -DisableNameChecking
        foreach ($f in ($script:files | Where-Object { $_.Extension -eq '.json' -or $_.Name -eq 'package.manifest' })) {
            { ConvertFrom-JsonText ([System.IO.File]::ReadAllText($f.FullName)) } | Should -Not -Throw -Because $f.FullName
        }
    }
    It 'command skills disable model invocation and declare their arguments' {
        foreach ($name in @('start', 'plan')) {
            $text = Get-Content -Raw (Join-Path $script:root "skills/$name/SKILL.md")
            $text | Should -Match '(?m)^disable-model-invocation: true$'
            $text | Should -Match '(?m)^argument-hint: <target-version> \[project-path\]$'
            $text | Should -Match '(?m)^arguments: \[target, path\]$'
        }
    }
    It 'shared skills are not user-invocable and every skill stays under 500 lines' {
        foreach ($dir in (Get-ChildItem -LiteralPath (Join-Path $script:root 'skills') -Directory)) {
            $text = Get-Content -Raw (Join-Path $dir.FullName 'SKILL.md')
            ($text -split "`n").Count | Should -BeLessThan 500
            if ($dir.Name -notin @('start', 'plan')) { $text | Should -Match '(?m)^user-invocable: false$' }
        }
    }
    It 'every script a skill references exists' {
        foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $script:root 'skills') -Recurse -Filter '*.md')) {
            $text = Get-Content -Raw $f.FullName
            foreach ($m in [regex]::Matches($text, '\b([A-Z][A-Za-z\-]+\.ps1|state\.ps1)\b')) {
                Test-Path (Join-Path $script:root ('scripts/' + $m.Groups[1].Value)) | Should -BeTrue -Because "$($f.Name) references $($m.Groups[1].Value)"
            }
        }
    }
    It 'no root CLAUDE.md and no bin directory' {
        Test-Path (Join-Path $script:root 'CLAUDE.md') | Should -BeFalse
        Test-Path (Join-Path $script:root 'bin') | Should -BeFalse
    }
}
