# Changes

2026.11.11 - Backend overhaul / Security patches

* Permission pass now grants the interactive user's SID (owner of explorer.exe in the session) on each profile root, instead of re-granting BUILTIN\Administrators, which Explorer cannot use while non-elevated
* Verify-and-repair walk over the first three levels of each profile, with a recursive grant only on subtrees that have protected ACLs; takeown /a on one folder and one retry on access denied
* -Deep runs the full recursive grant, four profiles at a time
* Every icacls call passes /L, enumeration skips reparse points, takeown never recurses, and any path outside the mounted drive is refused, so junctions can no longer redirect ACL changes onto the host
* icacls output and exit codes are captured and parsed; failures leave the user marked incomplete so the next mount retries
* Completion state moved from a sidecar .perms_done file into a hidden X:\.vhdoneclick.json inside the diff, tracked per SID, so a new diff or a new machine reruns the pass
* Parent image is set read-only before the diff is created or attached; -ClearReadOnly undoes it
* Logs written to VHDOneClick-logs next to the image, 10 newest kept, %TEMP% fallback
* Image selection prompts when a folder has more than one image instead of silently picking the largest; -Image picks directly
* .vhd parents get a .diff.vhd diff
* Target volume is the one with \Windows\System32, then \Users, then the largest
* Signature collisions (mounting on the source machine) get a new disk GUID or signature on the diff; offline and read-only disks are brought online
* Locked BitLocker volumes print an unlock hint
* Polling every 200 ms instead of 1 s sleeps; fixed the drive-letter fallback ($_[0] on DriveInfo) and added TB to the diskpart size parser
* diskpart commands go over stdin, with a create-new file under %SystemRoot%\Temp as fallback
* System tools run from System32 by full path
* New parameters: -Image, -Mount, -Unmount, -Reset, -GrantAllUsers, -Access, -Deep, -ClearReadOnly, -Sid, -ShowVersion
* Batch launcher uses fltmc for the admin check and passes arguments through
* Script restructured into functions with a guarded Main so Pester can test it
* Release exe is now a PS2EXE build that embeds the script, replacing the WinRAR SFX
* GitHub Actions: ci.yml (hygiene, PSScriptAnalyzer, Pester, test build) and release.yml (tag build, integration test, optional SignPath signing, SHA256SUMS, provenance attestation, release notes from git log since the previous tag)
* Added tests, tools, .gitattributes, maintenance.md, changes.md; README rewritten

Reasons for changes: the permission step did not work, since Explorer runs non-elevated and the Administrators grant was a no-op. The old recursive takeown and icacls could follow junctions onto the host's own C:\Users. The sidecar sentinel skipped the fix after a diff was deleted or carried to another machine. Releases were hand-built.

2026.04.27 - Initial release (v1.0.0 to v1.2.0)

* Mount toggle with a differencing disk, largest-volume selection, diskpart drive-letter fallback
* takeown and icacls over X:\Users with a .perms_done sentinel
* WinRAR SFX exe
* README, GPL-3.0 license, .gitignore

Reasons for changes: first version, for handing Macrium backups to people who need files off them.
