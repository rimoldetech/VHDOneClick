# Pester 5 unit tests for the pure functions in VHDOneClick-Main.ps1.
# Run on Windows (SID and path functions use Windows-only .NET APIs):
#   Invoke-Pester -Path tests

BeforeAll {
    . (Join-Path $PSScriptRoot '..\VHDOneClick-Main.ps1')
}

Describe 'Get-BaseFolder' {
    It 'uses the script root when it is set' {
        Get-BaseFolder -ScriptRoot 'D:\Images' -ProcessPath 'C:\Tools\VHDOneClick.exe' | Should -Be 'D:\Images'
    }
    It 'falls back to the exe folder when the script root is empty (PS2EXE)' {
        Get-BaseFolder -ScriptRoot '' -ProcessPath 'C:\Tools\VHDOneClick.exe' | Should -Be 'C:\Tools'
    }
    It 'falls back to the current process when nothing is passed' {
        $expected = [IO.Path]::GetDirectoryName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        Get-BaseFolder -ScriptRoot '' | Should -Be $expected
    }
}

Describe 'Image names' {
    It 'keeps the parent format for the diff' {
        Get-DiffPath 'D:\img\backup.vhdx' | Should -Be 'D:\img\backup.diff.vhdx'
        Get-DiffPath 'D:\img\backup.vhd'  | Should -Be 'D:\img\backup.diff.vhd'
    }
    It 'treats diffs as non-images' {
        Test-IsImageName 'backup.diff.vhdx' | Should -BeFalse
        Test-IsImageName 'backup.DIFF.VHD'  | Should -BeFalse
        Test-IsImageName 'backup.vhdx'      | Should -BeTrue
        Test-IsImageName 'backup.vhd'       | Should -BeTrue
        Test-IsImageName 'backup.iso'       | Should -BeFalse
    }
    It 'finds candidates in a folder and skips diffs' {
        foreach ($n in 'a.vhdx', 'a.diff.vhdx', 'b.vhd', 'b.diff.vhd', 'notes.txt') {
            Set-Content -LiteralPath (Join-Path $TestDrive $n) -Value 'x'
        }
        $names = @(Get-ImageCandidates $TestDrive | ForEach-Object { $_.Name })
        $names | Should -Be @('a.vhdx', 'b.vhd')
    }
}

Describe 'Select-TargetVolume' {
    It 'prefers the Windows volume over a bigger data volume' {
        $v = @(
            [pscustomobject]@{ Letter = 'E'; Size = 2TB;   HasSystem32 = $false; HasUsers = $false },
            [pscustomobject]@{ Letter = 'F'; Size = 200GB; HasSystem32 = $true;  HasUsers = $true }
        )
        (Select-TargetVolume $v).Volume.Letter | Should -Be 'F'
    }
    It 'falls back to a volume with Users' {
        $v = @(
            [pscustomobject]@{ Letter = 'E'; Size = 2TB;   HasSystem32 = $false; HasUsers = $false },
            [pscustomobject]@{ Letter = 'F'; Size = 200GB; HasSystem32 = $false; HasUsers = $true }
        )
        (Select-TargetVolume $v).Volume.Letter | Should -Be 'F'
    }
    It 'falls back to the largest' {
        $v = @(
            [pscustomobject]@{ Letter = 'E'; Size = 2TB;   HasSystem32 = $false; HasUsers = $false },
            [pscustomobject]@{ Letter = 'F'; Size = 200GB; HasSystem32 = $false; HasUsers = $false }
        )
        (Select-TargetVolume $v).Volume.Letter | Should -Be 'E'
    }
    It 'returns null for no volumes' {
        Select-TargetVolume @() | Should -BeNullOrEmpty
    }
}

Describe 'SID selection' {
    It 'uses the override first' {
        (Select-TargetSid -OverrideSid 'S-1-5-21-1-2-3-1001' -ExplorerSids @('S-1-5-21-9-9-9-1001') -CurrentSid 'S-1-5-21-9-9-9-500').Sid |
            Should -Be 'S-1-5-21-1-2-3-1001'
    }
    It 'uses the explorer owner next' {
        $r = Select-TargetSid -ExplorerSids @('S-1-5-21-9-9-9-1001') -CurrentSid 'S-1-5-21-9-9-9-500'
        $r.Sid | Should -Be 'S-1-5-21-9-9-9-1001'
        $r.Source | Should -Be 'explorer.exe owner'
    }
    It 'falls back to the current token' {
        (Select-TargetSid -ExplorerSids @() -CurrentSid 'S-1-5-21-9-9-9-500').Sid | Should -Be 'S-1-5-21-9-9-9-500'
    }
    It 'Get-TargetSid reads explorer owners through the mockable helper' {
        Mock Get-ExplorerOwnerSids { 'S-1-5-21-4-4-4-1001' }
        (Get-TargetSid).Sid | Should -Be 'S-1-5-21-4-4-4-1001'
    }
    It 'Get-TargetSid skips explorer lookup when overridden' {
        Mock Get-ExplorerOwnerSids { throw 'should not be called' }
        (Get-TargetSid -OverrideSid 'S-1-5-21-1-1-1-1001').Sid | Should -Be 'S-1-5-21-1-1-1-1001'
    }
    It 'validates SID strings' {
        Test-SidString 'S-1-5-21-2622925689-1543212673-3818942365-1001' | Should -BeTrue
        Test-SidString 'S-1-5-32-545' | Should -BeTrue
        Test-SidString 'S-1-5-21;calc' | Should -BeFalse
        Test-SidString 'nathan' | Should -BeFalse
    }
    It 'builds icacls grant arguments' {
        Get-GrantArguments -Sids @('S-1-5-21-1-2-3-1001', 'S-1-5-32-545') -Access 'M' |
            Should -Be @('*S-1-5-21-1-2-3-1001:(OI)(CI)M', '*S-1-5-32-545:(OI)(CI)M')
    }
}

Describe 'Path guard' {
    It 'accepts paths on the mounted drive' {
        Test-PathOnDrive 'G:\Users\pawna' 'G' | Should -BeTrue
        Test-PathOnDrive 'g:\Users' 'G' | Should -BeTrue
    }
    It 'rejects host and UNC paths' {
        Test-PathOnDrive 'C:\Users\pawna' 'G' | Should -BeFalse
        Test-PathOnDrive '\\?\C:\Users' 'G' | Should -BeFalse
        Test-PathOnDrive '\\server\share' 'G' | Should -BeFalse
        Test-PathOnDrive '' 'G' | Should -BeFalse
    }
    It 'Invoke-Icacls refuses host paths before running anything' {
        Mock Invoke-Native { throw 'icacls must not run' }
        { Invoke-Icacls -Path 'C:\Users\nathan' -Grants @('*S-1-5-21-1-2-3-1001:(OI)(CI)F') -DriveLetter 'G' } |
            Should -Throw '*outside the mounted volume*'
    }
}

Describe 'diskpart and icacls parsing' {
    It 'parses partition sizes including TB' {
        $lines = @(
            '  Partition ###  Type              Size     Offset',
            '  -------------  ----------------  -------  -------',
            '  Partition 1    System             100 MB  1024 KB',
            '  Partition 2    Reserved            16 MB   101 MB',
            '  Partition 3    Primary           1863 GB   117 MB',
            '  Partition 4    Primary              2 TB  1863 GB'
        )
        $p = @(ConvertFrom-DiskPartPartitionList $lines)
        $p.Count | Should -Be 4
        ($p | Where-Object Num -eq 4).Bytes | Should -Be (2 * 1TB)
        ($p | Where-Object Type -eq 'Primary' | Sort-Object Bytes -Descending | Select-Object -First 1).Num | Should -Be 4
    }
    It 'reads the icacls failure count' {
        Get-IcaclsFailureCount @('G:\x: Access is denied.', 'Successfully processed 10 files; Failed processing 3 files') | Should -Be 3
        Get-IcaclsFailureCount @('Successfully processed 10 files; Failed processing 0 files') | Should -Be 0
        Get-IcaclsFailureCount @('Erfolgreich verarbeitet: 10 Dateien') | Should -Be -1
    }
    It 'keeps only error lines' {
        $e = Get-IcaclsErrorLines @('G:\x: Access is denied.', '', 'Successfully processed 1 files; Failed processing 1 files')
        $e | Should -Be @('G:\x: Access is denied.')
    }
}

Describe 'State marker' {
    It 'round-trips through JSON and reports completion per SID' {
        $m = New-Marker -Version '2.0.0' -ParentSize 1234 -ParentLastWriteUtc ([datetime]'2026-01-01T00:00:00Z')
        $m = Set-MarkerGrant -Marker $m -Sid 'S-1-5-21-1-2-3-1001' -Access 'F' -Complete $true -Failures 0 -Machine 'BENCH' -When (Get-Date)
        $back = ConvertFrom-MarkerJson (ConvertTo-MarkerJson $m)
        $back.parentSize | Should -Be 1234
        Test-MarkerComplete -Marker $back -Sids @('S-1-5-21-1-2-3-1001') -Access 'F' | Should -BeTrue
        Test-MarkerComplete -Marker $back -Sids @('S-1-5-21-1-2-3-1001') -Access 'M' | Should -BeFalse
        Test-MarkerComplete -Marker $back -Sids @('S-1-5-21-9-9-9-1001') -Access 'F' | Should -BeFalse
        Test-MarkerComplete -Marker $back -Sids @('S-1-5-21-1-2-3-1001', 'S-1-5-32-545') -Access 'F' | Should -BeFalse
    }
    It 'keeps earlier users when a new one is added (diff carried to another machine)' {
        $m = New-Marker -Version '2.0.0' -ParentSize 1 -ParentLastWriteUtc (Get-Date)
        $m = Set-MarkerGrant -Marker $m -Sid 'S-1-5-21-1-1-1-1001' -Access 'F' -Complete $true -Failures 0 -Machine 'A' -When (Get-Date)
        $m = Set-MarkerGrant -Marker $m -Sid 'S-1-5-21-2-2-2-1001' -Access 'F' -Complete $true -Failures 0 -Machine 'B' -When (Get-Date)
        $back = ConvertFrom-MarkerJson (ConvertTo-MarkerJson $m)
        @($back.grants).Count | Should -Be 2
    }
    It 'an incomplete run is not complete' {
        $m = New-Marker -Version '2.0.0' -ParentSize 1 -ParentLastWriteUtc (Get-Date)
        $m = Set-MarkerGrant -Marker $m -Sid 'S-1-5-21-1-1-1-1001' -Access 'F' -Complete $false -Failures 4 -Machine 'A' -When (Get-Date)
        Test-MarkerComplete -Marker (ConvertFrom-MarkerJson (ConvertTo-MarkerJson $m)) -Sids @('S-1-5-21-1-1-1-1001') -Access 'F' | Should -BeFalse
    }
    It 'ignores garbage and wrong schemas' {
        ConvertFrom-MarkerJson 'not json' | Should -BeNullOrEmpty
        ConvertFrom-MarkerJson '{"schema":99,"grants":[]}' | Should -BeNullOrEmpty
        $m = ConvertFrom-MarkerJson '{"schema":1,"grants":[{"sid":"bogus","access":"F","complete":true}]}'
        @($m.grants).Count | Should -Be 0
    }
    It 'writes a hidden file and can overwrite it' {
        $m = New-Marker -Version '2.0.0' -ParentSize 1 -ParentLastWriteUtc (Get-Date)
        Write-Marker -Root $TestDrive -Marker $m | Should -BeTrue
        $path = Join-Path $TestDrive '.vhdoneclick.json'
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::Hidden) | Should -Be ([IO.FileAttributes]::Hidden)
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::System) | Should -Be 0
        $m = Set-MarkerGrant -Marker $m -Sid 'S-1-5-21-1-1-1-1001' -Access 'F' -Complete $true -Failures 0 -Machine 'A' -When (Get-Date)
        Write-Marker -Root $TestDrive -Marker $m | Should -BeTrue
        Test-MarkerComplete -Marker (Read-Marker -Root $TestDrive) -Sids @('S-1-5-21-1-1-1-1001') -Access 'F' | Should -BeTrue
    }
}

Describe 'Log rotation' {
    It 'removes everything beyond the newest 10' {
        $now = Get-Date
        $files = 1..13 | ForEach-Object {
            [pscustomobject]@{ Name = "log$_"; LastWriteTimeUtc = $now.AddMinutes(-$_) }
        }
        $gone = @(Get-LogsToRemove -Files $files -Keep 10)
        $gone.Count | Should -Be 3
        ($gone | ForEach-Object Name) | Should -Be @('log11', 'log12', 'log13')
    }
    It 'removes nothing when under the limit' {
        @(Get-LogsToRemove -Files @([pscustomobject]@{ Name = 'a'; LastWriteTimeUtc = Get-Date }) -Keep 10).Count | Should -Be 0
    }
    It 'writes logs next to the image and rotates them' {
        $img = Join-Path $TestDrive 'disk.vhdx'
        Set-Content -LiteralPath $img -Value 'x'
        $folder = Join-Path $TestDrive 'VHDOneClick-logs'
        $null = New-Item -ItemType Directory -Path $folder -Force
        1..12 | ForEach-Object {
            $f = Join-Path $folder ('disk-2026010{0:D2}-000000.log' -f $_)
            Set-Content -LiteralPath $f -Value 'old'
            (Get-Item -LiteralPath $f).LastWriteTimeUtc = (Get-Date).AddDays(-$_)
        }
        $script:LogFile = $null
        Initialize-Log $img
        $script:LogFile | Should -Match 'VHDOneClick-logs'
        @(Get-ChildItem -LiteralPath $folder -Filter 'disk-*.log').Count | Should -Be 10
        $script:LogFile = $null
    }
}

Describe 'Version helpers' {
    It 'turns a tag version into a four-part file version' {
        Get-ReleaseVersionNumber '2.0.0' | Should -Be '2.0.0.0'
        Get-ReleaseVersionNumber '2.1.0-rc1' | Should -Be '2.1.0.0'
        Get-ReleaseVersionNumber '2.0.0-dev' | Should -Be '2.0.0.0'
    }
}

Describe 'Release notes' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\New-ReleaseNotes.ps1')
    }
    It 'picks the previous stable tag for a stable release' {
        Get-PreviousTag -SortedTags @('v2.0.0', 'v2.0.0-rc2', 'v2.0.0-rc1', 'v1.2.0', 'v1.1.0') -Current 'v2.0.0' | Should -Be 'v1.2.0'
    }
    It 'lets a pre-release compare against the previous pre-release' {
        Get-PreviousTag -SortedTags @('v2.0.0-rc2', 'v2.0.0-rc1', 'v1.2.0') -Current 'v2.0.0-rc2' | Should -Be 'v2.0.0-rc1'
    }
    It 'returns null on the first tag' {
        Get-PreviousTag -SortedTags @('v1.0.0') -Current 'v1.0.0' | Should -BeNullOrEmpty
    }
    It 'groups commits and drops docs/ci/chore' {
        $commits = @(
            [pscustomobject]@{ Hash = 'a1'; Subject = 'fix: grant user SID' },
            [pscustomobject]@{ Hash = 'b2'; Subject = 'security(perm): pass /L' },
            [pscustomobject]@{ Hash = 'c3'; Subject = 'docs: readme' },
            [pscustomobject]@{ Hash = 'd4'; Subject = 'Refactor drive mounting' }
        )
        $n = ConvertTo-ReleaseNotes -Commits $commits -Tag 'v2.0.0' -PreviousTag 'v1.2.0' -Repository 'o/r' -Signed $true
        $n | Should -Match '### Fixes'
        $n | Should -Match '### Security'
        $n | Should -Match '### Other'
        $n | Should -Not -Match 'docs: readme'
        $n | Should -Match 'compare/v1.2.0...v2.0.0'
        $n | Should -Not -Match 'unsigned'
    }
    It 'keeps dropped types when they are all there is' {
        $n = ConvertTo-ReleaseNotes -Commits @([pscustomobject]@{ Hash = 'c3'; Subject = 'docs: readme' }) -Tag 'v2.0.1' -PreviousTag 'v2.0.0' -Repository 'o/r' -Signed $false
        $n | Should -Match 'docs: readme'
        $n | Should -Match 'unsigned'
    }
}
