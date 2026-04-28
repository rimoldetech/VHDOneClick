# ============================================================
#  MountToggle.ps1
#  Mounts the VHD/VHDX found alongside this script using a
#  differencing disk, so the original image is never modified.
#
#  State machine:
#    No diff disk found    -> Create diff, mount, fix permissions (first run)
#    Diff found, unmounted -> Mount existing diff (subsequent runs, fast)
#    Diff found, mounted   -> Unmount
# ============================================================

$CurrentDir = $PSScriptRoot
$VHDFile    = Get-ChildItem -Path "$CurrentDir\*" -Include *.vhd, *.vhdx |
                  Where-Object { $_.Name -notlike '*.diff.vhdx' } |
                  Sort-Object Length -Descending |
                  Select-Object -First 1

if (-not $VHDFile) {
    Write-Host ""
    Write-Host " [ERROR] No VHD/VHDX file found in this folder." -ForegroundColor Red
    Write-Host "         Place this script in the same folder as your VHD/VHDX file." -ForegroundColor Red
    Write-Host ""
    pause
    exit 1
}

$ImagePath = $VHDFile.FullName
$DiffName  = [System.IO.Path]::GetFileNameWithoutExtension($VHDFile.Name) + '.diff.vhdx'
$DiffPath  = Join-Path $VHDFile.DirectoryName $DiffName

Write-Host ""
Write-Host " Image  : $($VHDFile.Name)" -ForegroundColor Cyan

# Helper: get all currently ready fixed drives via Win32 API directly.
# This bypasses the PowerShell Storage CIM layer entirely and reflects
# exactly what Disk Management sees.
function Get-ReadyDriveLetters {
    [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        Select-Object -ExpandProperty Name  # returns 'C:', 'D:' etc.
}

# -- State: diff exists --------------------------------------------------------
if (Test-Path $DiffPath) {
    $DiffStatus = Get-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue

    # State: mounted -> unmount, keep diff for next time
    if ($DiffStatus -and $DiffStatus.Attached) {
        Write-Host " Status : Mounted -> Unmounting..." -ForegroundColor Yellow
        try {
            Dismount-DiskImage -ImagePath $DiffPath | Out-Null
            Write-Host " Status : Unmounted successfully." -ForegroundColor Green
            Write-Host "          (Diff disk kept for faster next access.)" -ForegroundColor DarkGray
        } catch {
            Write-Host " [ERROR] Could not unmount: $_" -ForegroundColor Red
        }
        Write-Host ""
        pause
        exit 0
    }

    # State: diff exists but unmounted -> mount only
    Write-Host " Diff   : Existing diff disk found - skipping setup." -ForegroundColor DarkGray
    Write-Host " Status : Not mounted -> Mounting..." -ForegroundColor Cyan

    $DrivesBefore = Get-ReadyDriveLetters

    try {
        Mount-DiskImage -ImagePath $DiffPath -ErrorAction Stop | Out-Null
    } catch {
        Write-Host " [ERROR] Failed to mount: $_" -ForegroundColor Red
        Write-Host ""
        pause
        exit 1
    }

} else {

    # -- State: no diff -> first run, full setup --------------------------------
    Write-Host " Status : First run - creating differencing disk..." -ForegroundColor Cyan

    $DiffCreated = $false

    # Attempt 1: New-VHD (requires Hyper-V Management Tools)
    if (Get-Command New-VHD -ErrorAction SilentlyContinue) {
        try {
            New-VHD -Path $DiffPath -ParentPath $ImagePath -Differencing | Out-Null
            $DiffCreated = $true
        } catch {
            Write-Host " [WARN]  New-VHD failed - trying diskpart..." -ForegroundColor Yellow
        }
    }

    # Attempt 2: diskpart (built into every Windows install)
    if (-not $DiffCreated) {
        $DpScript = "create vdisk file=`"$DiffPath`" parent=`"$ImagePath`"`r`nexit`r`n"
        $DpFile   = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.txt')
        [System.IO.File]::WriteAllText($DpFile, $DpScript, [System.Text.Encoding]::ASCII)
        & diskpart /s $DpFile 2>&1 | Out-Null
        Remove-Item $DpFile -ErrorAction SilentlyContinue
        $DiffCreated = Test-Path $DiffPath
    }

    if (-not $DiffCreated) {
        Write-Host " [ERROR] Could not create a differencing disk." -ForegroundColor Red
        Write-Host "         Try enabling Hyper-V Management Tools in Windows Features." -ForegroundColor Red
        Write-Host ""
        pause
        exit 1
    }

    Write-Host " Mounting..." -ForegroundColor Cyan

    $DrivesBefore = Get-ReadyDriveLetters

    try {
        Mount-DiskImage -ImagePath $DiffPath -ErrorAction Stop | Out-Null
    } catch {
        Write-Host " [ERROR] Failed to mount: $_" -ForegroundColor Red
        Remove-Item $DiffPath -ErrorAction SilentlyContinue
        Write-Host ""
        pause
        exit 1
    }
}

# -- Poll until the disk is fully attached -------------------------------------
Write-Host " Waiting for disk to attach..." -ForegroundColor DarkGray

$DiskImage  = $null
$DiskNumber = $null
$Retries    = 20

for ($i = 0; $i -lt $Retries; $i++) {
    Start-Sleep -Seconds 1
    $DiskImage = Get-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue
    if ($DiskImage -and $DiskImage.Attached -and $null -ne $DiskImage.Number) {
        $DiskNumber = $DiskImage.Number
        break
    }
}

if ($null -eq $DiskNumber) {
    Write-Host " [ERROR] Disk did not attach within the expected time." -ForegroundColor Red
    Dismount-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue
    Write-Host ""
    pause
    exit 1
}

# -- Poll for new drive letters using Win32 API --------------------------------
#    Compare against the pre-mount snapshot. DriveInfo.GetDrives() calls
#    GetLogicalDrives() directly -- the same source as Disk Management.
Write-Host " Waiting for Windows to assign drive letters..." -ForegroundColor DarkGray

$TargetDrive = $null

for ($i = 0; $i -lt $Retries; $i++) {
    Start-Sleep -Seconds 1
    $NewDrives = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        Where-Object { $DrivesBefore -notcontains $_.Name } |
        Sort-Object TotalSize -Descending
    if ($NewDrives) {
        $TargetDrive = $NewDrives | Select-Object -First 1
        break
    }
}

# -- Fallback: assign a letter via diskpart if nothing appeared ----------------
#    Used in environments where Windows skips auto-assignment entirely.
if (-not $TargetDrive) {
    Write-Host " No letter auto-assigned - attempting manual assignment via diskpart..." -ForegroundColor Yellow

    $UsedLetters = [System.IO.DriveInfo]::GetDrives() | Select-Object -ExpandProperty Name |
        ForEach-Object { $_[0] }  # 'C:' -> 'C'
    $FreeLetter = [char[]]([int][char]'D'..[int][char]'Z') |
        Where-Object { $UsedLetters -notcontains $_ } |
        Select-Object -First 1

    if ($FreeLetter) {
        # Use diskpart to select the disk and assign - works even when
        # the Storage CIM layer cannot see the partitions.
        $DpScript = @"
select disk $DiskNumber
list partition
"@
        $DpFile  = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.txt')
        [System.IO.File]::WriteAllText($DpFile, $DpScript, [System.Text.Encoding]::ASCII)
        $DpOut   = & diskpart /s $DpFile 2>&1
        Remove-Item $DpFile -ErrorAction SilentlyContinue

        # Parse diskpart output to find the largest Primary partition
        $PartLines = $DpOut | Where-Object { $_ -match 'Partition\s+\d+\s+Primary' }
        $BestPart  = $PartLines | ForEach-Object {
            if ($_ -match 'Partition\s+(\d+)\s+Primary\s+(\d+)\s*(\w+)') {
                $mult = switch ($Matches[3]) { 'GB' {1GB} 'MB' {1MB} default {1KB} }
                [PSCustomObject]@{ Num = [int]$Matches[1]; Bytes = [int]$Matches[2] * $mult }
            }
        } | Sort-Object Bytes -Descending | Select-Object -First 1

        if ($BestPart) {
            $DpAssign = @"
select disk $DiskNumber
select partition $($BestPart.Num)
assign letter=$FreeLetter
"@
            $DpFile2 = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.txt')
            [System.IO.File]::WriteAllText($DpFile2, $DpAssign, [System.Text.Encoding]::ASCII)
            & diskpart /s $DpFile2 2>&1 | Out-Null
            Remove-Item $DpFile2 -ErrorAction SilentlyContinue

            Start-Sleep -Seconds 2
            $Candidate = [System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_[0] -eq $FreeLetter }
            if ($Candidate) {
                $TargetDrive = $Candidate
                Write-Host " Assigned drive letter ${FreeLetter}: manually." -ForegroundColor Green
            } else {
                Write-Host " [ERROR] Letter assigned but drive not accessible." -ForegroundColor Red
            }
        } else {
            Write-Host " [ERROR] No Primary partition found on disk $DiskNumber." -ForegroundColor Red
        }
    } else {
        Write-Host " [ERROR] No free drive letters available (D-Z all in use)." -ForegroundColor Red
    }
}

if (-not $TargetDrive) {
    Dismount-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue
    Write-Host ""
    pause
    exit 1
}

$DriveLetter = $TargetDrive.Name[0]  # 'E:' -> 'E'

# -- Fix NTFS permissions (first run only) -------------------------------------
#    takeown claims ownership so icacls can override the original machine's SIDs.
#    Sentinel file prevents this re-running on subsequent mounts.
$SentinelPath = Join-Path $VHDFile.DirectoryName ($DiffName + '.perms_done')

if (-not (Test-Path $SentinelPath)) {
    Write-Host " Unlocking folders (first-run only, may take a moment)..." -ForegroundColor DarkGray
    & takeown /f "${DriveLetter}:\Users" /r /d y 2>&1 | Out-Null
    & icacls "${DriveLetter}:\Users" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    New-Item -Path $SentinelPath -ItemType File -Force | Out-Null
}

# -- Open Explorer -------------------------------------------------------------
$DrivePath = "${DriveLetter}:\"
$SizeGB    = [math]::Round($TargetDrive.TotalSize / 1GB, 1)
Write-Host " Opened : $DrivePath ($SizeGB GB - largest volume)" -ForegroundColor Green
Write-Host ""
Start-Process explorer.exe $DrivePath
