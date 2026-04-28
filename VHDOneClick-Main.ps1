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

# -- State: diff exists --------------------------------------------------------
if (Test-Path $DiffPath) {
    $DiffStatus = Get-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue

    # State: mounted -> unmount (keep the diff disk for next time)
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

    # State: diff exists but not mounted -> skip creation and permission fix
    Write-Host " Diff   : Existing diff disk found - skipping setup." -ForegroundColor DarkGray
    Write-Host " Status : Not mounted -> Mounting..." -ForegroundColor Cyan

    try {
        Mount-DiskImage -ImagePath $DiffPath | Out-Null
    } catch {
        Write-Host " [ERROR] Failed to mount: $_" -ForegroundColor Red
        Write-Host ""
        pause
        exit 1
    }

} else {

    # -- State: no diff disk -> first run, full setup --------------------------
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

    try {
        Mount-DiskImage -ImagePath $DiffPath | Out-Null
    } catch {
        Write-Host " [ERROR] Failed to mount: $_" -ForegroundColor Red
        Remove-Item $DiffPath -ErrorAction SilentlyContinue
        Write-Host ""
        pause
        exit 1
    }
}

# -- Wait for the disk image to fully attach -----------------------------------
#    Mount-DiskImage can return before Windows has finished processing the
#    mount internally. Poll until Attached is True and Number is populated.
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

# -- Wait for Windows to finish assigning drive letters ------------------------
Write-Host " Waiting for Windows to assign drive letters..." -ForegroundColor DarkGray

$TargetDrive = $null

for ($i = 0; $i -lt $Retries; $i++) {
    Start-Sleep -Seconds 1
    $TargetDrive = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                       Where-Object { $_.DriveLetter -match '[A-Z]' } |
                       Sort-Object  Size -Descending |
                       Select-Object -First 1
    if ($TargetDrive) { break }
}

# -- Auto-assign a letter if Windows did not give one --------------------------
if (-not $TargetDrive) {
    Write-Host " No letter auto-assigned - attempting manual assignment..." -ForegroundColor Yellow

    $SkipTypes = @(
        '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}',  # EFI System
        '{e3c9e316-0b5c-4db8-817d-f92df00215ae}',  # MSR
        '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'   # Windows Recovery
    )

    $LargestUnlettered = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $SkipTypes -notcontains $_.GptType } |
        Where-Object { $_.Size -gt 100MB } |
        Sort-Object Size -Descending |
        Select-Object -First 1

    if ($LargestUnlettered) {
        $UsedLetters = (Get-PSDrive -PSProvider FileSystem).Name
        $FreeLetter  = [char[]]([int][char]'D'..[int][char]'Z') |
                           Where-Object { $UsedLetters -notcontains $_ } |
                           Select-Object -First 1

        if ($FreeLetter) {
            try {
                Set-Partition -DiskNumber $DiskNumber `
                              -PartitionNumber $LargestUnlettered.PartitionNumber `
                              -NewDriveLetter $FreeLetter
                Start-Sleep -Seconds 1
                $TargetDrive = Get-Partition -DiskNumber $DiskNumber `
                                   -PartitionNumber $LargestUnlettered.PartitionNumber
                Write-Host " Assigned drive letter ${FreeLetter}: manually." -ForegroundColor Green
            } catch {
                Write-Host " [ERROR] Could not assign drive letter: $_" -ForegroundColor Red
            }
        } else {
            Write-Host " [ERROR] No free drive letters available (D-Z all in use)." -ForegroundColor Red
        }
    } else {
        Write-Host " [ERROR] No suitable data partition found to assign a letter to." -ForegroundColor Red
    }
}

if (-not ($TargetDrive -and $TargetDrive.DriveLetter -match '[A-Z]')) {
    Dismount-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue
    Write-Host ""
    pause
    exit 1
}

$DriveLetter = $TargetDrive.DriveLetter

# -- Fix NTFS permissions (first run only) -------------------------------------
#    takeown claims ownership of each item first so that icacls can then
#    actually override the original machine's SIDs. Without takeown the
#    grant ACE is added but the original owner SID still wins.
#    Using the Administrators SID (*S-1-5-32-544) works on all Windows locales.
$SentinelPath = Join-Path $VHDFile.DirectoryName ($DiffName + '.perms_done')

if (-not (Test-Path $SentinelPath)) {
    Write-Host " Unlocking folders (first-run only, may take a moment)..." -ForegroundColor DarkGray
    & takeown /f "${DriveLetter}:\Users" /r /d y 2>&1 | Out-Null
    & icacls "${DriveLetter}:\Users" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    New-Item -Path $SentinelPath -ItemType File -Force | Out-Null
}

# -- Open Explorer -------------------------------------------------------------
$DrivePath = "${DriveLetter}:\"
$SizeGB    = [math]::Round($TargetDrive.Size / 1GB, 1)
Write-Host " Opened : $DrivePath ($SizeGB GB - largest volume)" -ForegroundColor Green
Write-Host ""
Start-Process explorer.exe $DrivePath
