# VHDOneClick

A lightweight, end-user-friendly tool for mounting VHD/VHDX disk images and browsing their contents in Windows Explorer. Designed with converted Macrium Reflect X full-disk backups in mind, where the image contains multiple partitions (EFI, MSR, Recovery, and the main Windows volume).

Double-click to mount. Double-click again to unmount. That's it.

---

## Use Case

When you hand a VHD/VHDX backup image off to someone for file recovery, they typically have no idea how to mount it, navigate Disk Management, or deal with the fact that a full-disk image contains several partitions. VHDOneClick handles all of that automatically:

- Creates a **differencing disk** so the original image is never modified
- Identifies the correct volume (the largest data partition, equivalent to the source `C:` drive) and opens it directly in Explorer
- Fixes NTFS ownership and permissions on first run so protected folders like `Users` are accessible without prompts
- If Windows doesn't auto-assign a drive letter, the tool assigns one itself
- Running it a second time cleanly unmounts the image

---

## Contents

| File | Description |
|---|---|
| `VHDOneClick-Entrypoint.bat` | Entry point. Checks for Administrator rights and launches the PowerShell script. |
| `VHDOneClick-Main.ps1` | Core logic. Handles diff disk creation, mounting, drive letter detection, permission fixing, Explorer launch, and unmounting. |

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 (built into Windows — no install required)
- Administrator rights (required by Windows to mount disk images)

---

## Usage

### Scripts only

1. Place `VHDOneClick-Entrypoint.bat` and `VHDOneClick-Main.ps1` in the same folder as your `.vhd` or `.vhdx` file.
2. Right-click `VHDOneClick-Entrypoint.bat` and choose **Run as administrator**.
3. On first run, a differencing disk is created and NTFS permissions are fixed — this may take a moment depending on how many files are in the image.
4. An Explorer window will open to the main volume automatically.
5. To unmount, run `VHDOneClick-Entrypoint.bat` as administrator again.

### Pre-built release (VHDOneClick.exe)

1. Place `VHDOneClick.exe` in the same folder as your `.vhd` or `.vhdx` file.
2. Double-click it. The UAC elevation prompt is handled automatically.
3. Mount and unmount work the same way as above.

---

## How It Works

**Differencing disk**

Rather than mounting the original image directly, VHDOneClick creates a child differencing disk (`.diff.vhdx`) alongside the source file. All writes — including NTFS permission changes — land in the diff disk. The original image is never opened for writing. The diff disk is kept between sessions so subsequent mounts are fast.

**Finding the right volume**

Full-disk images from tools like Macrium Reflect contain every partition from the source drive: EFI System, Microsoft Reserved (MSR), Recovery, and the main Windows data partition. VHDOneClick detects new drive letters by comparing a snapshot of all mounted volumes taken before and after the mount call, using the Win32 `GetLogicalDrives` API directly. This bypasses the PowerShell Storage CIM layer, which can have visibility gaps with differencing disks on some machines. The largest newly appeared volume is selected as the target.

**Drive letter assignment**

Windows usually assigns drive letters automatically. If it doesn't, VHDOneClick uses `diskpart` to identify the largest Primary partition and assign the next available letter from D onwards. Like the permission changes, this assignment exists only in Windows' own mount table and does not affect the image file.

**Permission fixing**

Backup images preserve the original machine's NTFS security descriptors, meaning protected folders like `Users` appear locked when accessed from a different machine. On first run, VHDOneClick runs `takeown` to transfer ownership of the `Users` tree to the local Administrators group, then `icacls` to grant full access. Both operations write only to the differencing disk. A small sentinel file (`.diff.vhdx.perms_done`) is written alongside the diff when this completes, so the process is skipped on all subsequent mounts.

---

## Files Created Alongside the Image

After first run, VHDOneClick will leave two small sidecar files next to your `.vhdx`:

| File | Purpose |
|---|---|
| `<imagename>.diff.vhdx` | Differencing disk. Keeps permission changes and speeds up subsequent mounts. Safe to delete — it will be recreated on next run, but the permission fix will need to run again. |
| `<imagename>.diff.vhdx.perms_done` | Sentinel flag. Prevents the `takeown`/`icacls` pass from re-running unnecessarily. Delete this alongside the diff if you need to force a permission reset. |

---

## Building the SFX (for contributors)

The release `VHDOneClick.exe` is a WinRAR self-extracting archive configured as follows:

- **Files to pack:** `VHDOneClick-Entrypoint.bat`, `VHDOneClick-Main.ps1`
- **Run after extraction:** `VHDOneClick-Entrypoint.bat`
- **Request administrative privileges:** Yes
- **Overwrite mode:** Overwrite all files (so re-running always uses the latest scripts)

---

## Troubleshooting

**"No VHD/VHDX file found in this folder"**
The scripts or `.exe` must be in the same folder as the image file. Move them to the same location and try again.

**"Failed to mount image"**
The file may be open by another process or damaged. Make sure nothing else has the image open and try again.

**"No Primary partition found"**
The image may use MBR-style partitioning rather than GPT. Please open an issue with details about how the source image was created.

**"No free drive letters available"**
All letters D through Z are in use on the host machine. Disconnect an unused drive or network share to free one up, then try again.

**Folders still show as inaccessible after first run**
Delete the `.diff.vhdx.perms_done` sentinel file and the `.diff.vhdx` differencing disk, then run again. This forces the ownership and permission fix to re-run from scratch against a fresh diff disk.

---

## License

[GNU General Public License v3.0](LICENSE)
