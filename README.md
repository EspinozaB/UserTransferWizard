# User Transfer Wizard (UTW)

A PowerShell GUI for Microsoft's USMT. It captures a Windows user profile off
one machine and restores it onto another — locally, over the network, or by way
of an external drive.

USMT itself only runs `scanstate.exe` and `loadstate.exe`. UTW does the work
around them: staging the binaries on the remote machine, pre-flight checks,
tailing the logs, cleaning up afterwards, and comparing the two machines when
it's done. No WinRM, no PsExec.

Windows PowerShell 5.1 and WinForms. Nothing to install, nothing to compile.

## Requirements

- Windows PowerShell 5.1 (ships with Windows 10/11 — not PowerShell 7)
- USMT from the Windows ADK. **Not included** — those binaries are Microsoft's
  to distribute. Install the ADK's *User State Migration Tool* feature and point
  UTW at the `amd64` folder on first run.
- The XML in `usmt-xml\` copied into that same folder. Not strictly required,
  but see below — it's the difference between a migration that works and one
  people are happy with.
- For remote work: local administrator on both machines, with `C$` reachable.

## Running it

```
UTW-Launcher.bat            elevates, then opens the window
UTW-Launcher.bat /noadmin   no elevation — local browsing and Compare only
```

Or from a console:

```
powershell -NoProfile -ExecutionPolicy Bypass -STA -File UTW-Main.ps1
```

Settings save beside the script as `UTW_Settings_<you>.json`, one file per
operator, so two techs sharing a folder don't overwrite each other.

## What it does

| Operation | Result |
|---|---|
| Export | Captures a profile to a store |
| Import | Restores a store onto a machine |
| Export + Import | Both legs in one run, old machine to new |
| Computer Settings | System settings and Public folders only, no user profiles |
| Extract | Unpacks a `.MIG` into a normal folder tree for manual recovery |

The store can go to a share on the new PC (**Direct**), a **UNC path**, or an
**external drive**. Direct is the one that needs no ACL work — UTW creates a
temporary share on the new PC, grants exactly the account that needs it, and
removes it afterwards.

Also in the box: stale profile cleanup (folder *and* registry entry, so nobody
gets a temporary profile next sign-in), OneDrive exclusion with a size
threshold, an Expert panel showing the exact command line before it runs, eight
themes, and a movable panel layout.

## Three things that trip people up

**Remote runs execute as SYSTEM.** There's no WinRM here, so UTW stages the
binaries over `C$` and starts a scheduled task as `SYSTEM`. On the network,
SYSTEM is the *computer account* (`DOMAIN\PCNAME$`) — not you. Any share the
capture writes to has to grant that account write access, and effective SMB
access is the intersection of the share ACL and the NTFS ACL. This is behind
most "access is denied" failures that show up halfway through a healthy run.
Add `Domain Computers` to the share, or use Direct mode and skip the problem.

**`Config.xml` prevents error 72.** Migrating from a newer Windows build to an
older one, loadstate aborts during V2V arbitration on components the destination
doesn't have — and `/c` doesn't override it. The working file is in `usmt-xml\`;
copy it in and the problem is gone. It has to be present during the **export**,
not just the import. Full walkthrough in the docs.

**A drive store is two runs, not one.** Every other store type works in one pass
because both machines can reach it at the same moment. A drive can't be in two
places, so Export + Import greys the drive option out. Export on the old PC,
carry it, Import on the new one.

## Use the included XML

Four files in `usmt-xml\`. Copy them next to `scanstate.exe` and `loadstate.exe`.
This is the highest-value thing you can do before the first migration — stock
USMT rules leave a lot behind.

| File | What it changes |
|---|---|
| `Config.xml` | Turns off the three components that abort loadstate with error 72. Nothing else — the other 153 stay on. Portable across builds as-is |
| `MigUser.xml` | Replaces the stock file. Adds Chrome, Firefox, Outlook mail profiles, **Downloads** (stock USMT doesn't migrate it), file associations, and printers |
| `MigratePublicFolders.xml` | Captures `C:\Users\Public` on computer-settings runs, which `/ue:*\*` otherwise excludes |
| `ExcludeOneDriveFolders.xml` | Skips folders already synced to OneDrive. Read the caveat below |

UTW picks up `Config.xml` and `MigratePublicFolders.xml` on its own.
`MigUser.xml` is always passed, so dropping it in is all it takes.

Two things to know:

**`ExcludeOneDriveFolders.xml` doesn't look for a folder called OneDrive.** It
unconditionally excludes Documents, Desktop and Pictures. Under Known Folder
Move those already point into OneDrive, so it skips exactly what will sync back
down — but on a profile *without* KFM it drops the three folders the user cares
about most, quietly. UTW measures the folders on disk before offering the
exclusion for this reason. Running scanstate by hand, check KFM first.

**The printer component in `MigUser.xml` carries driver files and `HKLM` print
keys.** Same build to same build, printers just appear. Across builds, or onto a
machine that already has a different driver version, you can get a queue that
exists but won't print. If a print server or GPO already deploys printers, this
component is redundant.

## Repo layout

| Path | What |
|---|---|
| `UTW-Main.ps1` | GUI and run orchestration |
| `UTW-Logic.ps1` | Command building, remote execution, checks |
| `UTW-Themes.ps1` | Theme data, design tokens, background painters |
| `UTW-Launcher.bat` | Starts it without a console window |
| `xaml\` | Theme artwork and operation icons |
| `tests\` | Test suite — see `tests\README.md` |
| `Config.xml` | Passed as `/config:`. Prevents error 72 |
| `UTW_Settings.json` | Shipped defaults |
| `UTW_SyncRules.json` | Exclusion lists for Compare & Sync — edit without touching code |
| `usmt-xml\` | The tuned migration XML — copy into the USMT folder |
| `USMT\amd64\` | Microsoft's USMT binaries — **not included** |

## Tests

```
powershell -NoProfile -File tests\Run-Tests.ps1        all 11
powershell -NoProfile -File tests\Run-Tests.ps1 -Fast  skip the ones that build a window
```

No USMT install needed, and nothing touches a real machine — the destructive
tests run against a substituted drive letter.

## Troubleshooting

Anything with a **USMT exit code** is Microsoft's. UTW prints what the code
means and links the reference page when a run fails:
<https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes>

Anything **without** one is UTW's — staging tools, creating shares, scheduling
tasks, locking a destination:

| Message | Cause |
|---|---|
| Could not stage the USMT tools | `\\PC\C$\Windows\Temp` unreachable. Machine off, not an admin on it, or File and Printer Sharing closed |
| Access is denied, partway through a capture | Store doesn't grant the source *computer account* write access |
| UNC mode does nothing, or 0x5 | Same cause. Share needs `Domain Computers` |
| Destination store is in use by another window | Another UTW window is writing that store. Two captures on one store make a bad `.MIG` |
| Not a valid computer name | Clean Up takes plain machine names only — that path is handed to a recursive delete |
| Clean Up skipped a profile | Every profile is listed with the reason. "Signed in right now" is the usual one: any loaded hive counts, so run it against a machine users have signed out of |

## Docs

`docs/DOCUMENTATION.md` has the rest: the remote execution model, command
construction and profile targeting, the full error 72 fix, OneDrive detection,
stale profile deletion, Expert mode, layout, themes, and the reference commands.
