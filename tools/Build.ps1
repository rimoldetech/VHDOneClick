# Compiles VHDOneClick.exe with PS2EXE from a version-stamped build copy,
# and packs the scripts zip.
#   powershell -NoProfile -File tools\Build.ps1 -Version 2.0.0 -OutDir out

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutDir = 'out'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$v = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'versions.psd1')
Set-Location -LiteralPath $repo

$buildDir = Join-Path $repo 'build'
$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
foreach ($d in @($buildDir, $out)) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $d
}

$stamped = Join-Path $buildDir 'VHDOneClick-Main.ps1'
& (Join-Path $PSScriptRoot 'Set-BuildVersion.ps1') -Version $Version -Source (Join-Path $repo 'VHDOneClick-Main.ps1') -OutFile $stamped

# Same rule the script uses for its file version: numeric core, four parts.
$core = ($Version -split '[-+]')[0]
$parts = @($core.Split('.') | Where-Object { $_ -match '^\d+$' })
while ($parts.Count -lt 4) { $parts += '0' }
$fileVersion = ($parts | Select-Object -First 4) -join '.'

Import-Module ps2exe -RequiredVersion $v.PS2EXE
$exe = Join-Path $out 'VHDOneClick.exe'
# -x64: the Storage cmdlets misbehave in a 32-bit host on 64-bit Windows.
Invoke-ps2exe -inputFile $stamped -outputFile $exe -x64 -requireAdmin `
    -title 'VHDOneClick' -product 'VHDOneClick' `
    -description 'Mount a VHD/VHDX through a differencing disk and open it in Explorer' `
    -company 'rimoldetech' -copyright 'GPL-3.0-or-later' -version $fileVersion
if (-not (Test-Path -LiteralPath $exe)) { throw 'PS2EXE did not produce VHDOneClick.exe.' }

$zipStage = Join-Path $buildDir 'scripts'
$null = New-Item -ItemType Directory -Path $zipStage
Copy-Item -LiteralPath $stamped -Destination $zipStage
Copy-Item -LiteralPath (Join-Path $repo 'VHDOneClick-Entrypoint.bat') -Destination $zipStage
Copy-Item -LiteralPath (Join-Path $repo 'README.md') -Destination $zipStage
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $zipStage
Compress-Archive -Path (Join-Path $zipStage '*') -DestinationPath (Join-Path $out 'VHDOneClick-scripts.zip')

Write-Output "Built $exe ($fileVersion) and VHDOneClick-scripts.zip"
