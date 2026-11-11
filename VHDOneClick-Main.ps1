# ============================================================
#  VHDOneClick-Main.ps1
#  Mounts a VHD/VHDX through a differencing disk so the original
#  image is never written, grants the interactive user access to
#  the profile folders inside it, and opens it in Explorer.
#
#  No arguments: mount if unmounted, unmount if mounted.
#  Run with -? for parameters, or see README.md.
#
#  Target: Windows PowerShell 5.1. Keep this file ASCII-only and
#  free of Add-Type, Invoke-Expression, base64 and downloads, since
#  the release exe is a PS2EXE build and AMSI scans it at runtime.
#
#  License: GPL-3.0. Source: https://github.com/rimoldetech/VHDOneClick
# ============================================================

param(
    [string]$Image,
    [switch]$Mount,
    [switch]$Unmount,
    [switch]$Reset,
    [switch]$GrantAllUsers,
    [ValidateSet('F', 'M', 'RX')]
    [string]$Access = 'F',
    [switch]$Deep,
    [switch]$ClearReadOnly,
    [string]$Sid,
    [switch]$ShowVersion
)

# Stamped by the release workflow in a build copy. Do not reformat this line.
$ScriptVersion = '2.0.0-dev'

# Captured at load time. Empty inside a PS2EXE build.
$script:LoadScriptRoot = $PSScriptRoot

$script:AllUsersSid       = 'S-1-5-32-545'
$script:MarkerName        = '.vhdoneclick.json'
$script:MarkerSchema      = 1
$script:LogFolderName     = 'VHDOneClick-logs'
$script:LogKeep           = 10
$script:PollMs            = 200
$script:AttachTimeoutSec  = 20
$script:LetterTimeoutSec  = 20
$script:LetterSettleMs    = 1000
$script:VerifyDepth       = 3
$script:DeepParallel      = 4

$script:LogFile    = $null
$script:LogBuffer  = New-Object System.Collections.Generic.List[string]
$script:ExitCode   = 0
$script:FromExplorer = $null

# ------------------------------------------------------------
#  Pure helpers (no system changes; covered by Pester)
# ------------------------------------------------------------

function Get-BaseFolder {
    # $PSScriptRoot is empty inside a PS2EXE build, so fall back to the
    # folder of the running exe.
    param(
        [string]$ScriptRoot,
        [string]$ProcessPath
    )
    if ($ScriptRoot) { return $ScriptRoot }
    if (-not $ProcessPath) {
        $ProcessPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    }
    return [IO.Path]::GetDirectoryName($ProcessPath)
}

function Test-IsDiffName {
    param([string]$Name)
    return ($Name -like '*.diff.vhd' -or $Name -like '*.diff.vhdx')
}

function Test-IsImageName {
    param([string]$Name)
    $ext = [IO.Path]::GetExtension($Name)
    return (($ext -eq '.vhd' -or $ext -eq '.vhdx') -and -not (Test-IsDiffName $Name))
}

function Get-ImageCandidates {
    param([string]$Folder)
    @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-IsImageName $_.Name } |
        Sort-Object Name)
}

function Get-DiffPath {
    # A differencing disk must match its parent's format, so .vhd gets .diff.vhd.
    param([string]$ImagePath)
    $dir  = [IO.Path]::GetDirectoryName($ImagePath)
    $base = [IO.Path]::GetFileNameWithoutExtension($ImagePath)
    $ext  = [IO.Path]::GetExtension($ImagePath)
    return (Join-Path $dir ($base + '.diff' + $ext))
}

function Test-PathOnDrive {
    # True only when Path resolves to somewhere under the mounted drive root.
    # Guards against acting on host paths through junction targets.
    param(
        [string]$Path,
        [string]$DriveLetter
    )
    if (-not $Path -or -not $DriveLetter) { return $false }
    if ($Path.StartsWith('\\')) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $false }
    $root = ($DriveLetter.Substring(0, 1) + ':\')
    return $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SidString {
    param([string]$Value)
    if ($Value -notmatch '^S-1-\d+(-\d+)+$') { return $false }
    try {
        $null = New-Object System.Security.Principal.SecurityIdentifier($Value)
        return $true
    } catch {
        return $false
    }
}

function Select-TargetSid {
    # Order: -Sid override, owner of explorer.exe in this session, current token.
    param(
        [string]$OverrideSid,
        [string[]]$ExplorerSids,
        [string]$CurrentSid
    )
    if ($OverrideSid) {
        return [pscustomobject]@{ Sid = $OverrideSid; Source = 'parameter' }
    }
    $first = @($ExplorerSids | Where-Object { $_ }) | Select-Object -First 1
    if ($first) {
        return [pscustomobject]@{ Sid = $first; Source = 'explorer.exe owner' }
    }
    return [pscustomobject]@{ Sid = $CurrentSid; Source = 'current process' }
}

function Select-TargetVolume {
    # Volumes: objects with Letter, Size, HasSystem32, HasUsers.
    # First a Windows volume, else one with \Users, else the largest.
    param([object[]]$Volumes)
    $v = @($Volumes | Where-Object { $_ })
    if ($v.Count -eq 0) { return $null }
    $win = @($v | Where-Object { $_.HasSystem32 } | Sort-Object Size -Descending)
    if ($win.Count -gt 0) { return [pscustomobject]@{ Volume = $win[0]; Reason = 'contains \Windows\System32' } }
    $usr = @($v | Where-Object { $_.HasUsers } | Sort-Object Size -Descending)
    if ($usr.Count -gt 0) { return [pscustomobject]@{ Volume = $usr[0]; Reason = 'contains \Users' } }
    $big = @($v | Sort-Object Size -Descending)
    return [pscustomobject]@{ Volume = $big[0]; Reason = 'largest new volume' }
}

function ConvertFrom-DiskPartPartitionList {
    # Parses "list partition" output into Num, Type, Bytes.
    param([string[]]$Lines)
    $units = @{ 'B' = 1L; 'KB' = 1KB; 'MB' = 1MB; 'GB' = 1GB; 'TB' = 1TB }
    foreach ($line in $Lines) {
        if ($line -match 'Partition\s+(\d+)\s+(\S+)\s+(\d+)\s*(B|KB|MB|GB|TB)\b') {
            [pscustomobject]@{
                Num   = [int]$Matches[1]
                Type  = $Matches[2]
                Bytes = [long]$Matches[3] * $units[$Matches[4].ToUpperInvariant()]
            }
        }
    }
}

function Get-IcaclsFailureCount {
    # Returns the "Failed processing N files" count, or -1 if the summary
    # line is missing (localized Windows). Callers then rely on exit code.
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match 'Failed processing (\d+) files') { return [int]$Matches[1] }
    }
    return -1
}

function Get-IcaclsErrorLines {
    param([string[]]$Lines)
    @($Lines | Where-Object {
        $_ -and
        $_ -notmatch '^\s*$' -and
        $_ -notmatch 'Successfully processed' -and
        $_ -notmatch '^processed (file|dir):'
    })
}

function Get-LogsToRemove {
    # Given log files, returns the ones beyond the newest Keep.
    param(
        [object[]]$Files,
        [int]$Keep = 10
    )
    @($Files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip $Keep)
}

function New-Marker {
    param(
        [string]$Version,
        [long]$ParentSize,
        [datetime]$ParentLastWriteUtc
    )
    [pscustomobject]@{
        schema             = $script:MarkerSchema
        scriptVersion      = $Version
        parentSize         = $ParentSize
        parentLastWriteUtc = $ParentLastWriteUtc.ToUniversalTime().ToString('o')
        failureCount       = 0
        grants             = @()
    }
}

function Set-MarkerGrant {
    # Adds or replaces the entry for one SID. Returns the updated marker.
    param(
        [object]$Marker,
        [string]$Sid,
        [string]$Access,
        [bool]$Complete,
        [int]$Failures,
        [string]$Machine,
        [datetime]$When
    )
    $entry = [pscustomobject]@{
        sid          = $Sid
        access       = $Access
        complete     = $Complete
        failures     = $Failures
        machine      = $Machine
        timestampUtc = $When.ToUniversalTime().ToString('o')
    }
    $others = @($Marker.grants | Where-Object { $_ -and $_.sid -ne $Sid })
    $Marker.grants = @($others + $entry)
    return $Marker
}

function Test-MarkerComplete {
    param(
        [object]$Marker,
        [string[]]$Sids,
        [string]$Access
    )
    if (-not $Marker -or -not $Marker.grants) { return $false }
    foreach ($s in $Sids) {
        $hit = @($Marker.grants | Where-Object {
            $_.sid -eq $s -and $_.access -eq $Access -and $_.complete -eq $true
        })
        if ($hit.Count -eq 0) { return $false }
    }
    return $true
}

function ConvertTo-MarkerJson {
    param([object]$Marker)
    return ($Marker | ConvertTo-Json -Depth 5)
}

function ConvertFrom-MarkerJson {
    # Marker content comes from the image, so treat it as untrusted:
    # anything that does not parse to the expected shape is ignored.
    param([string]$Json)
    if (-not $Json) { return $null }
    try { $m = $Json | ConvertFrom-Json } catch { return $null }
    if (-not $m -or $m.schema -ne $script:MarkerSchema) { return $null }
    if ($null -eq $m.grants) { $m | Add-Member -NotePropertyName grants -NotePropertyValue @() -Force }
    $m.grants = @($m.grants | Where-Object { $_ -and $_.sid -and (Test-SidString ([string]$_.sid)) })
    return $m
}

function Get-GrantArguments {
    param(
        [string[]]$Sids,
        [string]$Access
    )
    @($Sids | ForEach-Object { '*' + $_ + ':(OI)(CI)' + $Access })
}

function Get-ReleaseVersionNumber {
    # "2.0.0-rc1" -> "2.0.0.0" for file version resources.
    param([string]$Version)
    $core = ($Version -split '[-+]')[0]
    $parts = @($core.Split('.') | Where-Object { $_ -match '^\d+$' })
    while ($parts.Count -lt 4) { $parts += '0' }
    return (($parts | Select-Object -First 4) -join '.')
}

# ------------------------------------------------------------
#  Logging
# ------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Detail')]
        [string]$Level = 'Info',
        [switch]$FileOnly
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = '{0} [{1}] {2}' -f $stamp, $Level.ToUpperInvariant(), $Message
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [Text.Encoding]::ASCII) } catch { $null = $_ }
    } else {
        $script:LogBuffer.Add($line)
    }
    if ($FileOnly) { return }
    $color = switch ($Level) {
        'Ok'     { 'Green' }
        'Warn'   { 'Yellow' }
        'Error'  { 'Red' }
        'Detail' { 'DarkGray' }
        default  { 'Cyan' }
    }
    $prefix = switch ($Level) {
        'Warn'  { ' [WARN]  ' }
        'Error' { ' [ERROR] ' }
        default { ' ' }
    }
    Write-Host ($prefix + $Message) -ForegroundColor $color
}

function Test-FolderWritable {
    param([string]$Folder)
    try {
        if (-not (Test-Path -LiteralPath $Folder)) {
            $null = New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop
        }
        $probe = Join-Path $Folder ('.write-test-' + [IO.Path]::GetRandomFileName())
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Initialize-Log {
    param([string]$ImagePath)
    $imageDir  = [IO.Path]::GetDirectoryName($ImagePath)
    $imageName = [IO.Path]::GetFileNameWithoutExtension($ImagePath)
    $folder    = Join-Path $imageDir $script:LogFolderName
    $fallback  = $false
    if (-not (Test-FolderWritable $folder)) {
        $folder   = Join-Path ([IO.Path]::GetTempPath()) $script:LogFolderName
        $fallback = $true
        if (-not (Test-FolderWritable $folder)) { return }
    }
    $name = '{0}-{1}.log' -f $imageName, (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:LogFile = Join-Path $folder $name
    try {
        [IO.File]::AppendAllText($script:LogFile, (($script:LogBuffer -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    } catch {
        $script:LogFile = $null
        return
    }
    $script:LogBuffer.Clear()
    if ($fallback) {
        Write-Log ('Image folder is not writable. Logging to ' + $script:LogFile) -Level Warn
    } else {
        Write-Log ('Log    : ' + $script:LogFile) -Level Detail
    }
    $old = Get-LogsToRemove -Files @(Get-ChildItem -LiteralPath $folder -Filter ($imageName + '-*.log') -File -ErrorAction SilentlyContinue) -Keep $script:LogKeep
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------
#  Process and console helpers
# ------------------------------------------------------------

function Get-SystemTool {
    # Elevated code: run system tools from System32, never from PATH.
    param([string]$Name)
    return (Join-Path ([Environment]::SystemDirectory) $Name)
}

function Invoke-Native {
    # Runs a native tool and returns ExitCode plus output as strings.
    # EAP is relaxed locally, since PS 5.1 turns stderr lines into errors.
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$InputText
    )
    $ErrorActionPreference = 'Continue'
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $out = $InputText | & $FilePath @ArgumentList 2>&1
    } else {
        $out = & $FilePath @ArgumentList 2>&1
    }
    $code = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $code
        Output   = @($out | ForEach-Object { "$_" })
    }
}

function Get-ParentProcessChain {
    param([int]$StartPid = $PID, [int]$Depth = 4)
    $names = @()
    $current = $StartPid
    for ($i = 0; $i -lt $Depth; $i++) {
        $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $current) -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.ParentProcessId) { break }
        $parent = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $p.ParentProcessId) -ErrorAction SilentlyContinue
        if (-not $parent) { break }
        $names += $parent.Name.ToLowerInvariant()
        $current = $parent.ProcessId
    }
    return $names
}

function Test-LaunchedFromExplorer {
    # Double-click (exe or batch) means the window closes when we exit.
    # Walk up through cmd/powershell/conhost until something else appears.
    if ($null -ne $script:FromExplorer) { return $script:FromExplorer }
    $script:FromExplorer = $false
    try {
        foreach ($n in (Get-ParentProcessChain)) {
            if ($n -eq 'explorer.exe') { $script:FromExplorer = $true; break }
            if ($n -notin @('cmd.exe', 'powershell.exe', 'conhost.exe', 'vhdoneclick.exe')) { break }
        }
    } catch { $script:FromExplorer = $false }
    return $script:FromExplorer
}

function Wait-OnError {
    if (Test-LaunchedFromExplorer) {
        Write-Host ''
        $null = Read-Host ' Press Enter to close'
    }
}

function Wait-OnSuccess {
    # Not a pause: a short hold so a double-click user can read the result.
    if (Test-LaunchedFromExplorer) { Start-Sleep -Seconds 4 }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-Tool {
    # Ends the run from anywhere inside Main with an exit code.
    param([int]$Code, [string]$Message)
    if ($Message) { Write-Log $Message -Level Error }
    $script:ExitCode = $Code
    throw 'VHDOneClick.Stop'
}

function Test-InteractiveInput {
    try { return (-not [Console]::IsInputRedirected) -and [Environment]::UserInteractive } catch { return $true }
}

# ------------------------------------------------------------
#  diskpart
# ------------------------------------------------------------

function Invoke-DiskPart {
    # Feeds commands on stdin. If Validate rejects the result, retries once
    # with a script file under %SystemRoot%\Temp, created with CreateNew so
    # a pre-planted file with the same name cannot be reused.
    param(
        [string[]]$Commands,
        [scriptblock]$Validate
    )
    $diskpart = Get-SystemTool 'diskpart.exe'
    $text = (@($Commands) + 'exit') -join "`r`n"
    $r = Invoke-Native -FilePath $diskpart -InputText $text
    if (-not $Validate -or (& $Validate $r)) { return $r }

    Write-Log 'diskpart over stdin did not give the expected result, retrying with a script file.' -Level Detail
    $tempDir = Join-Path $env:SystemRoot 'Temp'
    $file = Join-Path $tempDir ('vhdoneclick-' + [IO.Path]::GetRandomFileName() + '.txt')
    try {
        $fs = New-Object IO.FileStream($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes($text + "`r`n")
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
        $r = Invoke-Native -FilePath $diskpart -ArgumentList @('/s', $file)
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    return $r
}

# ------------------------------------------------------------
#  Image and disk handling
# ------------------------------------------------------------

function Resolve-ImagePath {
    param([string]$ImageArg, [string]$BaseFolder)
    if ($ImageArg) {
        if (-not (Test-Path -LiteralPath $ImageArg -PathType Leaf)) {
            Stop-Tool 1 ('Image not found: ' + $ImageArg)
        }
        $full = (Get-Item -LiteralPath $ImageArg -Force).FullName
        if (Test-IsDiffName ([IO.Path]::GetFileName($full))) {
            Stop-Tool 1 'That is a differencing disk. Point -Image at the parent .vhd/.vhdx instead.'
        }
        if (-not (Test-IsImageName ([IO.Path]::GetFileName($full)))) {
            Stop-Tool 1 ('Not a .vhd or .vhdx file: ' + $full)
        }
        return $full
    }

    $candidates = @(Get-ImageCandidates $BaseFolder)
    if ($candidates.Count -eq 0) {
        Stop-Tool 1 ('No VHD/VHDX file found in ' + $BaseFolder + '. Put VHDOneClick in the same folder as the image, or pass -Image.')
    }
    if ($candidates.Count -eq 1) { return $candidates[0].FullName }

    if (-not (Test-InteractiveInput)) {
        Stop-Tool 1 'More than one image in this folder and no console to ask. Pass -Image.'
    }
    Write-Host ''
    Write-Host ' More than one image found:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $gb = [math]::Round($candidates[$i].Length / 1GB, 1)
        Write-Host ('   {0}) {1}  ({2} GB)' -f ($i + 1), $candidates[$i].Name, $gb)
    }
    while ($true) {
        $answer = Read-Host ' Pick a number (or Q to quit)'
        if ($answer -match '^[Qq]') { Stop-Tool 1 'Cancelled.' }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
            return $candidates[$n - 1].FullName
        }
    }
}

function Get-DiffAttached {
    param([string]$DiffPath)
    if (-not (Test-Path -LiteralPath $DiffPath)) { return $false }
    $di = Get-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue
    return [bool]($di -and $di.Attached)
}

function Dismount-Diff {
    param([string]$DiffPath)
    try {
        Dismount-DiskImage -ImagePath $DiffPath -ErrorAction Stop | Out-Null
        Write-Log 'Status : Unmounted. Diff kept for faster next access.' -Level Ok
    } catch {
        Stop-Tool 1 ('Could not unmount: ' + $_.Exception.Message)
    }
}

function Protect-ParentImage {
    param([string]$ImagePath)
    try {
        $item = Get-Item -LiteralPath $ImagePath -Force -ErrorAction Stop
        if ($item.IsReadOnly) {
            Write-Log 'Parent : already read-only.' -Level Detail
            return
        }
        Set-ItemProperty -LiteralPath $ImagePath -Name IsReadOnly -Value $true -ErrorAction Stop
        Write-Log 'Parent : set read-only so it cannot be modified by accident. Use -ClearReadOnly to undo.' -Level Info
    } catch {
        Write-Log ('Parent : could not set read-only (' + $_.Exception.Message + '). Continuing.') -Level Warn
    }
}

function New-DiffDisk {
    param([string]$ImagePath, [string]$DiffPath)
    if (Get-Command New-VHD -ErrorAction SilentlyContinue) {
        try {
            New-VHD -Path $DiffPath -ParentPath $ImagePath -Differencing -ErrorAction Stop | Out-Null
            Write-Log 'Diff   : created with New-VHD.' -Level Detail
            return $true
        } catch {
            Write-Log ('New-VHD failed (' + $_.Exception.Message + '), trying diskpart.') -Level Warn
            Remove-Item -LiteralPath $DiffPath -Force -ErrorAction SilentlyContinue
        }
    }
    $cmd = 'create vdisk file="{0}" parent="{1}"' -f $DiffPath, $ImagePath
    $r = Invoke-DiskPart -Commands @($cmd) -Validate { param($res) $null = $res; Test-Path -LiteralPath $DiffPath }
    foreach ($l in $r.Output) { if ($l.Trim()) { Write-Log ('diskpart: ' + $l.Trim()) -Level Detail -FileOnly } }
    if (Test-Path -LiteralPath $DiffPath) {
        Write-Log 'Diff   : created with diskpart.' -Level Detail
        return $true
    }
    return $false
}

function Get-FixedDriveSnapshot {
    @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object {
        $ready = $false
        try { $ready = $_.IsReady } catch { $ready = $false }
        [pscustomobject]@{ Letter = $_.Name.Substring(0, 1).ToUpperInvariant(); Ready = $ready }
    })
}

function Wait-DiskAttach {
    param([string]$DiffPath)
    $deadline = [DateTime]::UtcNow.AddSeconds($script:AttachTimeoutSec)
    while ($true) {
        $di = Get-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue
        if ($di -and $di.Attached -and $null -ne $di.Number) { return [int]$di.Number }
        if ([DateTime]::UtcNow -ge $deadline) { return $null }
        Start-Sleep -Milliseconds $script:PollMs
    }
}

function Repair-DiskOnline {
    # Brings the attached diff online. A signature collision means the image
    # came from this machine (its disk is still here), so give the diff a new
    # disk identifier. The change lands in the diff only.
    param([int]$DiskNumber)
    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) {
        Write-Log ('Disk {0} not visible to the Storage cmdlets, skipping online checks.' -f $DiskNumber) -Level Detail
        return
    }
    if ($disk.IsOffline) {
        $reason = [string]$disk.OfflineReason
        Write-Log ('Disk {0} is offline (reason: {1}).' -f $DiskNumber, $reason) -Level Warn
        if ($reason -match 'Collision' -or $reason -eq '4') {
            try {
                if ([string]$disk.PartitionStyle -eq 'GPT') {
                    $guid = '{' + [guid]::NewGuid().ToString() + '}'
                    Set-Disk -Number $DiskNumber -Guid $guid -ErrorAction Stop
                    Write-Log ('Signature collision: gave the diff a new GPT disk GUID ' + $guid) -Level Info
                } else {
                    $sig = [uint32](Get-Random -Minimum 1 -Maximum ([int]::MaxValue))
                    Set-Disk -Number $DiskNumber -Signature $sig -ErrorAction Stop
                    Write-Log ('Signature collision: gave the diff a new MBR signature 0x{0:X8}' -f $sig) -Level Info
                }
            } catch {
                Stop-Tool 1 ('Signature collision and the disk ID could not be changed: ' + $_.Exception.Message + '. This happens when mounting an image on the machine it came from.')
            }
        }
        try {
            Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop
            Write-Log ('Disk {0} brought online.' -f $DiskNumber) -Level Ok
        } catch {
            Stop-Tool 1 ('Disk is offline and could not be brought online: ' + $_.Exception.Message)
        }
    }
    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if ($disk -and $disk.IsReadOnly) {
        try {
            Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction Stop
            Write-Log 'Disk was read-only, cleared (writes go to the diff).' -Level Detail
        } catch {
            Write-Log ('Disk is read-only and could not be changed: ' + $_.Exception.Message) -Level Warn
        }
    }
}

function Wait-NewDrives {
    # Polls every PollMs, checking before sleeping. Once something appears,
    # keeps polling until the set stops changing for LetterSettleMs, since
    # multi-partition images get their letters one at a time.
    param([string[]]$Before)
    $deadline = [DateTime]::UtcNow.AddSeconds($script:LetterTimeoutSec)
    $lastSig = ''
    $stableSince = $null
    while ($true) {
        $new = @(Get-FixedDriveSnapshot | Where-Object { $Before -notcontains $_.Letter })
        $sig = (@($new | ForEach-Object { $_.Letter + [int]$_.Ready }) -join ',')
        if ($new.Count -gt 0) {
            if ($sig -ne $lastSig) { $lastSig = $sig; $stableSince = [DateTime]::UtcNow }
            elseif (([DateTime]::UtcNow - $stableSince).TotalMilliseconds -ge $script:LetterSettleMs) { return $new }
        }
        if ([DateTime]::UtcNow -ge $deadline) { return $new }
        Start-Sleep -Milliseconds $script:PollMs
    }
}

function Add-LetterWithDiskPart {
    # Fallback for hosts with automount disabled.
    param([int]$DiskNumber)
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $free = @([char[]]([int][char]'D'..[int][char]'Z') | ForEach-Object { [string]$_ } | Where-Object { $used -notcontains $_ }) | Select-Object -First 1
    if (-not $free) { Stop-Tool 1 'No free drive letters (D-Z all in use). Disconnect a drive or network share and try again.' }

    $r = Invoke-DiskPart -Commands @(('select disk {0}' -f $DiskNumber), 'list partition') -Validate { param($res) ($res.Output -join "`n") -match 'Partition\s+\d+' }
    $parts = @(ConvertFrom-DiskPartPartitionList $r.Output | Where-Object { $_.Type -eq 'Primary' } | Sort-Object Bytes -Descending)
    if ($parts.Count -eq 0) {
        foreach ($l in $r.Output) { if ($l.Trim()) { Write-Log ('diskpart: ' + $l.Trim()) -Level Detail -FileOnly } }
        Stop-Tool 1 ('No Primary partition found on disk {0}.' -f $DiskNumber)
    }
    $best = $parts[0]
    $null = Invoke-DiskPart -Commands @(('select disk {0}' -f $DiskNumber), ('select partition {0}' -f $best.Num), ('assign letter={0}' -f $free)) -Validate {
        param($res) $null = $res; Test-Path -LiteralPath ($free + ':\')
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        $snap = @(Get-FixedDriveSnapshot | Where-Object { $_.Letter -eq $free })
        if ($snap.Count -gt 0) {
            Write-Log ('Assigned drive letter {0}: manually.' -f $free) -Level Ok
            return $snap
        }
        Start-Sleep -Milliseconds $script:PollMs
    }
    Stop-Tool 1 ('Letter {0}: assigned but the drive is not accessible.' -f $free)
}

function Get-AttachedDiskLetters {
    # Letters of an already-attached diff, via the Storage cmdlets.
    param([string]$DiffPath)
    $di = Get-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue
    if (-not $di -or $null -eq $di.Number) { return @() }
    @(Get-Partition -DiskNumber $di.Number -ErrorAction SilentlyContinue |
        ForEach-Object { [string]$_.DriveLetter } |
        Where-Object { $_ -match '^[A-Za-z]$' } |
        ForEach-Object { $_.ToUpperInvariant() })
}

function Test-BitLockerLocked {
    param([string]$Letter)
    $r = Invoke-Native -FilePath (Get-SystemTool 'manage-bde.exe') -ArgumentList @('-status', ($Letter + ':'))
    foreach ($l in $r.Output) { if ($l.Trim()) { Write-Log ('manage-bde: ' + $l.Trim()) -Level Detail -FileOnly } }
    return (($r.Output -join "`n") -match 'Lock Status:\s+Locked')
}

function Get-VolumeInfo {
    param([string[]]$Letters)
    foreach ($l in $Letters) {
        $root = $l + ':\'
        $size = 0L
        try { $size = ([IO.DriveInfo]$root).TotalSize } catch { $size = 0L }
        [pscustomobject]@{
            Letter      = $l
            Size        = $size
            HasSystem32 = Test-Path -LiteralPath ($root + 'Windows\System32')
            HasUsers    = Test-Path -LiteralPath ($root + 'Users')
        }
    }
}

# ------------------------------------------------------------
#  Permissions
# ------------------------------------------------------------

function Get-ExplorerOwnerSids {
    $session = (Get-Process -Id $PID).SessionId
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $session })
    foreach ($p in $procs) {
        try {
            $r = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
            if ($r.ReturnValue -eq 0 -and $r.Sid) { $r.Sid }
        } catch { $null = $_ }
    }
}

function Get-TargetSid {
    param([string]$OverrideSid)
    $explorer = @()
    if (-not $OverrideSid) { $explorer = @(Get-ExplorerOwnerSids) }
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return (Select-TargetSid -OverrideSid $OverrideSid -ExplorerSids $explorer -CurrentSid $current)
}

function Get-SidDisplayName {
    param([string]$Value)
    try {
        $s = New-Object Security.Principal.SecurityIdentifier($Value)
        return $s.Translate([Security.Principal.NTAccount]).Value
    } catch {
        return '(unresolved)'
    }
}

function Assert-OnDrive {
    param([string]$Path, [string]$DriveLetter)
    if (-not (Test-PathOnDrive -Path $Path -DriveLetter $DriveLetter)) {
        throw ('Refusing to touch a path outside the mounted volume: ' + $Path)
    }
}

function Test-IsReparsePoint {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        return $true
    }
}

function Invoke-Icacls {
    # One icacls call with /L (act on links, never their targets) and /C.
    # Returns Failures (-1 means unknown), ExitCode, ErrorLines.
    param(
        [string]$Path,
        [string[]]$Grants,
        [switch]$Recurse,
        [string]$DriveLetter
    )
    Assert-OnDrive -Path $Path -DriveLetter $DriveLetter
    $argList = @($Path, '/grant') + $Grants
    if ($Recurse) { $argList += '/T' }
    $argList += @('/C', '/L', '/Q')
    $r = Invoke-Native -FilePath (Get-SystemTool 'icacls.exe') -ArgumentList $argList
    $failed = Get-IcaclsFailureCount $r.Output
    if ($failed -lt 0) { if ($r.ExitCode -eq 0) { $failed = 0 } else { $failed = 1 } }
    [pscustomobject]@{
        Path       = $Path
        ExitCode   = $r.ExitCode
        Failures   = $failed
        ErrorLines = @(Get-IcaclsErrorLines $r.Output)
        Denied     = (($r.Output -join "`n") -match 'Access is denied') -or ($r.ExitCode -eq 5)
    }
}

function Invoke-GrantWithRetry {
    # Grant; on access denied take ownership for Administrators on that one
    # path (never /r) and retry once.
    param(
        [string]$Path,
        [string[]]$Grants,
        [switch]$Recurse,
        [string]$DriveLetter
    )
    $res = Invoke-Icacls -Path $Path -Grants $Grants -Recurse:$Recurse -DriveLetter $DriveLetter
    if ($res.Failures -gt 0 -and $res.Denied) {
        Assert-OnDrive -Path $Path -DriveLetter $DriveLetter
        $t = Invoke-Native -FilePath (Get-SystemTool 'takeown.exe') -ArgumentList @('/a', '/f', $Path)
        Write-Log ('takeown /a on {0} exit {1}' -f $Path, $t.ExitCode) -Level Detail -FileOnly
        $res = Invoke-Icacls -Path $Path -Grants $Grants -Recurse:$Recurse -DriveLetter $DriveLetter
    }
    foreach ($l in $res.ErrorLines) { Write-Log ('icacls: ' + $l) -Level Detail -FileOnly }
    return $res
}

function Test-HasAllSids {
    param([string]$Path, [string[]]$Sids)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    } catch {
        return $false
    }
    foreach ($s in $Sids) {
        $hit = $false
        foreach ($r in $rules) {
            if ($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Value -eq $s) { $hit = $true; break }
        }
        if (-not $hit) { return $false }
    }
    return $true
}

function Get-ChildDirectories {
    # Direct child directories that are not reparse points.
    param([string]$Path)
    @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
}

function Invoke-VerifyAndRepair {
    # Walks the first VerifyDepth levels below a profile root. Any directory
    # missing the ACE gets a recursive grant on that subtree only, and the
    # walk does not descend into it.
    param([string]$ProfilePath, [string[]]$Sids, [string[]]$Grants, [string]$DriveLetter)
    $failures = 0
    $repaired = 0
    $checked = 0
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ Path = $ProfilePath; Depth = 0 })
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $checked++
        if (-not (Test-PathOnDrive -Path $node.Path -DriveLetter $DriveLetter)) {
            Write-Log ('Skipped path outside the mounted volume: ' + $node.Path) -Level Warn
            continue
        }
        if (-not (Test-HasAllSids -Path $node.Path -Sids $Sids)) {
            $res = Invoke-GrantWithRetry -Path $node.Path -Grants $Grants -Recurse -DriveLetter $DriveLetter
            $repaired++
            if ($res.Failures -gt 0) {
                $failures += $res.Failures
                Write-Log ('Repair left {0} failure(s) under {1}' -f $res.Failures, $node.Path) -Level Warn -FileOnly
            }
            continue
        }
        if ($node.Depth -lt $script:VerifyDepth) {
            foreach ($c in (Get-ChildDirectories $node.Path)) {
                $queue.Enqueue([pscustomobject]@{ Path = $c.FullName; Depth = $node.Depth + 1 })
            }
        }
    }
    [pscustomobject]@{ Failures = $failures; Repaired = $repaired; Checked = $checked }
}

function Invoke-DeepGrant {
    # Recursive grant per profile, DeepParallel processes at a time.
    param([string[]]$Profiles, [string[]]$Grants, [string]$DriveLetter)
    $icacls = Get-SystemTool 'icacls.exe'
    $pending = New-Object System.Collections.Generic.Queue[string]
    foreach ($p in $Profiles) {
        Assert-OnDrive -Path $p -DriveLetter $DriveLetter
        $pending.Enqueue($p)
    }
    $running = New-Object System.Collections.Generic.List[object]
    $failures = 0
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $script:DeepParallel) {
            $path = $pending.Dequeue()
            $out = [IO.Path]::GetTempFileName()
            $err = [IO.Path]::GetTempFileName()
            # NTFS names cannot contain double quotes, so quoting is safe here.
            $argLine = '"' + $path + '" /grant ' + (($Grants | ForEach-Object { '"' + $_ + '"' }) -join ' ') + ' /T /C /L /Q'
            $proc = Start-Process -FilePath $icacls -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
            $null = $proc.Handle
            Write-Log ('Deep   : started ' + $path) -Level Detail
            $running.Add([pscustomobject]@{ Proc = $proc; Path = $path; Out = $out; Err = $err })
        }
        foreach ($job in @($running)) {
            if ($job.Proc.HasExited) {
                $job.Proc.WaitForExit()
                $lines = @()
                $lines += @(Get-Content -LiteralPath $job.Out -ErrorAction SilentlyContinue)
                $lines += @(Get-Content -LiteralPath $job.Err -ErrorAction SilentlyContinue)
                Remove-Item -LiteralPath $job.Out, $job.Err -Force -ErrorAction SilentlyContinue
                $f = Get-IcaclsFailureCount $lines
                if ($f -lt 0) { if ($job.Proc.ExitCode -eq 0) { $f = 0 } else { $f = 1 } }
                foreach ($l in (Get-IcaclsErrorLines $lines)) { Write-Log ('icacls: ' + $l) -Level Detail -FileOnly }
                $failures += $f
                if ($f -gt 0) { Write-Log ('Deep   : {0} failure(s) in {1}' -f $f, $job.Path) -Level Warn }
                else { Write-Log ('Deep   : done ' + $job.Path) -Level Ok }
                $null = $running.Remove($job)
            }
        }
        if ($running.Count -gt 0) { Start-Sleep -Milliseconds $script:PollMs }
    }
    return $failures
}

function Read-Marker {
    param([string]$Root)
    $path = Join-Path $Root $script:MarkerName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $json = [IO.File]::ReadAllText($path) } catch { return $null }
    return (ConvertFrom-MarkerJson $json)
}

function Write-Marker {
    param([string]$Root, [object]$Marker)
    $path = Join-Path $Root $script:MarkerName
    try {
        if (Test-Path -LiteralPath $path) {
            # .NET refuses to overwrite a Hidden file, so clear it first.
            [IO.File]::SetAttributes($path, [IO.FileAttributes]::Normal)
        }
        [IO.File]::WriteAllText($path, (ConvertTo-MarkerJson $Marker), [Text.Encoding]::ASCII)
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::Hidden)
        return $true
    } catch {
        Write-Log ('Could not write the state marker: ' + $_.Exception.Message) -Level Warn
        return $false
    }
}

function Invoke-PermissionPass {
    param(
        [string]$DriveLetter,
        [string]$TargetSid,
        [string]$ImagePath,
        [string]$AccessLevel,
        [bool]$AllUsers,
        [bool]$DeepMode
    )
    $sids = @($TargetSid)
    if ($AllUsers) { $sids += $script:AllUsersSid }
    $grants = Get-GrantArguments -Sids $sids -Access $AccessLevel

    $marker = Read-Marker -Root ($DriveLetter + ':\')
    if (-not $DeepMode -and (Test-MarkerComplete -Marker $marker -Sids $sids -Access $AccessLevel)) {
        Write-Log 'Perms  : already granted for this user on this diff, skipping.' -Level Detail
        return 0
    }

    $usersPath = $DriveLetter + ':\Users'
    $totalFailures = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if (-not (Test-Path -LiteralPath $usersPath)) {
        Write-Log ('No \Users folder on ' + $DriveLetter + ':, nothing to unlock.') -Level Warn
    } elseif (Test-IsReparsePoint $usersPath) {
        Write-Log ($usersPath + ' is a link, refusing to change it.') -Level Warn
        $totalFailures++
    } else {
        Write-Log 'Perms  : unlocking profile folders (first mount for this user may take a moment)...' -Level Info
        $res = Invoke-GrantWithRetry -Path $usersPath -Grants $grants -DriveLetter $DriveLetter
        $totalFailures += $res.Failures
        $profiles = @(Get-ChildDirectories $usersPath | ForEach-Object { $_.FullName })

        if ($DeepMode) {
            foreach ($p in $profiles) {
                $r = Invoke-GrantWithRetry -Path $p -Grants $grants -DriveLetter $DriveLetter
                $totalFailures += $r.Failures
            }
            Write-Log ('Deep   : recursive grant over {0} profile(s), {1} at a time.' -f $profiles.Count, $script:DeepParallel) -Level Info
            $totalFailures += (Invoke-DeepGrant -Profiles $profiles -Grants $grants -DriveLetter $DriveLetter)
        } else {
            foreach ($p in $profiles) {
                $name = [IO.Path]::GetFileName($p)
                $r = Invoke-GrantWithRetry -Path $p -Grants $grants -DriveLetter $DriveLetter
                $v = Invoke-VerifyAndRepair -ProfilePath $p -Sids $sids -Grants $grants -DriveLetter $DriveLetter
                $f = $r.Failures + $v.Failures
                $totalFailures += $f
                if ($f -gt 0) {
                    Write-Log ('  {0}: {1} failure(s), {2} subtree(s) repaired' -f $name, $f, $v.Repaired) -Level Warn
                } else {
                    Write-Log ('  {0}: ok ({1} folders checked, {2} subtree(s) repaired)' -f $name, $v.Checked, $v.Repaired) -Level Ok
                }
            }
        }
    }

    Write-Log ('Perms  : finished in {0:N1} s, {1} failure(s).' -f $sw.Elapsed.TotalSeconds, $totalFailures) -Level Detail

    $parent = Get-Item -LiteralPath $ImagePath -Force
    if (-not $marker) { $marker = New-Marker -Version $ScriptVersion -ParentSize $parent.Length -ParentLastWriteUtc $parent.LastWriteTimeUtc }
    $marker.scriptVersion = $ScriptVersion
    $marker.parentSize = $parent.Length
    $marker.parentLastWriteUtc = $parent.LastWriteTimeUtc.ToString('o')
    $marker.failureCount = $totalFailures
    $now = Get-Date
    foreach ($s in $sids) {
        $marker = Set-MarkerGrant -Marker $marker -Sid $s -Access $AccessLevel -Complete ($totalFailures -eq 0) -Failures $totalFailures -Machine $env:COMPUTERNAME -When $now
    }
    $null = Write-Marker -Root ($DriveLetter + ':\') -Marker $marker
    return $totalFailures
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------

function Invoke-ClearReadOnly {
    param([string]$ImagePath, [string]$DiffPath)
    try {
        Set-ItemProperty -LiteralPath $ImagePath -Name IsReadOnly -Value $false -ErrorAction Stop
        Write-Log 'Parent : read-only flag cleared.' -Level Ok
        if (Test-Path -LiteralPath $DiffPath) {
            Write-Log 'Any write to the parent breaks the existing diff. Run with -Reset afterwards if you change it.' -Level Warn
        }
    } catch {
        Stop-Tool 1 ('Could not clear read-only: ' + $_.Exception.Message)
    }
}

function Mount-Image {
    param([string]$ImagePath, [string]$DiffPath)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $before = @(Get-FixedDriveSnapshot | ForEach-Object { $_.Letter })
    $created = $false

    Protect-ParentImage $ImagePath

    if (-not (Test-Path -LiteralPath $DiffPath)) {
        Write-Log 'Status : First run, creating differencing disk...' -Level Info
        if (-not (New-DiffDisk -ImagePath $ImagePath -DiffPath $DiffPath)) {
            Stop-Tool 1 'Could not create a differencing disk. Enabling Hyper-V Management Tools in Windows Features gives a second method.'
        }
        $created = $true
    } else {
        Write-Log 'Diff   : existing diff found.' -Level Detail
    }

    Write-Log 'Status : Mounting...' -Level Info
    try {
        Mount-DiskImage -ImagePath $DiffPath -ErrorAction Stop | Out-Null
    } catch {
        $msg = $_.Exception.Message
        if ($created) {
            Remove-Item -LiteralPath $DiffPath -Force -ErrorAction SilentlyContinue
            Stop-Tool 1 ('Failed to mount: ' + $msg)
        }
        if ($msg -match 'parent|mismatch|chain') {
            Write-Log ('Mount error: ' + $msg) -Level Detail -FileOnly
            Stop-Tool 1 'The image changed since this diff was created. Run with -Reset.'
        }
        Stop-Tool 1 ('Failed to mount: ' + $msg + ' If the image was modified, run with -Reset.')
    }

    $diskNumber = Wait-DiskAttach $DiffPath
    if ($null -eq $diskNumber) {
        Dismount-DiskImage -ImagePath $DiffPath -ErrorAction SilentlyContinue | Out-Null
        Stop-Tool 1 'Disk did not attach within the expected time.'
    }
    Write-Log ('Disk   : attached as disk {0}.' -f $diskNumber) -Level Detail

    Repair-DiskOnline $diskNumber

    $new = @(Wait-NewDrives -Before $before)
    if ($new.Count -eq 0) {
        Write-Log 'No letter auto-assigned, assigning one with diskpart...' -Level Warn
        $new = @(Add-LetterWithDiskPart $diskNumber)
    }
    Write-Log ('Mount  : {0:N1} s' -f $sw.Elapsed.TotalSeconds) -Level Detail -FileOnly
    return $new
}

function Resolve-TargetLetter {
    param([object[]]$NewDrives)
    $notReady = @($NewDrives | Where-Object { -not $_.Ready })
    foreach ($d in $notReady) {
        if (Test-BitLockerLocked $d.Letter) {
            Write-Log ('Volume {0}: is BitLocker-locked.' -f $d.Letter) -Level Error
            Write-Host ''
            Write-Host (' Unlock it first: double-click {0}: in Explorer and enter the password or recovery key,' -f $d.Letter) -ForegroundColor Yellow
            Write-Host ('   or run: manage-bde -unlock {0}: -RecoveryPassword <48-digit key>' -f $d.Letter) -ForegroundColor Yellow
            Write-Host ' Then run VHDOneClick again with -Mount to finish setup.' -ForegroundColor Yellow
            Stop-Tool 3
        }
        Write-Log ('Volume {0}: appeared but is not ready.' -f $d.Letter) -Level Warn
    }
    $ready = @($NewDrives | Where-Object { $_.Ready } | ForEach-Object { $_.Letter })
    if ($ready.Count -eq 0) { Stop-Tool 1 'No readable volume appeared on the mounted image.' }

    $info = @(Get-VolumeInfo $ready)
    foreach ($v in $info) {
        Write-Log ('Volume {0}: {1:N1} GB{2}{3}' -f $v.Letter, ($v.Size / 1GB), ($(if ($v.HasSystem32) { ', Windows' } else { '' })), ($(if ($v.HasUsers) { ', Users' } else { '' }))) -Level Detail
    }
    $pick = Select-TargetVolume $info
    Write-Log ('Target : {0}: ({1})' -f $pick.Volume.Letter, $pick.Reason) -Level Info
    return $pick.Volume
}

function Invoke-Main {
    $ErrorActionPreference = 'Stop'

    if ($ShowVersion) {
        Write-Host ('VHDOneClick ' + $ScriptVersion)
        return
    }

    if ($Mount -and $Unmount) { Stop-Tool 1 '-Mount and -Unmount cannot be used together.' }
    if ($Reset -and $Unmount) { Stop-Tool 1 '-Reset and -Unmount cannot be used together.' }
    if ($ClearReadOnly -and ($Mount -or $Reset)) { Stop-Tool 1 '-ClearReadOnly runs on its own. Do not combine it with -Mount or -Reset.' }
    if ($Sid -and -not (Test-SidString $Sid)) { Stop-Tool 1 ('Not a valid SID: ' + $Sid) }

    if (-not (Test-IsAdmin)) {
        Stop-Tool 1 'Administrator rights are required to mount disk images. Run as administrator.'
    }

    Write-Host ''
    Write-Log ('VHDOneClick ' + $ScriptVersion) -Level Detail
    $base = Get-BaseFolder -ScriptRoot $script:LoadScriptRoot
    $imagePath = Resolve-ImagePath -ImageArg $Image -BaseFolder $base
    $diffPath = Get-DiffPath $imagePath
    Initialize-Log $imagePath
    Write-Log ('Image  : ' + $imagePath) -Level Info
    Write-Log ('Diff   : ' + $diffPath) -Level Detail

    $legacySentinel = $diffPath + '.perms_done'
    $legacyDiff = [IO.Path]::Combine([IO.Path]::GetDirectoryName($imagePath), [IO.Path]::GetFileNameWithoutExtension($imagePath) + '.diff.vhdx')
    if (Test-Path -LiteralPath $legacySentinel) {
        Write-Log ('Found an old v1 sentinel ({0}). It is no longer used and can be deleted.' -f [IO.Path]::GetFileName($legacySentinel)) -Level Detail
    }

    if ($ClearReadOnly) {
        Invoke-ClearReadOnly -ImagePath $imagePath -DiffPath $diffPath
        return
    }

    $attached = Get-DiffAttached $diffPath

    if ($Unmount -or (-not $Mount -and -not $Reset -and $attached)) {
        if (-not $attached) {
            Write-Log 'Status : not mounted, nothing to do.' -Level Ok
            return
        }
        Write-Log 'Status : Mounted -> Unmounting...' -Level Info
        Dismount-Diff $diffPath
        return
    }

    if ($Reset) {
        if ($attached) {
            Write-Log 'Reset  : unmounting...' -Level Info
            Dismount-Diff $diffPath
            $attached = $false
        }
        if (Test-Path -LiteralPath $diffPath) {
            try {
                Remove-Item -LiteralPath $diffPath -Force -ErrorAction Stop
                Write-Log 'Reset  : diff deleted, a fresh one will be created.' -Level Info
            } catch {
                Stop-Tool 1 ('Could not delete the diff: ' + $_.Exception.Message)
            }
        }
    }

    if ($diffPath -ne $legacyDiff -and (Test-Path -LiteralPath $legacyDiff)) {
        Write-Log ('An old {0} from v1 sits next to this .vhd. v2 uses {1}. Delete the old one when you no longer need it.' -f [IO.Path]::GetFileName($legacyDiff), [IO.Path]::GetFileName($diffPath)) -Level Warn
    }

    if ($attached) {
        Write-Log 'Status : already mounted, checking permissions.' -Level Info
        $letters = @(Get-AttachedDiskLetters $diffPath)
        if ($letters.Count -eq 0) {
            Stop-Tool 1 'The diff is mounted but its drive letters could not be read. Unmount it and run again.'
        }
        $newDrives = @(Get-FixedDriveSnapshot | Where-Object { $letters -contains $_.Letter })
    } else {
        $newDrives = @(Mount-Image -ImagePath $imagePath -DiffPath $diffPath)
    }

    $target = Resolve-TargetLetter $newDrives
    $letter = $target.Letter

    $sidPick = Get-TargetSid -OverrideSid $Sid
    Write-Log ('User   : {0} {1} (from {2})' -f $sidPick.Sid, (Get-SidDisplayName $sidPick.Sid), $sidPick.Source) -Level Detail

    $failures = Invoke-PermissionPass -DriveLetter $letter -TargetSid $sidPick.Sid -ImagePath $imagePath -AccessLevel $Access -AllUsers ([bool]$GrantAllUsers) -DeepMode ([bool]$Deep)

    $root = $letter + ':\'
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $root
    } catch {
        Write-Log ('Could not open Explorer: ' + $_.Exception.Message) -Level Warn
    }

    Write-Host ''
    Write-Log ('Opened : {0} ({1:N1} GB)' -f $root, ($target.Size / 1GB)) -Level Ok
    if ($failures -gt 0) {
        Write-Log ('{0} permission failure(s). Some folders may still prompt. The next mount retries. Details in the log.' -f $failures) -Level Warn
        $script:ExitCode = 2
        Wait-OnError
        return
    }
    Write-Log 'Done. Run VHDOneClick again to unmount.' -Level Detail
}

function Main {
    try {
        Invoke-Main | Out-Null
        if ($script:ExitCode -eq 0) { Wait-OnSuccess }
    } catch {
        if ("$_" -ne 'VHDOneClick.Stop') {
            Write-Log ('Unexpected error: ' + $_.Exception.Message) -Level Error
            Write-Log ($_.ScriptStackTrace) -Level Detail -FileOnly
            $script:ExitCode = 1
        }
        if ($script:ExitCode -ne 0) { Wait-OnError }
    }
    if ($script:LogFile -and $script:ExitCode -ne 0) {
        Write-Host (' Log    : ' + $script:LogFile) -ForegroundColor DarkGray
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
    exit $script:ExitCode
}
