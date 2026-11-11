# End-to-end test. Needs an elevated Windows session that can mount VHDX
# files (GitHub windows-latest, or a local Windows VM).
#
#   powershell -NoProfile -File tests\Integration.ps1 -Exe out\VHDOneClick.exe
#   powershell -NoProfile -File tests\Integration.ps1        (runs the .ps1)
#
# Builds a small NTFS image with a Users\test profile that has explicit,
# protected DACLs and junctions pointing at a host folder, runs the tool
# against it with a fake SID, and checks the spec's acceptance points:
# ACE present, host ACLs untouched, parent read-only and unchanged,
# marker hidden inside the diff, logs next to the image, toggle works.

param(
    [string]$Exe,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) ('vhdoneclick-it-' + [IO.Path]::GetRandomFileName()))
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $repo 'VHDOneClick-Main.ps1'
$fakeSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
$hostDir = Join-Path $env:SystemDrive ('vhdoneclick-host-' + [IO.Path]::GetRandomFileName())
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host ('PASS ' + $What) -ForegroundColor Green }
    else { Write-Host ('FAIL ' + $What) -ForegroundColor Red; $failures.Add($What) }
}

function Invoke-Tool {
    param([string[]]$ToolArgs)
    if ($Exe) {
        & $Exe @ToolArgs | Out-Host
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript @ToolArgs | Out-Host
    }
    return $LASTEXITCODE
}

function Invoke-DiskPartScript {
    param([string[]]$Lines)
    $f = Join-Path $WorkDir ('dp-' + [IO.Path]::GetRandomFileName() + '.txt')
    [IO.File]::WriteAllText($f, (($Lines + 'exit') -join "`r`n"), [Text.Encoding]::ASCII)
    $out = & diskpart.exe /s $f 2>&1
    Remove-Item -LiteralPath $f -Force
    if ($LASTEXITCODE -ne 0) { throw ('diskpart failed: ' + ($out -join "`n")) }
}

function Get-FreeLetter {
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) })
    foreach ($c in [char[]]([int][char]'Z'..[int][char]'H')) { if ($used -notcontains [string]$c) { return [string]$c } }
    throw 'No free drive letter.'
}

function Test-HasSid {
    param([string]$Path, [string]$SidValue)
    $rules = (Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    return [bool](@($rules | Where-Object { $_.IdentityReference.Value -eq $SidValue -and $_.AccessControlType -eq 'Allow' }).Count)
}

function Get-DiffLetter {
    param([string]$DiffPath)
    $di = Get-DiskImage -ImagePath $DiffPath
    @(Get-Partition -DiskNumber $di.Number | ForEach-Object { [string]$_.DriveLetter } | Where-Object { $_ -match '^[A-Z]$' }) | Select-Object -First 1
}

$null = New-Item -ItemType Directory -Path $WorkDir -Force
$parent = Join-Path $WorkDir 'testimage.vhdx'
$diff = Join-Path $WorkDir 'testimage.diff.vhdx'

try {
    # Host folder the junctions point at. Record its ACLs.
    $null = New-Item -ItemType Directory -Path $hostDir -Force
    Set-Content -LiteralPath (Join-Path $hostDir 'host.txt') -Value 'host'
    $hostSddlBefore = @(
        (Get-Acl -LiteralPath $hostDir).Sddl,
        (Get-Acl -LiteralPath (Join-Path $hostDir 'host.txt')).Sddl
    )

    # Build the parent image.
    $L = Get-FreeLetter
    Invoke-DiskPartScript @(
        ('create vdisk file="{0}" maximum=256 type=expandable' -f $parent),
        ('select vdisk file="{0}"' -f $parent),
        'attach vdisk',
        'convert gpt',
        'create partition primary',
        'format fs=ntfs quick label=VHDTEST',
        ('assign letter={0}' -f $L)
    )
    $R = $L + ':'
    $null = New-Item -ItemType Directory -Path "$R\Windows\System32" -Force
    $null = New-Item -ItemType Directory -Path "$R\Users\test\Documents" -Force
    $null = New-Item -ItemType Directory -Path "$R\Users\test\Private\Deeper" -Force
    Set-Content -LiteralPath "$R\Users\test\Documents\doc.txt" -Value 'doc'
    Set-Content -LiteralPath "$R\Users\test\Private\Deeper\secret.txt" -Value 'secret'

    # Like a real image: explicit, protected profile root, plus a protected subfolder.
    & icacls.exe "$R\Users\test" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    & icacls.exe "$R\Users\test\Private" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    & icacls.exe "$R\Users\test\Private\Deeper" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

    # Junctions with absolute host targets: one at profile level (enumeration
    # must skip it) and one inside a protected subtree (the /T repair runs over it).
    & cmd.exe /c mklink /J "$R\Users\test\Application Data" "$hostDir" | Out-Null
    & cmd.exe /c mklink /J "$R\Users\test\Private\HostLink" "$hostDir" | Out-Null

    Dismount-DiskImage -ImagePath $parent | Out-Null
    $hashBefore = (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash

    # Version smoke test.
    $code = Invoke-Tool @('-ShowVersion')
    Assert-True ($code -eq 0) '-ShowVersion exits 0'

    # First mount.
    $code = Invoke-Tool @('-Image', $parent, '-Sid', $fakeSid, '-Mount')
    Assert-True ($code -eq 0) ('first mount exits 0 (got {0})' -f $code)
    Assert-True ((Get-DiskImage -ImagePath $diff).Attached) 'diff is attached'
    $X = (Get-DiffLetter $diff) + ':'
    Assert-True ($X.Length -eq 2) ('diff has a drive letter ({0})' -f $X)

    Assert-True (Test-HasSid "$X\Users" $fakeSid) 'ACE on \Users'
    Assert-True (Test-HasSid "$X\Users\test" $fakeSid) 'ACE on profile root'
    Assert-True (Test-HasSid "$X\Users\test\Documents" $fakeSid) 'ACE inherited by Documents'
    Assert-True (Test-HasSid "$X\Users\test\Documents\doc.txt" $fakeSid) 'ACE inherited by a file'
    Assert-True (Test-HasSid "$X\Users\test\Private" $fakeSid) 'ACE on protected subfolder (repair)'
    Assert-True (Test-HasSid "$X\Users\test\Private\Deeper\secret.txt" $fakeSid) 'ACE under nested protected folder (repair /T)'

    $hostSddlAfter = @(
        (Get-Acl -LiteralPath $hostDir).Sddl,
        (Get-Acl -LiteralPath (Join-Path $hostDir 'host.txt')).Sddl
    )
    Assert-True (($hostSddlBefore -join '|') -eq ($hostSddlAfter -join '|')) 'host folder ACLs untouched through junctions'

    Assert-True ((Get-Item -LiteralPath $parent).IsReadOnly) 'parent is read-only'

    $marker = Get-Item -LiteralPath "$X\.vhdoneclick.json" -Force -ErrorAction SilentlyContinue
    Assert-True ($null -ne $marker) 'marker exists in the diff'
    if ($marker) {
        Assert-True ([bool]($marker.Attributes -band [IO.FileAttributes]::Hidden)) 'marker is hidden'
        Assert-True (-not ($marker.Attributes -band [IO.FileAttributes]::System)) 'marker is not System'
        $m = Get-Content -LiteralPath $marker.FullName -Raw | ConvertFrom-Json
        Assert-True ([bool](@($m.grants | Where-Object { $_.sid -eq $fakeSid -and $_.complete }).Count)) 'marker records the SID as complete'
    }

    $logs = @(Get-ChildItem -LiteralPath (Join-Path $WorkDir 'VHDOneClick-logs') -Filter '*.log' -ErrorAction SilentlyContinue)
    Assert-True ($logs.Count -ge 1) 'log written next to the image'

    # Toggle: no arguments unmounts.
    $code = Invoke-Tool @('-Image', $parent)
    Assert-True ($code -eq 0) 'second run exits 0'
    Assert-True (-not (Get-DiskImage -ImagePath $diff).Attached) 'second run unmounted'

    # Remount an existing diff: marker skips the permission pass.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-Tool @('-Image', $parent, '-Sid', $fakeSid)
    $sw.Stop()
    Assert-True ($code -eq 0) 'remount exits 0'
    Write-Host ('Remount of existing diff took {0:N1} s' -f $sw.Elapsed.TotalSeconds)
    Assert-True ($sw.Elapsed.TotalSeconds -lt 15) 'remount is quick (CI allowance 15 s; spec target 5 s on real hardware)'
    $null = Invoke-Tool @('-Image', $parent, '-Unmount')
    Assert-True (-not (Get-DiskImage -ImagePath $diff).Attached) '-Unmount unmounted'

    # Two images: no -Image and no console must fail instead of guessing.
    Copy-Item -LiteralPath $parent -Destination (Join-Path $WorkDir 'second.vhdx')
    Set-ItemProperty -LiteralPath (Join-Path $WorkDir 'second.vhdx') -Name IsReadOnly -Value $false
    # The tool must sit in the image folder for the folder scan, so copy it there.
    if ($Exe) {
        $copy = Join-Path $WorkDir 'VHDOneClick.exe'
        Copy-Item -LiteralPath $Exe -Destination $copy
        $null = '' | & $copy 2>&1
    } else {
        $copy = Join-Path $WorkDir 'VHDOneClick-Main.ps1'
        Copy-Item -LiteralPath $mainScript -Destination $copy
        $null = '' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $copy 2>&1
    }
    Assert-True ($LASTEXITCODE -eq 1) 'two images with no console refuses to pick'
    Assert-True (-not (Get-DiskImage -ImagePath $diff).Attached) 'nothing was mounted when it refused'

    $hashAfter = (Get-FileHash -LiteralPath $parent -Algorithm SHA256).Hash
    Assert-True ($hashBefore -eq $hashAfter) 'parent SHA-256 unchanged'
}
finally {
    foreach ($p in @($diff, $parent, (Join-Path $WorkDir 'second.vhdx'))) {
        if (Test-Path -LiteralPath $p) {
            Dismount-DiskImage -ImagePath $p -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Get-ChildItem -LiteralPath $WorkDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.PSIsContainer) { $_.IsReadOnly = $false }
    }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $hostDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ('{0} check(s) failed.' -f $failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'All integration checks passed.' -ForegroundColor Green
