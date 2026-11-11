# VHDOneClick

VHDOneClick mounts a VHD/VHDX disk image, usually a converted Macrium Reflect full-disk backup, and opens it in Explorer with the user folders unlocked, for anyone handing a backup to someone who needs files off it.

Double-click to mount. Double-click again to unmount.

The original image is never written. Everything goes into a differencing disk next to it.

## What it does

- Creates a differencing disk (`<image>.diff.vhdx`, or `.diff.vhd` for a `.vhd`) and mounts that instead of the image.
- Finds the right volume: the one with `\Windows\System32`, else one with `\Users`, else the largest.
- Grants the person at the keyboard access to every profile under `\Users`, so Explorer opens them without the "You don't currently have permission" prompt.
- Assigns a drive letter itself if Windows does not.
- Sets the image file read-only so it does not get edited by accident.
- Writes a log next to the image every run.

## Prerequisites

- Windows 10 or Windows 11
- Windows PowerShell 5.1, which ships with Windows
- Administrator rights, since Windows only lets admins mount disk images

## Usage

### The exe (recommended)

1. Download `VHDOneClick.exe` from the latest release and check it against `SHA256SUMS.txt` (see "Verifying a download" below).
2. Put `VHDOneClick.exe` in the same folder as the `.vhd` or `.vhdx`.
3. Double-click it and accept the UAC prompt.
4. If the folder has more than one image, pick one from the numbered list.
5. Explorer opens on the image's main volume once everything is finished. The first mount for a user takes longer, since that is when access gets granted.
6. Double-click it again to unmount.

### The scripts

For people who will not run an unsigned exe, `VHDOneClick-scripts.zip` on each release has the same logic as plain files.

1. Unzip `VHDOneClick-Entrypoint.bat` and `VHDOneClick-Main.ps1` into the image folder.
2. Right-click `VHDOneClick-Entrypoint.bat` and choose **Run as administrator**.
3. Everything else works the same as the exe. Parameters go after the batch file name: `VHDOneClick-Entrypoint.bat -Deep`.

Or from an elevated PowerShell, wherever the script is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\VHDOneClick-Main.ps1 -Image D:\Backups\laptop.vhdx
```

## Parameters

No parameters is the normal path: mount if unmounted, unmount if mounted.

| Parameter | What it does |
|---|---|
| `-Image <path>` | Use this image instead of scanning the tool's folder. |
| `-Mount` | Mount only. If already mounted, re-check permissions and open Explorer. |
| `-Unmount` | Unmount only. |
| `-Reset` | Unmount, delete the diff, create a fresh one and mount it. Use after the image file changed. |
| `-GrantAllUsers` | Also grant `BUILTIN\Users`, for shared bench machines where several accounts need in. |
| `-Access F\|M\|RX` | Access level granted. Default `F` (full), since writes land in a throwaway diff. |
| `-Deep` | Recursive grant over every file in every profile, four profiles at a time. Slower, for when you want certainty. |
| `-ClearReadOnly` | Clear the read-only flag the tool set on the image, then exit. |
| `-Sid <SID>` | Grant this SID instead of the detected user. Mostly for testing. |
| `-ShowVersion` | Print the version and exit. |

Examples with the exe, from an elevated prompt:

```
VHDOneClick.exe -Image E:\client\backup.vhdx
VHDOneClick.exe -Reset
VHDOneClick.exe -Mount -GrantAllUsers -Access RX
```

PS2EXE reserves `-?`, `-debug`, `-extract`, `-wait` and `-end` on the exe itself. None of the tool's parameters collide with them.

Exit codes: `0` success, `1` error, `2` mounted but some permissions failed, `3` the volume is BitLocker-locked.

## How it works

**Differencing disk.** All writes, permission changes included, land in `<image>.diff.vhdx`. The diff is kept between runs, so later mounts are fast. Delete it any time; the next run makes a new one and redoes the permission pass.

**Which user gets access.** The tool finds `explorer.exe` in its own session and grants its owner. That is right when a standard user elevates with a separate admin account: the standard user is the one browsing. If no Explorer is running, it grants the account running the tool.

**Why the old version failed.** It granted `BUILTIN\Administrators`, which images already had. Explorer runs non-elevated, and in a non-elevated token Administrators is deny-only, so that grant did nothing for browsing. v2 grants the actual user's SID.

**The permission pass.** On each profile root (`X:\Users\<name>`) it adds one inheritable ACE for the user and lets Windows propagate it to children that inherit. Then it walks the first three folder levels of each profile and checks each folder with `Get-Acl`. Folders with protected ACLs (inheritance turned off) get a recursive grant on that subtree only. If `icacls` hits access denied, it runs `takeown /a` on that one folder and retries once. `-Deep` skips the walk and does the full recursive grant instead.

**Links are never followed.** Profiles contain junctions like `Application Data` that point at absolute paths such as `C:\Users\<name>\AppData\Roaming`. On your machine, `C:` is your own drive. Every `icacls` call passes `/L` so it acts on the link and not its target, enumeration skips reparse points, `takeown` never recurses, and any path that does not start with the mounted drive letter is refused. The old version could change host ACLs when usernames matched.

**State marker.** When the pass finishes with no failures, the tool writes `X:\.vhdoneclick.json` (Hidden, not System) inside the mounted volume. It records which SIDs were granted, at what level, when, and on which machine. It lives in the diff, so deleting the diff also forgets it. Carry the image and diff to another machine and the new user gets granted without redoing the first one. Any failure leaves the user marked incomplete, so the next mount retries.

**Logs.** Each run writes `VHDOneClick-logs\<image>-<yyyyMMdd-HHmmss>.log` next to the image, keeping the 10 newest per image. If that folder is not writable, logs go to `%TEMP%\VHDOneClick-logs` and the console says so. Logs hold paths and error codes, never file contents.

**Image protection.** Before creating or attaching the diff, the tool sets the read-only attribute on the image, since writing to a parent breaks every diff built on it. This is a speed bump. Explorer still lets someone delete the file after a prompt. A failure to set it (exFAT, network share) is a warning only. The tool never clears it on its own; `-ClearReadOnly` does.

**Drive letters.** The tool takes a snapshot of drive letters before attaching and compares after, using the Win32 drive list directly, polling every 200 ms. If Windows assigns no letter (automount disabled), it uses `diskpart` to give the largest Primary partition the next free letter from D up.

**Mounting on the machine the image came from.** The original disk is still attached, so Windows takes the diff offline with a signature collision. The tool gives the diff a new disk GUID (GPT) or signature (MBR) and brings it online. That change lands in the diff only.

## Files created next to the image

| File | Purpose |
|---|---|
| `<image>.diff.vhdx` (or `.diff.vhd`) | Differencing disk. Holds every change, including the permission grants and the marker. Safe to delete. |
| `VHDOneClick-logs\` | Run logs, 10 newest per image. |

v1 left a `<image>.diff.vhdx.perms_done` file. v2 ignores it, so delete it. If you have a `.vhd` image, v1 also made a `.diff.vhdx` for it; v2 uses `.diff.vhd` and says so in the console. Delete the old one.

## Performance

v1 ran `takeown /r` and `icacls /T` over the whole `Users` tree, rewriting the owner and DACL of every file. Each one dirties an MFT record, so a big profile took minutes and bloated the diff. v2 writes profile roots, lets inheritance do the rest, and recurses only into subtrees that fail the check.

Measured numbers go here once they exist. Nothing is measured yet, so treat "much faster on big profiles" as an estimate.

| Case | First run | Diff growth |
|---|---|---|
| 500,000-file profile, default | not measured | not measured |
| 500,000-file profile, `-Deep` | not measured | not measured |
| Remount of an existing diff | not measured (target: under 5 s) | none |

## Security notes

- **Do not run anything from the mounted volume.** If the image came from someone else, treat it as untrusted. Opening it at all means Windows' NTFS driver parses data someone else controls.
- **Loose scripts are tamperable.** The tool runs elevated. If you use the `.ps1` and `.bat` from a folder other people can write to, someone could swap them. The exe embeds the script, so this applies to the scripts zip, not the exe. Verify the exe with its hash, and the signature once releases are signed.
- **Grants are narrow by default.** Only the detected user gets access. `-GrantAllUsers` is opt-in.
- **`-ExecutionPolicy Bypass`** only appears in the batch launcher and only affects that one PowerShell process. The exe does not need it.
- **diskpart commands** go over stdin. If that fails they go into a randomly named file in `%SystemRoot%\Temp`, created with create-new semantics so a file planted under the same name cannot be reused. That folder lets standard users create files but not open each other's, so this is narrower than the user's own `%TEMP%`.

## Verifying a download

Each release has `SHA256SUMS.txt` and a build provenance attestation.

```powershell
Get-FileHash .\VHDOneClick.exe -Algorithm SHA256
```

Compare against the line in `SHA256SUMS.txt`. The attestation ties the exe to the exact workflow run and commit that built it, and you can check it on the release's Attestations page or with GitHub's CLI if you have it.

## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org). Releases built before signing was approved are unsigned and say so in their notes.

- Committers and reviewers: [rimoldetech](https://github.com/rimoldetech)
- Approvers: [rimoldetech](https://github.com/rimoldetech)

Only binaries built by this repository's GitHub Actions from this repository's source are signed.

**Privacy policy:** this program does not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

## Troubleshooting

**"No VHD/VHDX file found"**
The exe or scripts have to be in the same folder as the image. Or pass `-Image`.

**"The image changed since this diff was created. Run with -Reset."**
Something wrote to the image after the diff was made, so the diff no longer matches. `-Reset` throws the diff away and makes a new one. Anything saved into the old diff is gone.

**"Volume X: is BitLocker-locked"**
Double-click the drive in Explorer and enter the password or recovery key, or run `manage-bde -unlock X: -RecoveryPassword <key>`. Then run the tool again with `-Mount` to finish the permission pass.

**"Signature collision and the disk ID could not be changed"**
You are mounting the image on the machine it came from and the fix did not work. Mount it on a different machine, or open an issue with the log.

**"No free drive letters"**
D through Z are all taken. Disconnect a drive or network share.

**Some folders still prompt**
The console printed a failure count, and the log has the paths. Run the tool again with `-Mount`, which retries. If the same folders keep failing, run with `-Deep`. If that fails too, run with `-Reset` and open an issue with the log.

**Windows Defender or SmartScreen flags the exe**
PS2EXE output gets flagged more often than most programs, since its launcher stub is common in malware. Check the hash, use the scripts zip, or report the false positive to Microsoft. Signed releases flag far less.

## Building

GitHub Actions does it. `.github/workflows/ci.yml` lints, tests and builds on every push. `.github/workflows/release.yml` runs on a `v*.*.*` tag and publishes the release. See `maintenance.md` for the release checklist.

To build locally on Windows:

1. `powershell -NoProfile -File tools\Install-BuildTools.ps1`, since this installs the pinned ps2exe, Pester and PSScriptAnalyzer.
2. `powershell -NoProfile -File tools\Invoke-Checks.ps1`
3. `powershell -NoProfile -File tools\Build.ps1 -Version 2.0.0-local -OutDir out`
4. From an elevated prompt: `powershell -NoProfile -File tests\Integration.ps1 -Exe out\VHDOneClick.exe`

Now `out\` holds `VHDOneClick.exe` and `VHDOneClick-scripts.zip`, the same as a release minus signing.

## License

[GNU General Public License v3.0](LICENSE)
