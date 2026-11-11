# Checks every .ps1 parses, is ASCII-only, and that the main script avoids
# patterns AMSI and Defender treat as suspicious (spec 4.7 item 4).
# Exit code 1 on any problem. Run from the repo root:  pwsh tools/Test-ScriptHygiene.ps1

param([string]$Root = '.')

$problems = New-Object System.Collections.Generic.List[string]

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
    Where-Object { $_.FullName -notmatch '[\\/](build|out|\.git)[\\/]' })

foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) {
            $problems.Add(('{0}: non-ASCII byte at offset {1}' -f $f.Name, $i))
            break
        }
    }
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) {
        $problems.Add(('{0}:{1}: {2}' -f $f.Name, $e.Extent.StartLineNumber, $e.Message))
    }
}

$main = Join-Path $Root 'VHDOneClick-Main.ps1'
if (Test-Path -LiteralPath $main) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $main).Path, [ref]$tokens, [ref]$errors)

    $badCommands = @('Add-Type', 'Invoke-Expression', 'iex', 'Invoke-WebRequest', 'iwr', 'Invoke-RestMethod', 'irm',
        'Start-BitsTransfer', 'curl', 'wget', 'New-PSDrive')
    $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $commands) {
        $name = $c.GetCommandName()
        if ($name -and ($badCommands -contains $name)) {
            $problems.Add(('VHDOneClick-Main.ps1:{0}: forbidden command {1}' -f $c.Extent.StartLineNumber, $name))
        }
    }

    $badMembers = @('FromBase64String', 'ToBase64String', 'DownloadString', 'DownloadFile', 'DownloadData', 'Load', 'LoadFrom')
    $members = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
    foreach ($m in $members) {
        $mn = $m.Member.Extent.Text
        if ($badMembers -contains $mn) {
            $problems.Add(('VHDOneClick-Main.ps1:{0}: forbidden member call {1}' -f $m.Extent.StartLineNumber, $mn))
        }
    }

    foreach ($t in $tokens) {
        if ($t.Kind -eq 'Comment') { continue }
        if ($t.Text -match 'Net\.WebClient|HttpClient|Reflection\.Assembly') {
            $problems.Add(('VHDOneClick-Main.ps1:{0}: forbidden type reference {1}' -f $t.Extent.StartLineNumber, $t.Text))
        }
    }
}

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Output ('FAIL ' + $_) }
    exit 1
}
Write-Output ('OK: {0} PowerShell file(s) checked.' -f $files.Count)
