# Installs the pinned build and test modules from tools/versions.psd1.
#   powershell -NoProfile -File tools\Install-BuildTools.ps1

$ErrorActionPreference = 'Stop'
$v = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'versions.psd1')

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

Install-Module -Name ps2exe -RequiredVersion $v.PS2EXE -Scope CurrentUser -Force
Install-Module -Name Pester -RequiredVersion $v.Pester -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -RequiredVersion $v.PSScriptAnalyzer -Scope CurrentUser -Force

Write-Output ('ps2exe {0}, Pester {1}, PSScriptAnalyzer {2}' -f $v.PS2EXE, $v.Pester, $v.PSScriptAnalyzer)
