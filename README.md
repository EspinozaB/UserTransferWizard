# User Transfer Wizard (UTW)

A graphical front end for Microsoft's USMT. It captures a Windows user
profile from one machine and restores it onto another: locally, over the
network, or through an external drive.

USMT is `scanstate.exe` and `loadstate.exe`. UTW does the rest: staging
the binaries on the far machine, pre-flight checks, log tailing,
cleanup, and comparing the two machines afterwards. No WinRM, no PsExec.

Windows PowerShell 5.1 and WinForms. Nothing to install, nothing to
compile.

Full manual: [DOCUMENTATION.md](DOCUMENTATION.md)
Changes: [CHANGELOG.md](../CHANGELOG.md)

## Requirements

* Windows PowerShell 5.1, built into Windows 10 and 11. Not PowerShell 7.
* USMT from a released Windows ADK. The binaries are Microsoft's and are
  not in this repo. See Getting USMT below.
* The tuned XML from `Modified USMT Config Files\`, placed in the USMT
  folder beside `scanstate.exe`. Stock USMT rules leave a lot behind.
* Remote work: local administrator on both machines, `C$` reachable.

WARNING: use a released ADK, not an Insider or Canary one. Insider USMT
will not load on released Windows and fails instantly with a blank log.
Build 26100 (Windows 11 24H2) covers Windows 10 and 11.

## Install

Copy the folder anywhere: local disk, mapped drive, or `\\server\share`.
Add the USMT binaries and the tuned XML yourself, see Getting USMT
below. Nothing is written to the registry or to Program Files.

## Run

| Launcher | Notes |
|---|---|
| `Core\UTW.vbs` | Double-click. No console window. Best from a mapped drive or UNC path |
| `Core\UTW-Launcher.bat` | Same, with a brief console flash |

Both request administrator rights and let you continue without them
(local browsing and Compare only). Pass `/noadmin` to skip the prompt.

From a console:

    powershell -NoProfile -ExecutionPolicy Bypass -STA -File Core\UTW-Main.ps1

Settings save in `Core\` as `UTW_Settings_<you>.json`, one per operator.

## What it does

| Operation | Result |
|---|---|
| Export | Capture a profile to a store |
| Import | Restore a store onto a machine |
| Export + Import | Both legs in one run |
| Extract | Unpack a `.MIG` into a normal folder tree |
| Clean up | Remove staged USMT files and old stores. Optionally delete stale profiles |
| Compare and Sync | Copy across what changed on the old PC after a migration |

"Applies to" sets the scope: one profile, all profiles, or computer
settings only (system settings plus `C:\Users\Public`, no user
profiles).

The store goes to a temporary share on the new PC (Direct), a UNC path,
or an external drive. Direct needs no ACL work: UTW creates the share,
grants the one account that needs it, and removes it afterwards.

Also included: stale profile cleanup (folder and registry entry
together), OneDrive exclusion with a size threshold, an Expert panel
showing the exact command line, eight themes, a movable panel layout.

## Four things that trip people up

**Remote runs execute as SYSTEM.** UTW stages the binaries over `C$` and
runs a scheduled task as SYSTEM. On the network, SYSTEM is the computer
account (`DOMAIN\PCNAME$`), not you. Any share the capture writes to
must grant that account write access. This causes most "access is
denied" failures partway through an otherwise healthy run. Use Direct
mode, or add `Domain Computers` to the share.

**USMT version has to match the machines.** scanstate runs on the
source, loadstate on the destination, and the binary has to load on that
build of Windows. USMT from an Insider ADK fails instantly with a blank
log, exit `-1073741511` (`0xC0000139`). Use a released ADK. UTW warns,
but do not rely on the warning.

**Config.xml is opt-in.** Cross-build migrations hit error 72 during
loadstate. The setting is File > Settings > Cross-build fix
(Config.xml): `auto` (default) applies it only when the two machines are
on different builds, `yes` always, `no` never. It must be present during
the export, not only the import.

**A drive store is two runs.** A drive cannot be in two places, so
Export + Import greys out the drive option. Export on the old PC, move
the drive, Import on the new one.

## Included XML

| File | What it changes |
|---|---|
| `MigUser.xml` | Replaces the stock file. Adds Chrome, Firefox, Outlook mail profiles, Downloads (stock USMT skips it), file associations, printers |
| `Config.xml` | Turns off the three components that abort loadstate with error 72. Applied per the Cross-build fix setting |
| `MigratePublicFolders.xml` | Captures `C:\Users\Public` on computer-settings runs |
| `ExcludeOneDriveFolders.xml` | Skips OneDrive-synced folders. Read the caveat in DOCUMENTATION section 7.3 first |

Masters are in `Modified USMT Config Files\`. Copy them into the USMT
folder beside `scanstate.exe`.

## Updating

* **UTW:** replace the three `.ps1` files in `Core\`. Settings and USMT
  files are untouched. If it runs from a share, replace them on the
  share.
* **USMT:** copy a newer released ADK's `amd64` contents over the old
  ones, keeping the tuned XML. To keep several versions, use
  `amd64-<build>` sibling folders or a `USMT\Build <n>\amd64` folder per
  version. UTW reads each machine's Windows build and picks the
  closest-fitting set.
* **Tuned XML:** replace the file in the USMT folder. DOCUMENTATION
  section 8.5 covers regenerating `Config.xml`.

## Troubleshooting

USMT exit codes are Microsoft's. UTW prints the meaning and links
[the reference page](https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes).
UTW's own failures:

| Symptom | Cause |
|---|---|
| Exits instantly, blank log, exit `-1073741511` / `0xC0000139` | USMT binaries are from an Insider ADK and will not load. Replace with a released ADK's USMT, build 26100 |
| "USMT has not started after N min" | Task ran, no log appeared. On that PC check `C:\Windows\Temp\USMT_Temp`. A 0-byte stdout log means the task was blocked (AppLocker, WDAC, policy). Banner only means the executable stalled (store path, AV, USMT version). Task Scheduler History has the reason |
| "Could not stage the USMT tools" | `\\PC\C$\Windows\Temp` unreachable. Machine off, not an admin on it, or File and Printer Sharing closed |
| "Access is denied" partway through a capture | Store does not grant the source computer account write access. Use Direct mode or add `Domain Computers` |
| "Destination store is in use by another window" | Another UTW window is writing that store |
| Error 72 on loadstate | Cross-build component mismatch. Set Cross-build fix to `auto` or `yes` and confirm `Config.xml` is present |

Full list: DOCUMENTATION section 15.

## Layout

| Path | What |
|---|---|
| `Core\UTW-Main.ps1` | GUI and run orchestration |
| `Core\UTW-Logic.ps1` | Command building, remote execution, checks |
| `Core\UTW-Themes.ps1` | Theme data and background painters |
| `Core\UTW.vbs` | Double-click launcher, no console |
| `Core\UTW-Launcher.bat` | Double-click launcher, brief console |
| `Core\UTW_Settings.json` | Shipped defaults |
| `Core\UTW_SyncRules.json` | Compare and Sync exclusion lists |
| `Core\UTW.ico` | Window and shortcut icon |
| `Docs\` | README, DOCUMENTATION, command-line examples |
| `Modified USMT Config Files\` | Masters of the tuned XML |
| `xaml\` | The five Run button icons |
| `USMT\Build <n>\amd64\` | Microsoft's USMT binaries. Not in this repo |

The scripts locate `xaml\`, `Docs\`, and the tuned XML relative to the
folder holding `Core\`, so the tree can be flattened into one folder
without breaking anything.

## Getting USMT

Install the Windows ADK's User State Migration Tool feature, copy its
`amd64` folder somewhere, add the four tuned XML files from
`Modified USMT Config Files\`, and point UTW at that folder on first
run.

The binaries are not in this repo and are not covered by its licence.
The ADK's own terms decide whether you may redistribute them, so read
`License Terms.rtf` in the ADK install folder before publishing them
anywhere. If you do host a copy for your own team, attach a zip to a
GitHub Release rather than committing it: GitHub blocks single files
over 100 MiB, and anything committed stays in the history for good.

DOCUMENTATION section 2.8 has the detail.

## Licence

MIT. See [LICENSE](../LICENSE).

MIT covers the scripts, launchers, and documentation. It does not cover
`Modified USMT Config Files\MigUser.xml`, which is a modified copy of
Microsoft's file, or `Config.xml`, which is `scanstate /genconfig`
output that has been edited. Both are necessary and both are why that
folder is named what it is. Microsoft's terms apply to them and to the
USMT binaries. See [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).
