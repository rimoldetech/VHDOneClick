# Writes a build copy of the main script with $ScriptVersion stamped.
# The committed file is never changed.
#
#   pwsh tools/Set-BuildVersion.ps1 -Version 2.0.0 -OutFile build/VHDOneClick-Main.ps1

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Source = 'VHDOneClick-Main.ps1',
    [Parameter(Mandatory = $true)][string]$OutFile
)

if ($Version -notmatch '^[0-9A-Za-z.+-]+$') { throw "Version has characters that do not belong in a version string: $Version" }

$text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Source).Path)
$pattern = "(?m)^\`$ScriptVersion = '[^']*'\r?$"
$found = [regex]::Matches($text, $pattern).Count
if ($found -ne 1) { throw "Expected exactly one `$ScriptVersion line in $Source, found $found." }

$stamped = [regex]::Replace($text, "(?m)^\`$ScriptVersion = '[^']*'", "`$ScriptVersion = '$Version'")
$outFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$dir = [IO.Path]::GetDirectoryName($outFull)
if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
[IO.File]::WriteAllText($outFull, $stamped, [Text.Encoding]::ASCII)
Write-Output "Stamped $Version into $outFull"
