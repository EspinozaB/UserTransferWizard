USER TRANSFER WIZARD (UTW)
Technical Reference

Revision: September 2026


CONTENTS

     1.  INTRODUCTION
     2.  INSTALLATION
     3.  USMT VERSIONS
     4.  OPERATION
     5.  REMOTE MIGRATION
     6.  STORE LOCATIONS
     7.  MIGRATION XML
     8.  ERROR 72 AND CONFIG.XML
     9.  ONEDRIVE DETECTION
    10.  CLEANUP AND STALE PROFILES
    11.  COMPARE AND SYNC
    12.  EXPERT MODE
    13.  WINDOW AND LOGS
    14.  THEMES
    15.  TROUBLESHOOTING
    16.  REFERENCE

For a short overview, read README.md.

---

## 1. INTRODUCTION

UTW is a graphical front end for Microsoft's User State Migration Tool
(USMT), written in Windows PowerShell 5.1 and WinForms.

It runs `scanstate.exe` to capture a user profile and `loadstate.exe`
to restore it. Around that it stages the binaries on the far machine,
runs pre-flight checks, tails the logs, cleans up, and compares the two
machines afterwards.

Nothing is installed or compiled, and nothing is written to the registry
or to Program Files. Runs may be local, remote over admin shares, or
through an external drive. Remote work uses the `C$` admin share and
`schtasks.exe` over DCOM/RPC. WinRM and PsExec are not used.

Every USMT command is built from the fields in the window.

---

## 2. INSTALLATION

### 2.1 Requirements

* Windows PowerShell 5.1, built into Windows 10 and 11. PowerShell 7 is
  not supported.
* USMT from a released Windows ADK. Section 3.
* The four tuned XML files. Section 7.
* Remote work: local administrator on both machines, `C$` reachable on
  each.

### 2.2 What ships where

Scripts, launchers, documentation, and the tuned XML are in both the Git
repo and the release zip. The USMT binaries are Microsoft's and are
handled separately. See 2.8.

With the repo only: install the ADK's User State Migration Tool
feature, put the binaries in a folder, copy the four tuned XML files in
beside them, and point UTW at that folder on first run.

### 2.3 Install and layout

Copy the folder anywhere: local disk, mapped drive, or `\\server\share`.
Run `Core\UTW.vbs` (no console window) or `Core\UTW-Launcher.bat`.

    Core\                        scripts, launchers, settings
    Docs\                        this file and README.md
    Modified USMT Config Files\  masters of the tuned XML
    xaml\                        Run button icons
    USMT\                        binaries, see 2.8

The scripts locate the siblings relative to `Core\`, so the tree may
also be flattened into one folder.

### 2.4 Permissions

USMT reads profile registry hives (`NTUSER.DAT`) and protected folders,
so UTW normally runs elevated. Both launchers request elevation and let
you continue without it; unelevated covers local browsing, Extract, and
Compare. Pass `/noadmin` to skip the prompt.

NOTE: Elevating your own workstation does not grant remote access. A
network logon by a domain admin account gets an unfiltered token whether
or not the local window is elevated. A local, non-domain account does
not.

### 2.5 Files in the USMT folder

From the ADK: `scanstate.exe`, `loadstate.exe`, `UsmtUtils.exe`, and
`migapp.xml` unmodified.

From this project, all four from `Modified USMT Config Files\`:

| File | Purpose |
|---|---|
| `MigUser.xml` | User data rules. Replaces the stock file |
| `Config.xml` | Turns off the components causing error 72 |
| `MigratePublicFolders.xml` | Captures `C:\Users\Public` |
| `ExcludeOneDriveFolders.xml` | Optional. Read section 7.3 first |

`Config.xml` also works beside the scripts. On a remote run it is staged
with the tools automatically.

### 2.6 Settings

Per-operator settings save in `Core\` as `UTW_Settings_<name>.json`, so
two people sharing a folder do not clash. `Core\UTW_Settings.json` holds
the shipped defaults and seeds each operator's file on first run;
personal files are not committed.

Shipped defaults: theme Dark, graphics off, animation off, cross-build
fix `auto`, paths blank.

File > Settings holds the site-wide values. Most are self-explanatory in
the dialog. The ones worth knowing:

| Setting | Meaning | Default |
|---|---|---|
| Domain | Added in front of a username with no domain | blank |
| Store folder name | Folder under `C:\` holding stores | `USMT Profiles` |
| USMT verbosity | The `/v:` level | 13 |
| Cross-build fix (Config.xml) | Section 8.3 | `auto` |
| Ask about OneDrive above (MB) | Local data size before prompting. `0` always asks. Section 9 | 500 |
| Stale profile age (days) | Idle days before a profile is offered for deletion | 90 |

Machine names, theme, operation, and panel layout are remembered
automatically. File > New window (Ctrl+N) opens a second instance for
two migrations at once; only the first window saves on close.

### 2.7 Updating

UTW: replace the three `.ps1` files in `Core\`. Settings and USMT files
are untouched. If UTW runs from a share, replace them on the share.

USMT binaries: copy a new released ADK's `amd64` contents over yours,
including the executables, every `*.dll`, and the `DLManifests\` and
`ReplacementManifests*\` folders. Leave the tuned XML in place, then
check the build on the USMT status line.

Tuned XML: replace the file in the USMT folder. Section 8.5 covers
regenerating `Config.xml`.

### 2.8 Shipping the USMT binaries

UTW needs `scanstate.exe`, `loadstate.exe`, `UsmtUtils.exe`, their DLLs,
and the manifest folders. Those come from the Windows ADK. They are not
part of this project and this project's licence does not cover them.

WARNING: The ADK is licensed under Microsoft's terms, and its
"Distributable Code" section lists exactly which files may be
redistributed. Read `License Terms.rtf` in the ADK install folder before
publishing the binaries anywhere public. Microsoft's own deployment
products require the administrator to install the ADK rather than
bundling USMT with the product, which is a fair guide to the intent.

Three ways to handle it, in order of preference:

| Method | Notes |
|---|---|
| ADK install, documented | Nothing to host, no licence question. The operator installs the ADK's User State Migration Tool feature and points UTW at `amd64` |
| Release asset | A zip attached to a GitHub Release. Not in Git history, so a clone stays small. Assets take large files, and only people who want the binaries download them |
| Git LFS | Works, but the free tier is 1 GB of storage and 1 GB of bandwidth a month, and every clone spends bandwidth |

Committing the binaries straight into Git is the one to avoid. GitHub
hard-blocks any single file over 100 MiB, warns above 50 MiB, and
recommends keeping a whole repository under 1 GB. Worse, a binary
committed once is in the history forever, so removing it later means
rewriting history for everyone who cloned.

If you go with a Release asset:

1. Build the folder locally, `USMT\Build <n>\amd64\`, with the
   binaries and all four tuned XML files.
2. Zip it and attach the zip to a GitHub Release.
3. Add `USMT/` to `.gitignore` so it never reaches Git history.
4. Note the ADK build number and where it came from in the release
   notes, so anyone can reproduce the folder from the same ADK.

Whichever way you go, `.gitignore` should already carry `amd64/`,
`amd64-*/`, `x86/`, and `x86-*/`.

### 2.9 Licence

The UTW scripts, launchers, and documentation are MIT licensed. See
`LICENSE`.

MIT does not extend to everything in the tree:

| Item | Status |
|---|---|
| `Core\`, `Docs\`, `xaml\` | MIT. This project's own work |
| `Modified USMT Config Files\MigUser.xml` | A modified copy of Microsoft's `MigUser.xml`. Microsoft's terms apply. Modifying it is what makes it useful, which is why it sits in a folder named for exactly that |
| `Modified USMT Config Files\Config.xml` | Generated by `scanstate /genconfig` and then edited. Microsoft's terms apply |
| `Modified USMT Config Files\MigratePublicFolders.xml`, `ExcludeOneDriveFolders.xml` | Written for this project against Microsoft's published schema. MIT |
| USMT binaries | Microsoft's. Not covered. See 2.8 |

`THIRD-PARTY-NOTICES.md` in the repo root records the same thing.

---

## 3. USMT VERSIONS

The most common reason a migration fails instantly with an empty log.
Read this before the first run.

`scanstate.exe` runs on the source machine and `loadstate.exe` on the
destination. Each has to load on that machine's version of Windows.

### 3.1 The rule

Use USMT from a RELEASED Windows ADK, matched to the newest Windows you
deploy. A released ADK's USMT still captures from older Windows. Build
26100 (Windows 11 24H2) runs on Windows 10 and every Windows 11 build so
far, so one folder covers a mixed fleet.

WARNING: Do not use USMT from an Insider or Canary ADK. Its build number
is higher than any shipping Windows (27xxx, 28xxx), it links against
unreleased APIs, and it will not start on released Windows. It fails on
the older machine of the pair, instantly, with a blank log and exit
`-1073741511` (`0xC0000139`).

### 3.2 What UTW checks

Setting the USMT folder reports the build and whether it matches a known
released ADK, amber if newer than any known release. Before a run, UTW
compares the binary's build against both machines and stops with a
Yes/No prompt if the binary is newer than both.

The known-release list is `$Script:KnownUsmtBuilds` in `UTW-Logic.ps1`.
Add new builds there as ADKs ship.

### 3.3 Keeping more than one version

Optional. Needed only when one modern USMT cannot load on a machine you
must capture from. Either layout works:

    amd64\                       USMT\Build 26100\amd64\
    amd64-19041\                 USMT\Build 28000\amd64\

Siblings take `amd64-<build>` or `x86-<build>`. A folder per version
needs a build number in the folder name.

Point USMT Location at any one folder. On each run UTW reads the target
machine's build, checks every set it can see, and picks the newest build
not newer than that machine, or the oldest available if none qualify.
The build is read from each `scanstate.exe`, not the folder name. With
one set present, nothing changes.

### 3.4 USMT-VERSION.txt

Setting the USMT folder writes `USMT-VERSION.txt` into it with the build
number and date. A note for humans; UTW does not read it back. A
read-only share skips it.

---

## 4. OPERATION

### 4.1 Operations

| Operation | Tool | Purpose |
|---|---|---|
| Export | `scanstate.exe` | Capture a profile to a store |
| Import | `loadstate.exe` | Restore a store onto a machine |
| Export + Import | both | Both legs in one run |
| Extract a .MIG file | `UsmtUtils.exe` | Unpack a store into a folder tree |
| Clean up USMT files | UTW | Remove staged folders and old stores |
| Compare and Sync | robocopy | Copy across later changes. Section 11 |

### 4.2 Scope

Set by the "Applies to" control.

| Scope | Arguments | Captures |
|---|---|---|
| Single profile | `/ue:* /ui:DOMAIN\User` | One named user, everything else excluded |
| All profiles | `/ui:DOMAIN\* /ui:%computername%\*` | Every domain and local profile |
| Computer settings | `/ue:*\*` | System settings and `C:\Users\Public` only. Store folder named `Settings_COMPUTERNAME` |

### 4.3 Completion markers

A successful export writes `export_complete.json` to the store, holding
the source computer, timestamp, and technician account. Import reads it
to confirm the store is ready. `.usmt_store.json` is also written, so a
store can be found by content when its folder name does not match.

---

## 5. REMOTE MIGRATION

A remote leg is four steps:

1. Copy the USMT binaries to `C:\Windows\Temp\USMT_Temp` on the target,
   over `C$`.
2. Write `RunScan.bat` or `RunLoad.bat` there. It creates the log
   folder, writes a banner, runs the executable, and records the exit
   code.
3. Create a one-shot scheduled task through `schtasks.exe` over
   DCOM/RPC, running as `SYSTEM`, and start it.
4. Tail the progress and detail logs over `C$` until the task ends.

IMPORTANT: The task runs as `SYSTEM`. On the network that identity is
the machine's computer account (`DOMAIN\PCNAME$`), not you. Any network
path the capture writes to must grant that computer account access. This
is behind most "access is denied" failures that appear partway through
an otherwise healthy run.

Completion comes from the task's Last Run Result (`schtasks /query /v`,
parsed by column position so it works on non-English Windows),
cross-checked against the logs. If no detail log appears within five
minutes, UTW says so instead of tailing an empty file.

Export + Import over the network runs in three phases:

| Phase | Operation | Detail |
|---|---|---|
| 1 | Remote ScanState | Binaries staged to the source. Task runs scanstate as SYSTEM. Progress tailed over UNC |
| 2 | Transfer | Store copied to `\\DestPC\C$\USMT Profiles\<user>`. Source `USMT_Temp` cleaned. Skipped in Direct mode |
| 3 | Remote LoadState | Binaries staged on the destination. Task runs loadstate as SYSTEM. On success the store and `USMT_Temp` are deleted |

---

## 6. STORE LOCATIONS

| Store type | Reached by | Runs |
|---|---|---|
| New PC (Direct) | Both machines. UTW creates a temporary share on the destination granting only the source computer account, then removes it | One |
| Network share (UNC) | Both machines, if the ACLs allow it | One |
| External or USB drive | One machine at a time | Two |

### 6.1 Network share requirements

Effective SMB access is the intersection of the share ACL and the NTFS
ACL. Both must allow the write.

The capture runs as SYSTEM, so the account needing write access is the
source machine's computer account. Add `Domain Computers` to both ACLs.
Without that, UNC mode cannot work. Direct mode avoids the problem
entirely.

### 6.2 Why a drive store is two runs

A drive reaches one machine at a time, so Export + Import greys out
External / USB drive in the Save to list.

1. Old PC, or remotely to its own drive: Export to
   `D:\USMT Profiles\<user>`.
2. Move the drive.
3. New PC: Import. It accepts the store root, the `USMT` subfolder, or
   the `.MIG` file.

The export leg can still be remote: fill in Capture from and scanstate
runs on the old machine, writing to that machine's own drive. Useful
when the old PC's C: is full but it has an external disk.

---

## 7. MIGRATION XML

USMT ships generic rules. Four tuned files replace or extend them.
Copying them into the USMT folder is the single biggest change to what
arrives on the new machine.


| File | Status | Effect |
|---|---|---|
| `MigUser.xml` | Replaces stock | Adds browsers, Outlook profiles, Downloads, file associations, printers |
| `Config.xml` | Added | Turns off three components that abort loadstate with error 72. Opt-in, section 8 |
| `MigratePublicFolders.xml` | Added | Captures `C:\Users\Public` on computer-settings runs |
| `ExcludeOneDriveFolders.xml` | Added, optional | Skips OneDrive-synced folders |

`MigUser.xml` is always passed. `MigratePublicFolders.xml` is added on
computer-settings runs. `ExcludeOneDriveFolders.xml` is added when the
OneDrive option is on. `Config.xml` follows the Cross-build fix setting.

### 7.1 MigUser.xml

The stock file covers Documents, Desktop, Pictures, Music, Video,
Favorites, Quick Launch, the Start Menu, and common document extensions
on all fixed drives. The tuned version keeps that and adds:

| Component | Carries |
|---|---|
| Chrome | Profiles, bookmarks, saved passwords, extensions |
| Firefox | `%APPDATA%\Mozilla`, `%LOCALAPPDATA%\Mozilla\Firefox` |
| Outlook | Mail profiles, so Outlook does not rebuild from scratch |
| Downloads | `%USERPROFILE%\Downloads`, which stock USMT skips |
| Program defaults | `FileExts`, `HKCU\Software\Classes`, Shell Associations |
| Printers | `HKCU` printer settings, `HKLM` Print keys, driver entries, spool folder |

WARNING: The printer component carries `HKLM` print configuration and
the spool folder, driver binaries included. Same build and hardware
class, printers appear by themselves. Across builds, or onto a machine
holding a different driver version, you can get a queue that will not
print. It is redundant where a print server or Group Policy already
deploys printers. When printers are wrong after a migration, look here
first.

### 7.2 MigratePublicFolders.xml

A System-context component for `%PUBLIC%\Documents`, `Desktop`,
`Downloads`, `Music`, `Pictures`, `Videos`. Computer-settings runs
exclude all profiles with `/ue:*\*`, which drops the Public profile too,
so without this file such a capture takes no Public data at all. UTW
adds it on those runs.

### 7.3 ExcludeOneDriveFolders.xml

The file does not look for a folder called OneDrive. It sets
`unconditionalExclude` on `%CSIDL_MYDOCUMENTS%`, `%CSIDL_DESKTOP%`,
`%CSIDL_MYPICTURES%`, and `*.tmp` on all fixed drives. With OneDrive
Known Folder Move in effect those paths already point inside OneDrive,
so excluding them skips data that syncs back down anyway.

WARNING: `unconditionalExclude` beats every include rule, `MigUser.xml`
included. On a profile without Known Folder Move this file drops the
user's local Documents, Desktop, and Pictures, and the store comes out
small with no warning. UTW measures the folders on disk before offering
the exclusion (section 9). Running scanstate by hand, confirm Known
Folder Move is redirecting those folders first.

---

## 8. ERROR 72 AND CONFIG.XML

Error 72 stops loadstate before any data is restored. The destination
profile is untouched and the store is intact. Retry after the fix.

### 8.1 What it is

Error 72 occurs during V2V (version to version) arbitration. Before
applying data, loadstate checks each component in the store against what
the destination OS supports. A component marked critical in the store
but missing on the destination fails the run, even with `/c`.

It is a component mismatch between the two Windows builds, not a
network, permissions, or disk problem. Same-build migrations are
unaffected. Newer to older is the case at risk. Windows 10 to Windows 11
appears unaffected.

### 8.2 The three components

| Component | What it is | Safe to drop because |
|---|---|---|
| `Microsoft-Windows-Pcrpf` | TPM and Secure Boot measurement config | Hardware-specific. No user data |
| `Microsoft-Windows-Win32k-Settings` | Kernel graphics flags | OS-version-specific and policy-managed. No user data |
| `Microsoft-Windows-Printing-WindowsProtectedPrint` | Protected Print Mode toggle, Win11 24H2 and later | One policy setting. Does not affect printer migration |

`Config.xml` sets those three to `migrate="no"` and leaves the other 153
at `migrate="yes"`, so it is not a filter. Its component IDs use the
generic `migxmlext` URI form, so it works across Windows builds without
regenerating.

### 8.3 The Cross-build fix setting

`/config` matters for a cross-build migration. On a same-build capture
it only changes what is captured, so it is opt-in, under
File > Settings > Cross-build fix (Config.xml).

| Value | Behaviour |
|---|---|
| `auto` (default) | Apply `/config` only when the two machines report different Windows builds. The output pane shows what was found |
| `yes` | Always apply `/config` when `Config.xml` is present, on both legs |
| `no` | Never apply it |

A local export or a stand-alone import has no second machine to compare,
so `auto` does not apply `/config` there. Set `yes` when the store is
cross-build.

NOTE: `Config.xml` must be present during the EXPORT, not only the
import. The components are excluded at capture time, so a store written
without it still carries them. For a remote Export + Import, one
build-mismatch decision drives both legs.

### 8.4 Confirming it

Open the failed `Import_*.log` in
`\\DestPC\C$\Windows\Temp\USMT_Temp\Logs\`. Line 3 is the command. Look
for the V2V arbitration line about a critical migration unit, then
`USMT error code 72`.

After the fix, line 3 of a new `Import_*.log` should contain
`/config:"C:\Windows\Temp\USMT_Temp\Config.xml"`. If not, `Config.xml`
was not found and not staged. Confirm it sits beside `scanstate.exe`.

### 8.5 Regenerating Config.xml

Only needed if a later Windows build adds a fourth offending component.

1. On the destination, or any machine on the same build, from an
   elevated prompt:

       C:\Windows\Temp\USMT_Temp\scanstate.exe /genconfig:C:\Temp\Config.xml /v:5

2. Find the offending component and change `migrate="yes"` to
   `migrate="no"`. Do not touch the `ID` attribute.
3. Save it as `Config.xml` in the USMT folder. Leave every other
   component alone.

---

## 9. ONEDRIVE DETECTION

Before a single-profile capture, UTW checks whether the profile is on
OneDrive and offers to exclude it. Two signals: a matching folder in the
profile, and membership of the AD group named in the OneDrive group
setting.

Where OneDrive is deployed to everyone, both signals are always true and
tell you nothing. Hence the size threshold. The prompt appears only when
the OneDrive folders hold more than the Ask above value in MB, measured
ON DISK. Cloud-only files count as zero, so a fully dehydrated OneDrive
never prompts however large it looks in Explorer. A measurement beats
group membership: under the threshold, the group does not re-raise the
prompt.

---

## 10. CLEANUP AND STALE PROFILES

### 10.1 Clean up USMT files

Removes leftover `C:\Windows\Temp\USMT_Temp` folders from the machines
you name, and optionally the old stores. It also removes the store
folder itself (`USMT Profiles` by default) once the stores inside are
gone, but only when its name matches the configured name exactly, it
sits directly under a drive or share root, and it is completely empty.

### 10.2 Deleting stale profiles

UTW uses `Win32_UserProfile`, which is what System Properties drives
underneath and is remotable over DCOM. `Win32_UserProfile.Delete()`
removes the profile folder AND its `ProfileList` registry entry.
Deleting `C:\Users\<name>` by hand leaves the registry entry behind, and
the next sign-in gets a temporary profile.

Delete stale user profiles is in Options and applies to both Clean Up
and a capture. First a ticklist, one row per profile, with computer,
account, age, and folder; nothing ticked at first, and profiles that
cannot be deleted greyed out with the reason. Then a confirmation
listing exactly what was ticked. Cancelling abandons the whole clean
up.

Never offered: system and built-in profiles, anything under `\Windows`,
profiles signed in now, your own, and anything used inside the
inactivity window (default 90 days). The rules are re-checked at delete
time. On a capture, the profile just captured is never listed; removing
it is a separate Expert option with its own confirmation.

NOTE: Age is a hint, not proof. `LastUseTime` is often empty, so the
folder timestamp stands in, and the output says which was used.
`Win32_UserProfile.Loaded` is true for any profile with a loaded hive,
service accounts included, so on a live machine most profiles look
signed in. Run the clean up against a machine users have signed out of.

---

## 11. COMPARE AND SYNC

### 11.1 Compare and Sync

For when a profile was migrated days ago, the person kept using the old
machine, and the new PC is missing what they did since. A second full
capture would overwrite work already done on the new machine.

Compare and Sync runs robocopy `/L` to list what would copy, newer or
missing, lets you pick, then runs the same command for real. List and
copy are one command run twice, so they cannot drift apart.

It compares Documents, Desktop, and Downloads; the include AppData
setting adds `AppData\Roaming`. `NTUSER.DAT` and other working files are
never copied. Exclusion lists are in `Core\UTW_SyncRules.json`.

### 11.2 Compare installed programs

File > Compare installed programs reads the uninstall registry from both
machines and lists what the old PC has that the new one does not, plus
version differences. USMT does not migrate applications, so this is the
reinstall list.

IMPORTANT: Run it before wiping or returning the old PC. It reads live,
so once the machine is gone the list is gone. UTW prompts once per
session as a reminder.

---

## 12. EXPERT MODE

Mode: Expert in the header, or View > Expert, adds a panel with the
exact command line for each leg. Two of them for Export + Import.

* Editing the text updates the Options above, and the reverse. Removing
  `/o` unticks Overwrite.
* Switches UTW does not model (`/vsc`, `/encrypt`, `/hardlink`,
  `/nocompress`, `/uel`, `/md`, `/mu`) are kept as typed. Regenerate
  discards edits and custom switches.
* Switching back to Simple asks whether to keep the edit. Kept edits put
  "custom command" in the title bar, and every run says so.
* Nothing validates USMT syntax. A bad command line is exit 11.

The pre-check options (Profile exists, Free disk space, Inactive
profiles, Measure profile size) are UTW's own and have no command-line
form, so they are not in the panel.

Microsoft syntax reference:

    ScanState  https://learn.microsoft.com/windows/deployment/usmt/usmt-scanstate-syntax
    LoadState  https://learn.microsoft.com/windows/deployment/usmt/usmt-loadstate-syntax

---

## 13. WINDOW AND LOGS

Three zones, two draggable dividers, and any panel can go in any zone.
Setup fills the left column top to bottom. The right side holds Lookup
above and the output log below; double-click a Lookup row to fill the
fields on the left, right-click to add a user for a multi-user capture.
The foot carries status, progress, and the Logs path.

Summary states what Run will do: which machines, which user, where the
store lands, which options are on, and in red anything that changes or
destroys data.

View > Panels toggles panels; Customize layout under it moves them
between zones. Actions and the header cannot be hidden, and Reset
restores everything. View > Stacked layout gives a top and bottom split
for narrow screens.

### 13.1 The three logs

| Log | What | Where |
|---|---|---|
| Output log | UTW's commentary on this session | Right pane. File > Save output log |
| USMT logs | `scanstate.log`, `loadstate.log`, progress and detail logs | The Logs folder in the status bar |
| `CrashLog.txt` | UTW's own diagnostics | `Core\` |

Detail logs run at `/v:13`. The progress log is CSV and drives the
progress bar. For a failed migration open `Import_*.log` first; line 3
is the exact loadstate command.

---

## 14. THEMES

Eight themes under View > Theme: Dark (shipped default), Light, Neo
Dark, Neo Light, Fresh Water, Waste Water, Solarized Dark, Clown Fiesta.
Add one with an entry in `$Script:Themes` in `UTW-Themes.ps1`. Fonts
resolve Inter, then Segoe UI, then a system fallback.

View > Theme > Background graphics turns on a themed backdrop, off by
default and remembered per operator. Enable animations moves the art and
is off in the shipped settings. XAML mode, on by default, draws one
continuous picture behind the whole window rather than one copy per
panel.

Clown Fiesta reports a finished run as "HONK HONK! Migration
Successful!" and a failure as "HONK! Migration failed!". Cosmetic only:
the verdict, exit code, and log are identical.

---

## 15. TROUBLESHOOTING

USMT's own exit codes are in section 16.2. Below are UTW's failures and
the ones USMT reports badly.

### 15.1 scanstate or loadstate exits instantly with a blank log

Exit `-1073741511`, `-1073741515`, or `-1073741701` (`0xC0000139`,
`0xC0000135`, `0xC000007B`) are Windows loader failures, not USMT codes.
The process died before it ran. The binaries are the wrong version for
that machine's build, almost always from an Insider or Canary ADK.

Fix: replace them with a released ADK's, build 26100 for Windows 10 and
11, keeping the tuned XML. Or drop a released set in as an
`amd64-26100` sibling and let UTW pick it. Sections 2.7 and 3.

### 15.2 "USMT has not started after N min"

The task started but nothing wrote a detail log. On the target machine,
open `C:\Windows\Temp\USMT_Temp` and check the stdout log:

| stdout log | Meaning |
|---|---|
| 0 bytes | The task never ran the batch. AppLocker, WDAC, or SRP is blocking scripts or executables in `C:\Windows\Temp`. See Task Scheduler > Library > History and the Last Run Result for `USMT_Export_*` or `USMT_Import_*` |
| Banner only | The executable started then stalled. Usual causes: the store path is unreachable from that machine as SYSTEM, antivirus holding the process, or the wrong USMT version. Try a plain share or the machine's own drive |
| Banner plus `exit code:` | The executable ran and exited normally. Look up the code. If it is a loader code, see 15.1 |

In Direct mode the store is a share on your own workstation, so if that
machine sleeps or drops off the network the capture hangs.

The check fires only if no detail log appears within five minutes, and
never again once USMT is logging.


### 15.3 "Could not stage the USMT tools"

UTW cannot reach `\\PC\C$\Windows\Temp`. Check the machine is on, that
you are a local administrator on it, and that File and Printer Sharing
is open. Your own window's elevation does not matter here.

### 15.4 "Access is denied" partway through a remote capture

The store does not grant the source computer account write access. Use
Direct mode, or add `Domain Computers` to the share and NTFS ACLs. UNC
mode failing with 0x5 is the same cause.

### 15.5 "The destination store is in use by another window"

Another UTW window is writing that store. Two captures on one store
folder produce a bad `.MIG`, so the second is refused. Finish or stop
the other window. A lock left by a crash clears once that process is
gone.

### 15.6 "USMT version mismatch" prompt before a run

UTW read `scanstate.exe` as a build newer than both machines. Almost
always an Insider ADK. Cancel, fix the binaries, run again. Section 3.

### 15.7 "Not a valid computer name"

Clean Up takes plain names: letters, digits, dots, hyphens. Anything
that could change the shape of the UNC path is refused, because that
path is handed to a recursive delete.

### 15.8 Clean Up says a machine is unreachable that is on

It reports the underlying reason. "Access is denied" is rights on the
target. "Network path not found" is name resolution or the firewall.

### 15.9 Clean Up skipped a folder or profile

Only folders containing `USMT\USMT.MIG` are offered for deletion. Every
profile is listed either as removable or with the reason it is not.

### 15.10 Config.xml is not being applied

Check File > Settings > Cross-build fix. On `auto` it applies only when
the two machines report different builds and both were readable; the
output pane states what was found. Set `yes` to force it, and confirm
`Config.xml` is in the USMT folder or beside the scripts.

---

## 16. REFERENCE

### 16.1 Base commands

UTW builds these from the window. `DOMAIN` is your NetBIOS domain, set
under File > Settings.

    scanstate "D:\USMT Profiles\<user>" /i:migapp.xml /i:miguser.xml
      /config:Config.xml /v:13 /ue:* /ui:DOMAIN\<user>

    loadstate "D:\USMT Profiles\<user>" /i:migapp.xml /i:miguser.xml
      /config:Config.xml /v:13 /c /ue:* /ui:DOMAIN\<user>

That is a single profile. The rest differ only in the arguments:

| Variation | Change |
|---|---|
| All profiles | `/ui:DOMAIN\* /ui:%computername%\*` in place of `/ue:* /ui:...`, store folder named for the computer |
| Computer settings | `/ue:*\* /c` in place of the `/ui:` pair, plus `/i:MigratePublicFolders.xml` |
| Exclude OneDrive | Add `/i:ExcludeOneDriveFolders.xml` |
| Same-build migration | `/config:Config.xml` is dropped. Section 8.3 |

### 16.2 USMT exit codes

Full list:
https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes

UTW prints the meaning and links that page on a failure.

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Non-fatal errors, run continued. Needs `/c` |
| 11 | Bad command line. Check the Expert panel |
| 26 | Start-up failure: bad XML, more than one Windows install, or unknown |
| 27 | Store not found at the expected path |
| 33 | Could not read the encryption key |
| 71 | Could not initialise. Usually not elevated on the machine being migrated |
| 72 | V2V arbitration failure. Section 8 |
| 73 | Catastrophic failure. Store may be corrupt or the disk full |
| `-1073741511` and similar | Not a USMT code. Windows loader failure, section 15.1 |

### 16.3 Files

See the Layout table in README.md.

### 16.4 Run-time paths

| Path | Contents |
|---|---|
| `<USMT>\Logs\Export_*.log` | Full scanstate detail log |
| `<USMT>\Logs\Import_*.log` | Full loadstate detail log. Line 3 is the command |
| `<USMT>\Logs\*_progress_*.log` | CSV progress log |
| `<USMT>\Logs\Export_stdout_*.log` | Banner, console output, and exit code |
| `<USMT>\USMT-VERSION.txt` | The USMT build UTW detected |
| `Core\UTW_Settings_<user>.json` | Saved GUI settings |
| `Core\CrashLog.txt` | Script-level diagnostics |
| `<store>\export_complete.json` | Written after a successful export |
| `<store>\.usmt_store.json` | Marker for a store whose folder name does not match |
| `\\PC\C$\Windows\Temp\USMT_Temp\` | Remote staging folder. Created and cleaned up automatically |

END OF DOCUMENT
