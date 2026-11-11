# Hygiene, lint and unit tests. Same checks CI runs.
#   powershell -NoProfile -File tools\Invoke-Checks.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$v = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'versions.psd1')
Set-Location -LiteralPath $repo

Write-Output '== Hygiene (parse, ASCII, forbidden patterns)'
& (Join-Path $PSScriptRoot 'Test-ScriptHygiene.ps1') -Root $repo
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Output '== PSScriptAnalyzer'
Import-Module PSScriptAnalyzer -RequiredVersion $v.PSScriptAnalyzer
$results = @(Invoke-ScriptAnalyzer -Path $repo -Recurse -Settings (Join-Path $repo 'PSScriptAnalyzerSettings.psd1'))
$results | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 220 | Write-Output
$errors = @($results | Where-Object { $_.Severity -eq 'Error' -or $_.Severity -eq 'ParseError' })
if ($errors.Count -gt 0) {
    Write-Output ('{0} analyzer error(s).' -f $errors.Count)
    exit 1
}

Write-Output '== Pester'
Import-Module Pester -RequiredVersion $v.Pester
$c = New-PesterConfiguration
$c.Run.Path = (Join-Path $repo 'tests\VHDOneClick.Tests.ps1')
$c.Run.Exit = $true
$c.TestResult.Enabled = $true
$c.TestResult.OutputPath = (Join-Path $repo 'testResults.xml')
$c.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $c
