# User Transfer Wizard (UTW)

**Technical Documentation & Troubleshooting Guide**

## Overview

The User Transfer Wizard (UTW) is a PowerShell GUI wrapper around Microsoft's User State Migration Tool. It runs `scanstate.exe` to capture a user profile off one machine and `loadstate.exe` to restore it onto another, and handles the work USMT does not: staging the binaries on the far machine, pre-flight checks, tailing the logs, cleaning up afterwards, and comparing the two machines when the migration is done.

It is Windows PowerShell 5.1 and WinForms. There are no modules to install and nothing to compile.

Migrations can run locally, remotely over admin shares, or by way of an external drive. Every USMT command is built from what is entered in the window; the scripts do not need editing to change options.

This document covers how the tool works internally, what its own failures mean, and how to fix USMT error 72. For getting started, see `README.md`.

---

## 1. Environment and prerequisites

### Permissions

USMT needs elevation to read profile registry hives (`NTUSER.DAT`) and protected directories, so UTW normally runs elevated. `UTW-Launcher.bat /noadmin` starts it unelevated for local browsing and Compare only.

For remote work you need local administrator rights on both machines and a reachable `C$` admin share on each.

Elevation on the technician machine is not what grants remote access. A network logon by a domain admin account gets an unfiltered token whether or not the local window is elevated. A local, non-domain account does not.

### Required files

These must be present in the configured USMT folder:

| File | Purpose |
|---|---|
| `scanstate.exe` | Captures user profile data to a `.MIG` store |
| `loadstate.exe` | Restores user profile data from a `.MIG` store |
| `UsmtUtils.exe` | Extracts `.MIG` files for manual recovery or verification |
| `migapp.xml` | Application settings migration rules. Microsoft's, unmodified |
| `MigUser.xml` | User profile data rules. **Use the copy in this repo**, not the stock file — see section 5 |
| `MigratePublicFolders.xml` | Captures `C:\Users\Public` on computer-settings runs. In this repo |
| `ExcludeOneDriveFolders.xml` | Optional. Skips folders synced to OneDrive. In this repo. Read section 5 before using it |
| `Config.xml` | Strongly recommended. Excludes the three components that cause error 72. In this repo; see sections 5 and 9 |

The USMT binaries are Microsoft's to distribute and are not shipped with UTW. Install the Windows ADK's *User State Migration Tool* feature and point UTW at the `amd64` folder on first run.

The four XML files above **are** in this repo, and copying them into that folder is worth doing before the first migration. Section 5 covers what each one changes.

`Config.xml` must sit beside the script or in the USMT folder. It is staged with the tools on remote runs. Without it, **exit 72 is likely** on cross-build migrations.

### Settings

Settings are written next to the script as `UTW_Settings_<operator>.json`, one file per operator, so two people sharing a folder do not overwrite each other. `UTW_Settings.json` holds the shipped defaults; the per-operator files are not committed.

Saved settings include the USMT folder path, last-used machine and user names, the selected theme and operation, panel layout, divider positions, and the OneDrive detection options.

Divider positions and panel arrangement are stored at design scale, so they mean the same thing on a laptop and on a 4K monitor.

**File ▸ New window** (Ctrl+N) opens a second instance carrying the same settings, for migrating two machines at once. Machine names are deliberately left blank in the new window. Only the first window saves settings on close.

---

## 2. How a remote migration works

There is no WinRM in this environment, so UTW does not use it. A remote run is four steps:

1. Copy the USMT binaries to `C:\Windows\Temp\USMT_Temp` on the target, over its `C$` admin share.
2. Write a `.bat` there that runs scanstate or loadstate and captures the exit code.
3. Create a one-shot scheduled task through `schtasks.exe` over DCOM/RPC, running as `SYSTEM`, and start it.
4. Tail the USMT progress and detail logs back over the same admin share.

**The consequence that matters:** the task runs as `SYSTEM`, and SYSTEM's identity on the network is the **computer account** (`DOMAIN\PCNAME$`), not the technician. Any network location the capture writes to must grant access to that computer account. This accounts for most "access is denied" failures that appear halfway through an otherwise healthy run.

Task completion is detected using the Windows `STILL_ACTIVE` exit code (267011), which is language-independent and therefore correct on non-English Windows. The detail log is scanned independently as a fallback.

---

## 3. Operation modes

| Operation | Tool | Purpose |
|---|---|---|
| Export (capture) | `scanstate.exe` | Writes user profile data to a `.MIG` store |
| Import (restore) | `loadstate.exe` | Restores profile data onto the new machine |
| Export + Import | both | Both legs in one run, machine to machine |
| Export computer settings | `scanstate.exe` | System-level settings and Public folder contents only; all user profiles excluded with `/ue:*\*`. Store folder is named `Settings_COMPUTERNAME` |
| Import computer settings | `loadstate.exe` | Restores a computer-settings store. Needs the old computer name to find it |
| Extract profile | `UsmtUtils.exe` | Unpacks a `.MIG` into a normal folder tree for manual recovery |

Export + Import over the network runs in three phases:

| Phase | Operation | Detail |
|---|---|---|
| 1 | Remote ScanState | Binaries staged to `\\SourcePC\C$\Windows\Temp\USMT_Temp`; scheduled task runs scanstate as SYSTEM; progress tailed over UNC |
| 2 | Transfer | The store is copied from the source to `\\DestPC\C$\USMT Profiles\<user>`. Source `USMT_Temp` is cleaned up |
| 3 | Remote LoadState | Binaries staged on the destination; scheduled task runs loadstate as SYSTEM. On success the store and `USMT_Temp` are deleted from the destination |

---

## 4. Command construction

### XML rules

- `migapp.xml` and `miguser.xml` are always included.
- If *Exclude OneDrive folders* is ticked, `ExcludeOneDriveFolders.xml` is added as another `/i:` argument.
- If `Config.xml` is present in the USMT folder, `/config:Config.xml` is added automatically to **both** scanstate and loadstate. This is the primary defence against error 72.
- Import always includes `/c` so non-fatal errors do not stop the run.

### Profile targeting

| Mode | Arguments | Description |
|---|---|---|
| Single profile | `/ue:*` `/ui:DOMAIN\Username` | One specific domain user. Every other profile is excluded |
| All profiles | `/ui:DOMAIN\*` `/ui:%computername%\*` | Every domain and local profile on the machine |
| Computer settings | `/ue:*\*` | Excludes all profiles, domain and local. Captures System-context settings and Public folder contents only |

### Completion flag

On a successful export UTW writes `export_complete.json` to the store path, holding the source computer name, the timestamp, and the technician account. The import workflow reads it to confirm the store is ready.

A `.usmt_store.json` marker is also written so that a store folder can be discovered by name mismatch rather than failing, which is what caused exit 27 on all-profiles imports before.

---

## 5. The included migration XML

USMT ships with generic rules. The four XML files in this repo are the tuned versions used in production, and dropping them into the USMT folder is the single change that makes the most difference to what actually arrives on the new machine. Three of them are additions; `MigUser.xml` replaces Microsoft's stock file.

| File | Status | Effect |
|---|---|---|
| `Config.xml` | Addition | Excludes three components that abort loadstate with error 72 |
| `MigUser.xml` | Replaces stock | Adds browsers, Outlook profiles, Downloads, file associations and printers |
| `MigratePublicFolders.xml` | Addition | Captures `C:\Users\Public` during computer-settings runs |
| `ExcludeOneDriveFolders.xml` | Addition, optional | Skips folders already synced to OneDrive |

Put them in the same folder as `scanstate.exe` and `loadstate.exe`. UTW picks up `Config.xml` and `MigratePublicFolders.xml` on its own; `ExcludeOneDriveFolders.xml` is added only when the OneDrive option is on. `MigUser.xml` is always passed, so replacing the stock file is all that is needed.

### Config.xml

Generated with `/genconfig` and then edited. Of its 156 components, three are set to `migrate="no"` — `Microsoft-Windows-Pcrpf`, `Microsoft-Windows-Win32k-Settings` and `Microsoft-Windows-Printing-WindowsProtectedPrint`. Everything else is left at `migrate="yes"`, so this is not a restrictive filter; it turns off exactly the three components that cause error 72 and changes nothing else. See section 9 for why those three.

The component IDs in this file are the generic `migxmlext` URI form, not build-stamped assembly strings, so **this file is portable across Windows builds as it stands**. It does not need regenerating per build. If a `/genconfig` run on some future build does produce IDs carrying version numbers, that output would be build-specific and would need regenerating — but the file shipped here is not.

### MigUser.xml

Microsoft's stock `MigUser.xml` covers Documents, Desktop, Pictures, Music, Video, Favorites, Quick Launch, the Start Menu, and a long list of document extensions across all fixed drives. This version keeps all of that and adds six components:

| Component | What it carries |
|---|---|
| Chrome Browser Data | `%CSIDL_LOCAL_APPDATA%\Google\Chrome` — profiles, bookmarks, saved passwords, extensions |
| Firefox Browser Data | `%CSIDL_APPDATA%\Mozilla` and `%CSIDL_LOCAL_APPDATA%\Mozilla\Firefox` |
| Outlook Settings | `HKCU\Software\Microsoft\Office\*\Outlook` and the Windows Messaging Subsystem profiles — mail profiles, so Outlook does not rebuild from scratch |
| User Downloads | `%CSIDL_PROFILE%\Downloads`, which stock `MigUser.xml` does not migrate at all |
| User Program Defaults | `FileExts`, `HKCU\Software\Classes`, and the Shell `Associations` keys — the "open with" choices |
| Printers and Drivers | `HKCU` printer settings and default device, the `HKLM` Print control keys (Printers, Environments, Forms, Monitors, Providers), driver registry entries for x64 and x86, and `%CSIDL_SYSTEM%\spool` |

The Downloads and Outlook components are the two that get noticed. Everything else in the list is a matter of the new machine feeling like the old one on the first morning rather than the third.

**A caution on the printer component.** It carries `HKLM` print configuration and the contents of the spool folder, which includes driver binaries. Between two machines on the same build and the same hardware class this is what makes printers simply appear. Across different builds, or onto a machine with a different architecture or a driver already installed at a different version, it can produce a queue that exists but does not print. Where a print server or Group Policy already deploys printers, that mechanism will do it correctly and this component is redundant. If printers are the thing going wrong after a migration, this component is the first place to look.

### MigratePublicFolders.xml

A `System`-context component covering `%PUBLIC%\Documents`, `Desktop`, `Downloads`, `Music`, `Pictures` and `Videos`.

Computer-settings operations exclude every user profile with `/ue:*\*`, which also excludes the Public profile, so without this file a settings-only capture takes no Public data at all. Shared files that live in `C:\Users\Public` — which in practice is where a lot of departmental scanning and shared spreadsheets end up — would be lost. UTW adds this file automatically on computer-settings runs.

### ExcludeOneDriveFolders.xml

The name describes the intent rather than the mechanism, which is worth understanding before ticking the box.

The file does not look for a folder called OneDrive. It sets an `unconditionalExclude` on `%CSIDL_MYDOCUMENTS%`, `%CSIDL_DESKTOP%` and `%CSIDL_MYPICTURES%`, plus `*.tmp` on all fixed drives. Where OneDrive Known Folder Move is in effect, those three CSIDLs already resolve to the folders inside OneDrive, so excluding them skips exactly the data that will sync back down on its own. That is the whole point: capturing it doubles the migration time and then arrives twice.

**`unconditionalExclude` beats every include rule, including the ones in `MigUser.xml`.** So on a profile where Known Folder Move is *not* in effect, this file drops the user's local Documents, Desktop and Pictures — the three folders they care most about. Nothing warns about it, and the store simply comes out small.

This is why UTW measures the OneDrive folders on disk before offering the exclusion, rather than trusting AD group membership. See section 7. If you are running scanstate by hand rather than through UTW, confirm Known Folder Move is actually redirecting those folders before adding this `/i:`.


---

## 6. Where the store goes

| Store type | Reachable by | Runs |
|---|---|---|
| New PC (direct) | Both machines at once. UTW creates a temporary share on the new PC granting exactly the source computer account, then removes it | One |
| Network share (UNC) | Both machines at once, if the ACLs allow it | One |
| External / USB drive | One machine at a time | **Two** |

### Network share requirements

Effective SMB access is the **intersection** of the share ACL and the NTFS ACL. Both must allow the write.

Because the capture runs as SYSTEM, the account that needs write access is the source machine's computer account. In practice that means adding `Domain Computers` to both the share and NTFS ACLs of the network location. Without that change, UNC mode cannot work, whatever the tool does.

*New PC (direct)* mode avoids the issue entirely by creating a temporary share that grants exactly the one computer account, and removing it afterwards.

### Why a drive store is two runs

Selecting **Export + Import** greys out *External / USB drive* in the Save to list.

Every other store type works in one run because both machines can reach the store at the same moment. A drive is reachable by exactly one machine at a time, and the step that changes that is a person carrying it. There is no point at which LoadState could succeed.

The workflow is:

| Step | Where | What |
|---|---|---|
| 1 | Old PC, or remotely to *its* drive | **Export** to `D:\USMT Profiles\<user>` |
| 2 | — | Unplug, carry, plug in |
| 3 | New PC | **Import**, browsing to the store on the drive |

Import accepts the store root, the `USMT` subfolder, or the `.MIG` file itself.

The export leg can still be remote: fill in *Capture from* and ScanState runs on the old machine, writing to that machine's own drive. That is the answer when the old PC's C: is full but it has an external disk plugged in.

The *destination* is what goes unavailable, never the operation. Choosing Export + Import moves the store to the new PC without comment, because the drive greying out in the same instant explains itself. The only message appears if you go on to click the greyed drive anyway.

---

## 7. OneDrive detection

Before a single-profile capture, UTW checks whether the profile is on OneDrive and offers to exclude it. Two signals are used: a matching folder in the profile, and membership of the AD group named in `OneDriveGroup` (default `OneDriveUsers`).

Where OneDrive is deployed to everyone, both signals are true of everyone and discriminate nothing. That is what the size threshold is for. The prompt only appears when the OneDrive folders actually hold more than *Ask above* MB **on disk**. Cloud-only files count as nothing, so a fully dehydrated OneDrive never prompts however large it looks in Explorer — excluding it would save nothing.

A measurement always beats group membership. If the folders were measured and came in under the threshold, being in the group does not re-raise the prompt.

Settings live in **File ▸ Settings**, under *OneDrive detection*:

| Setting | Meaning |
|---|---|
| Check OneDrive before a capture | `no` = never ask about OneDrive at all |
| OneDrive group | AD group whose members are treated as OneDrive users |
| OneDrive folders | Wildcard for what counts as OneDrive. `OneDrive*` matches the tenant folder and a personal one; `OneDrive - *` matches tenant folders only. `<user>` expands to the profile name |
| Ask about OneDrive above (MB) | Locally-held data before prompting. `0` = ask whenever a folder exists |

---

## 8. Deleting stale user profiles

`sysdm.cpl` — System Properties ▸ Advanced ▸ User Profiles ▸ Settings — has no command line and cannot be pointed at another machine, so it cannot be automated. UTW uses `Win32_UserProfile`, which is what that dialog drives underneath and *is* remotable over DCOM.

This matters beyond convenience. `Win32_UserProfile.Delete()` removes the profile folder **and** its `ProfileList` registry entry. Deleting `C:\Users\<name>` by hand leaves the registry entry behind, and the next sign-in gets a temporary profile — a worse problem than the disk space it freed.

**Delete stale user profiles** in Options applies both to Clean Up and to a capture. Either way it is the same two steps:

1. **A ticklist**, one row per profile, with computer, account, age and folder. **Nothing is ticked when it opens** — you say yes to each account rather than no to the ones you did not mean. *Select all* and *Select none* are there for when you do mean all of them. Profiles that cannot be deleted are listed too, greyed out with the reason, so none go quietly missing.
2. **A confirmation** listing exactly what was ticked, and nothing else.

Cancelling the ticklist abandons the whole clean up, including anything already agreed to on earlier dialogs.

Never offered: system and built-in profiles, anything under `\Windows`, profiles that are signed in, your own, and anything used inside the inactivity window (90 days). The rules are re-checked at delete time, since someone can sign in while the confirmation is on screen. On a capture, the profile that run just captured is never in the list — removing it is a separate decision with its own Expert option and its own confirmation.

**Age is evidence, not proof.** `LastUseTime` is often empty, in which case the profile folder's own timestamp stands in, and the output says which was used. A backup agent or AV sweep touching a profile can refresh either date.

**Clean up USMT files** also removes the store folder itself (`USMT Profiles` by default) once the stores inside it are gone, so a cleaned machine has no leftover folder on the root of C:. It refuses unless the folder's name matches the configured store folder exactly, it sits directly under a drive or share root, and not a single file is left anywhere inside it.

---

## 9. USMT error 72: V2V arbitration failure

> **Error 72 aborts loadstate before any data is restored.** No partial migration occurs, the destination profile is untouched, and the `.MIG` store is intact. The migration can be retried once the fix below is applied.

### What it is

Error 72 occurs during the V2V (version-to-version) arbitration phase of loadstate. Before applying any data, USMT checks each component captured in the store against what the destination OS supports. If a component is flagged as critical in the store but is not present on the destination, USMT fails with error 72 **even when `/c` is specified**.

This is not a network, permissions, or disk space problem. It is a component compatibility mismatch between the source and destination OS builds.

### Components observed causing it

| Component | What it is | Why excluding it is safe |
|---|---|---|
| `Microsoft-Windows-Pcrpf` | Platform Configuration Register profiles; TPM/Secure Boot measurement configuration | Hardware-specific. Meaningless on a different machine with a different TPM. No user data |
| `Microsoft-Windows-Win32k-Settings` | Low-level kernel graphics subsystem flags (GDI, DWM composition) | OS-version-specific, and typically default or policy-managed. No user data |
| `Microsoft-Windows-Printing-WindowsProtectedPrint` | The Windows Protected Print Mode security toggle (Win11 24H2+) | A single on/off policy setting. It does **not** control printer migration — printer connections, queues and per-user preferences are handled by `migapp.xml` and are unaffected |

### Root cause

These components are in the store because the source machine runs a newer Windows 11 build (for example 24H2, build 26100) that has them registered. The destination is on an older build that does not. USMT flags them internally as critical, which overrides `/c`.

Same-build migrations are unaffected. Newer-to-older is the case at risk. Windows 10 to Windows 11 appears unaffected.

### Confirming it

Open the `Import_*.log` from the failed run, in `\\DestinationPC\C$\Windows\Temp\USMT_Temp\Logs\`. Line 3 holds the command that ran. Search the log for the V2V arbitration line reporting that the source migration unit is critical, followed by USMT error code 72. If both are present, the fix below applies.

### Generating a correct Config.xml

**A working `Config.xml` is already in this repo.** Copy it into the USMT folder and the problem is solved; it is portable across builds, for the reason given in section 5. The procedure below is how it was made, and is what to repeat if a future build turns up a fourth component.

1. Open an elevated command prompt on the destination machine, or any machine on the same Windows build.

2. Generate the file. `USMT_Temp` will still be present from the failed import; otherwise stage the USMT tools manually:

   ```
   C:\Windows\Temp\USMT_Temp\scanstate.exe /genconfig:C:\Temp\Config.xml /v:5
   ```

3. Open `C:\Temp\Config.xml` and find each of the three components in the table above.

4. For each one, change `migrate="yes"` to `migrate="no"`. Leave the `ID` attribute exactly as it is — it must not be changed.

   ```xml
   <!-- Before -->
   <component displayname="Microsoft-Windows-Pcrpf" migrate="yes"
     ID="http://www.microsoft.com/migration/1.0/migxmlext/cmi/microsoft-windows-pcrpf/microsoft-windows-pcrpf/settings"/>

   <!-- After -->
   <component displayname="Microsoft-Windows-Pcrpf" migrate="no"
     ID="http://www.microsoft.com/migration/1.0/migxmlext/cmi/microsoft-windows-pcrpf/microsoft-windows-pcrpf/settings"/>
   ```

5. Save it as `Config.xml` and place it in the USMT tools folder alongside `scanstate.exe` and `loadstate.exe`. Leave the other 153 components alone — the point is to disable three, not to filter the migration.

6. UTW detects it and passes `/config:` to both scanstate and loadstate on the next run. Nothing else needs changing.

**`Config.xml` must be present during the export, not only the import.** The components are excluded at capture time; a store written without it still carries them.

### Verifying the fix

Open the new `Import_*.log` and check line 3. The command should include:

```
/config:"C:\Windows\Temp\USMT_Temp\Config.xml"
```

If that argument is absent, `Config.xml` was not found in the USMT tools folder and was not staged to the remote machine. Confirm the file exists beside `scanstate.exe`.

---

## 10. UTW-level failures

Anything with a USMT exit code is Microsoft's, and the tool prints the meaning of the code and links the reference page when a run fails. The failures below are UTW's own — staging tools, creating shares, scheduling tasks, locking a destination — and have no USMT error code, which is why they are documented here.

#### "Could not stage the USMT tools"

UTW cannot reach `\\PC\C$\Windows\Temp`. Check the machine is on, that you are a local administrator on it, and that File and Printer Sharing is open to it. Being an administrator is what matters, not whether UTW is elevated.

#### "Access is denied" partway through a remote capture

The store location does not grant the **source computer account** write access. Either use *New PC (direct)* mode, which creates a temporary share granting exactly that account and then removes it, or add `Domain Computers` to the share and NTFS ACLs of the network location.

#### Network share (UNC) mode does nothing, or fails with 0x5

Same cause. The share needs `Domain Computers` write access.

#### "The destination store is in use by another window"

A second UTW window is already migrating to that store. Two captures writing one store folder produce a `.MIG` that restores badly, so the second is refused. Finish or stop the other window, or point this one elsewhere. A lock left behind by a crashed window is released automatically once that process is gone.

#### "Not a valid computer name"

Clean Up accepts plain machine names only — letters, digits, dots and hyphens. Anything that could change the shape of the UNC path it builds is refused, because that path is handed to a recursive delete.

#### Clean Up says a machine is unreachable that is plainly on

It reports the underlying reason. "Access is denied" and "network path not found" mean different things: the first is rights on the target, the second is name resolution or the firewall.

#### Clean Up did not offer a folder that is clearly in the store area

Only folders that really contain `USMT\USMT.MIG` are offered for deletion. Anything else is listed as "left alone". This is deliberate.

#### Clean Up did not offer a profile I expected

Every profile is listed either as removable or with the reason it is not: *system profile*, *built-in account*, *lives under Windows*, *signed in right now*, *that is you*, or *used N days ago*.

"Signed in right now" is the common surprise. `Win32_UserProfile.Loaded` is true for **any** profile with a loaded registry hive, including other sessions and service accounts, so on a live machine most profiles look busy. Run the clean up against a machine the users have signed out of.

---

## 11. Expert mode

*Mode: Expert* in the header, or **View ▸ Expert**, adds a panel showing the exact USMT command line each leg will run — two of them for Export + Import, since that is genuinely two runs on two machines.

The panel reads top to bottom: the command, the buttons that act on it, the USMT build to use, log-on-exit, and then, fenced off below a red rule, the two options that change or destroy data.

- Editing the text updates the Options above, and the reverse. Removing `/o` unticks *Overwrite*; removing the OneDrive XML unticks *Exclude OneDrive folders*.
- Switches UTW does not model — `/vsc`, `/encrypt`, `/hardlink`, `/nocompress`, `/uel`, `/md`, `/mu` and the rest — are kept exactly as typed and survive regeneration.
- **Regenerate** discards both the edits and the custom switches.
- **Copy** and **Paste** move the whole command through the clipboard. Pasting replaces the panel and the options follow it; Ctrl+V still inserts at the cursor.
- **Switching back to Simple does not undo an edit.** UTW asks whether to discard or keep. Kept edits put *custom command* in the title bar, and every run announces that it is using the edited command rather than the one the options describe.
- Nothing validates USMT syntax. There are too many options for that to be anything but a source of false rejections, and USMT reports a bad command line clearly as exit 11.

The pre-check options — *Profile exists*, *Free disk space*, *Inactive profiles*, *Measure profile size* — are UTW's own and deliberately have no command-line equivalent, so they do not appear in the panel.

Switch reference: [ScanState](https://learn.microsoft.com/windows/deployment/usmt/usmt-scanstate-syntax) · [LoadState](https://learn.microsoft.com/windows/deployment/usmt/usmt-loadstate-syntax)

---

## 12. The window

The window is three **zones** with two draggable dividers, and every panel can be sent to any zone.

| Where | What starts there |
|---|---|
| Left column | The setup, top to bottom in the order it is filled in: Header, USMT Location, Operation, Migration Details, Options, (Expert), Actions, Summary |
| Right, top | **Lookup** — the profiles on the machine being captured, or the stores this operation would read. Double-click a row to fill the fields on the left; right-click to add a user for a multi-user capture |
| Right, bottom | **Output log** — what this window has done. Right-click to copy, save or clear |
| Foot | Status, progress, and the **Logs:** path — click it to open the folder |

**Summary** is a panel like any other. It fills whatever space is left in the left column and says in plain English what pressing Run will do: which machines, which user, where the store lands, which options are on, and — in red — anything that will change or destroy data.

### Moving the panels

**View ▸ Panels** has a tick for every panel. **View ▸ Panels ▸ Customize layout** is the full editor:

- **Drag a row** to move it — within its zone to reorder, or onto another zone's heading to send it there. An insertion mark shows where it will land.
- **Click a row's "Where" cell** and pick a zone from a list. Same result, discoverable rather than dragged.
- There is a **Hidden** section at the bottom. Drag a panel in to put it away, out to bring it back.

Actions and the header can be moved but not hidden — without them there is no way to start a migration and no way back to Expert mode. **Reset** puts everything back.

Panels stretch to fill their zone and their contents stretch with them: drag the divider right and the machine boxes, the Run button and the Expert command line all widen. They will not shrink below the width they were designed at — nothing can make a labelled row narrower than its label plus its box — so the divider stops there, and a panel sent to a narrower zone gets a scroll bar rather than being clipped.

Every dialog — Settings, the store browser, the user picker, AD search, Customize layout — can be resized and maximized, and the last column of each list takes up the slack, so widening the window widens the column most likely to be truncated.

This is not free-form docking. It is zone placement plus ordering plus two dividers, which is what fits in a WinForms app without carrying a docking framework.

### Why a panel never collapses to nothing

Zones stack their panels with `Dock`, and the one marked *Fill* takes whatever the fixed-height ones leave. When those add up to more than the zone, that is **nothing at all** — measured, the Fill panel goes to height 0. Turning Expert mode on adds a tall panel and did exactly that to the summary: it vanished, and scrolling did not bring it back, because a zero-height control adds nothing to scroll to.

Every Fill panel therefore carries a minimum height as well as a minimum width.

That alone was not enough to reach it. `AutoScroll` works its range out from children *positioned* past the edge, and a docked child never is — Dock lays out inside whatever room is left. So the scroll range stayed at the visible height and stopped at the last panel that happened to fit, leaving the summary real, sized and unreachable. Each zone now sets `AutoScrollMinSize` to the true height of its stack, which it knows exactly, having just laid it out.

`tests\layout.ps1` fails if any Fill panel drops below 40px or has no floor.

### The three logs

| Log | What it is | Where |
|---|---|---|
| Output log | UTW's running commentary on this session | The pane on the right; **File ▸ Save output log** |
| USMT logs | `scanstate.log`, `loadstate.log`, `progress.log` | The **Logs:** folder in the status bar |
| `CrashLog.txt` | UTW's own diagnostics, including the finished window geometry | Beside the script |

The USMT detail logs run at `/v:13`. The progress log is CSV and is what drives the progress display in the window. When diagnosing a failed migration, check `Import_*.log` first: line 3 is the exact loadstate command that ran, which confirms what was actually passed.

---

## 13. Themes and the Neo design system

The palette, type scale and spacing come from the Neo design system (`designSystemTemplate.responsive.v10` / `neo-template-demo-vite-v10`). Those are CSS custom properties; `UTW-Themes.ps1` holds the same set in a form WinForms can use, under `$Script:Tokens`.

**Neo Dark** is the default and **Neo Light** is the same palette inverted. The six original themes are unchanged and still present.

Two places the mapping is deliberately not literal, both noted in the code:

- `--primary` is near-white in the dark palette, because in that system "primary" means a high-contrast surface. In UTW `Primary` is the *accent* — group captions, the title, the Run button. Taking the name rather than the meaning gives a white Run button with white text, so UTW's `Primary` maps to `--info`.
- `--card` equals `--background` in the dark palette, which would make every group box invisible against the form. Panels take `--muted`.

`--radius` and the shadows do not transfer. WinForms controls are rectangles, and rounded corners need owner-drawn painting on every button. The values are recorded in `$Script:Tokens.Radius` so that work, when it happens, uses the right numbers.

### Adding or changing a theme

Add an entry to `$Script:Themes` and it appears in **View ▸ Theme** on its own; the menu and the picker both read `Get-ThemeNames`. An `Accents` block is optional, and anything it leaves out falls back to the shipped colours, so the operation colours stay recognisable.

`tests\theme.ps1` then checks it automatically: every tagged control type takes the new colours, body and dim text clear their panel, the log clears its background, the divider is visible, and every filled button's label is legible on its fill. Text on an accent is computed by `Get-ContrastingText` rather than assumed white, so a pale accent gets dark text by itself.

Fonts come from `New-UTWFont`, which resolves Inter → Segoe UI → fallback once. Where Inter is not installed the tool looks exactly as it always has.

---

## 14. Background graphics

**View ▸ Theme ▸ Background graphics** turns a themed backdrop on. It is off by default and remembered per user.

Every theme has its own artwork, ported from the HTML background files rather than generated from its palette:

| Theme | Source | What it draws |
|---|---|---|
| Clown Fiesta | `clown-fiesta-bg_2.html` | Polka ground, bunting, balloons, drifting confetti, five clowns |
| Neo Dark / Neo Light | `neo-*-bg.html` | Base wash, three aurora ribbons, light shafts, four glass panes with a specular sweep, rising motes |
| Fresh Water | `freshwater-bg.html` | Lit water, three sliding swooshes, a shimmer band, bubbles |
| Waste Water | `wastewater-bg.html` | Settled bands, morphing blobs, drifting scum, bubbles |
| Solarized Dark | `solarized-dark-bg.html` | A sun below the horizon: a wheel of coloured rays, a breathing corona, horizon haze, a terminal cell grid |
| Dark / Light | `metro-*-bg.html` | Two accent glows and six crawling diagonals |

None is a pixel copy — the Clown Fiesta source alone is 308 SVG elements including 41 bezier paths — but each is made of the same things in the same palette. A theme added later without artwork of its own falls back to a default painter that still draws a picture, not just a gradient.

The backdrop runs behind the panels too, not only the header: 14 surfaces carry it.

### Legibility

Legibility is bought two different ways. The panels and the log dim the artwork, to 42% and 26%, and wash the panel colour back over it, at levels that were searched rather than guessed. The banner does the opposite: it keeps the artwork at full strength and protects its title with a halo, which is what the source files do (`text-shadow: 0 0 34px var(--glow)`).

That is not a stylistic choice. With Clown Fiesta's white gloves under light title text the banner measures 1.01:1, and the dimming needed to fix it is 193 of 255, which erases the picture.

**There is no text halo, and there cannot be one.** It was built three times. A Label paints its text with `TextRenderer` (GDI); a halo drawn with `Graphics.DrawString` is GDI+, and the two lay the same string out 1px apart — measured. An outline around text that is itself a pixel off lands 2px on one side and flush on the other, which is what kept being reported as a weird duplicate or a one-sided shadow. GDI text cannot be drawn translucently, so there is no aligned version to fall back on.

Instead the banner's caption band is scrimmed: the top 62% fades into the theme's own dark ground and the bottom keeps the picture at full strength, which is where the clowns are standing anyway. A gradient is not text and cannot be misaligned with anything. The clowns are drawn at 62% height on the banner so they stay clear of the band, and full height everywhere else.

Light grounds are tuned on their own numbers rather than sharing the dark ones — a wash that reads clearly over `#04121c` disappears entirely over `#ffffff`. Broad glows there take roughly double the alpha, but the small hard-edged marks do not: a dark accent dot on white is already a far bigger jump than the same dot on charcoal, and boosting those is what turns a backdrop into noise.

### Transparency

All 48 captions are transparent, and nothing cheaper works. Two flat-colour schemes were tried and both showed. One colour per surface cannot match, because every panel is a different size and shows a different crop of the artwork. Sampling the backdrop under each caption is closer but still a flat fill over a gradient, so a wide caption sits in a visible patch. The artwork behind text is not flat, so no flat colour will ever disappear into it.

Transparency was never the wrong answer — the paint handler being expensive was. A transparent caption is drawn by asking its parent to paint again clipped to the caption, so the handler runs once per caption, roughly 48 times per panel repaint. It now takes two fast paths when the clip is partial: the motion layers are skipped, since only the banner animates, and the group box caption is skipped unless the caption band is in the clip. With those, a divider frame is **49.6 ms against 65.2 ms** when the panels were using flat colours. The transparent version is not merely affordable, it is faster.

Group boxes paint their border and caption in `OnPaint`, and the Paint event fires afterwards — so blitting the backdrop over the client area covered both, and every panel lost its title the moment the graphics went on. The handler redraws them, using `TextRenderer` because that is what the control itself uses.

### The output log is tinted, not transparent

A RichTextBox and a ListView are opaque and WinForms gives no supported way round it. The see-through route was built and measured before being abandoned: a `WS_EX_TRANSPARENT` RichTextBox took **1387 ms to append 300 lines against 489 ms opaque**, 2.8×, on the one control that tells anybody what a migration actually did — and RichEdit smears it on scroll.

So the log is joined to the picture from both sides instead. Its group paints the real artwork and its padding leaves a frame wide enough to see it, and the log's own background colour is sampled from that artwork, so the two meet in the same family of colour rather than the log reading as a grey hole punched in the backdrop.

### Cost

The art is rendered once into a bitmap and blitted. With the backdrop on, a resize frame is 44 ms against 50 ms with it off — no difference. `tests\layout.ps1` fails if it ever adds more than 15 ms.

Each theme is pre-rendered once, then scaled. The painters are real artwork — a Clown Fiesta banner is 250-odd shapes, a Solarized ray wheel is 16 gradient-filled wedges — and re-running them at every size made resizing and theme-switching both stall. Each `(theme, surface, layer)` is now painted once into a master bitmap, and every size the window asks for is a scaled blit off that master, cover-cropped to the target's aspect and anchored to the bottom, because that is where the clowns stand. The master is produced by the same painter, so there is nothing to keep in step and no files to ship.

| | Before | After |
|---|---|---|
| A new size (what a resize pays) | 20–40 ms | **1.4–2.0 ms** |
| A theme switch, all surfaces cold | This, repeatedly, at every size | ~300–550 ms once |

Masters survive a resize, and two themes' worth are kept, so flipping back to a theme you were just on costs 47 ms instead of re-rendering every surface (272 ms, or 847 ms for Clown Fiesta). Toggling the animation does not discard them either; that used to route through the same path and stalled for a full re-render to change something that alters no pixels.

Clown Fiesta draws its clowns on the banner only. A clown is about 50 shapes and five of them is the most expensive thing any painter does. On a panel the artwork is dimmed to 42% and then washed with 140 of panel colour, and on a zone the clowns sit behind the panels — so they were being drawn where they cannot be seen. First visit to Clown Fiesta went from 1072 ms to 707 ms.

Caching by size is wrong during a drag: the size changes every frame, so every frame is a miss. Mid-drag the last bitmap is reused and the correct one is drawn when the drag ends, and sizes are quantised to a 64px grid so small movements do not miss at all.

### Verifying artwork

Two things go wrong with a painted backdrop and neither is visible in the source, so `tests\overlay.ps1` asserts both.

**It draws nothing.** The first version of the Clown Fiesta artwork put the confetti and balloons on the motion layer only, so with animation off the backdrop was a gradient and a stripe. Each theme's banner must now carry at least 150 distinct colours; they run from 962 to 2422, against 119–260 before.

**It draws too much.** The test measures WCAG contrast between each theme's own text colour and the worst pixel that text could land on, holding panels and the log to 4.5:1 (small text) and the haloed banner title to 3:1 (large text). That replaced a cruder check that gated on how far the busiest pixel strays from the average, which cannot tell a big smooth clown from a field of hard-edged confetti, and failed the clown for being a picture.

---

## 15. Animation

**View ▸ Theme ▸ Enable animations** is on by default, so switching the graphics on gives you the artwork moving, and this is the switch to turn that off. The graphics themselves are off by default, so nothing animates until somebody asks for a backdrop. It is greyed out unless the graphics are on and the theme has something that moves, which every theme with artwork now does.

Whether the timer runs is decided in exactly one place, `Set-OverlayEnabled`. Restoring saved settings used to set the animate flag and then turn the graphics on, which left the flag true and the timer stopped, so a tool closed with the animation running came back up showing a still picture.

It costs **7.3 ms a frame at 20 fps, about 15% of one core**, and it is done by scrolling rather than redrawing:

- The backdrop is layered. **Ground** is static. **Motion** and **motion2** are transparent bitmaps each drawn twice at a wrapping offset, so they drift endlessly for the cost of two blits apiece.
- Two layers travel opposite ways at different speeds — confetti falling at 5px a tick past balloons rising at 3. One layer drifting at 2px a tick was the old version, and it read as a picture sliding rather than as motion.
- **Only the header moves**, and this was measured twice rather than assumed. With the panels animated and the timer instrumented, frames arrived 643, 674 and finally 1,105 ms apart. The window stopped responding even after the animation had backed itself off to 400 ms, because `Application.DoEvents` never drains a queue filling faster than it empties.

  The blits are not the problem: a panel-sized ground plus four motion blits measures 1.5 ms, so all of them together are about 20 ms. The rest is WinForms compositing the 48 transparent captions, since a caption with a transparent background is rendered by asking its parent to paint again clipped to the caption. Invalidating one panel costs one paint per caption on it. That is the same transparency that removed the boxes from behind the text, and it is worth more than moving confetti behind a form.

- There is an **overrun guard** regardless, for slow machines and remote sessions: it compares the frame interval actually achieved against the one asked for and backs off to a 400 ms ceiling. The first version timed the tick body and never fired, because the body only posts `Invalidate` calls and is fast by construction; the expense is the painting that follows.
- The painting stands down during a resize, not just the timer. Otherwise every resize frame still paid for four alpha blits of a banner-sized layer.
- The halo is cached. Drawing it live cost 1.2 ms per caption on every frame, a quarter of the budget spent redrawing an identical picture.
- Surfaces other than the banner quantise their size to a 64px grid, so a window resize reuses one bitmap instead of missing the cache on every frame at 20–40 ms a miss. The banner is exempt: its composition is anchored to its own edges, because the clowns stand on the bottom of it.
- The timer stands down during a resize or a divider drag, while a migration is running, and while the window is minimised. Resizing with it on measures 48.8 ms against 58.6 ms with it off — no cost.

`tests\layout.ps1` fails if a frame exceeds 15 ms or if resizing-while-animating regresses.

One thing follows the theme rather than the artwork: in **Clown Fiesta only**, a finished run is announced as *★ HONK HONK! Migration Successful!* and a failed one as *★ HONK! Migration failed!* — two honks good, one honk bad. Every other theme reports in the usual words. It is cosmetic; the verdict, the exit code and the log are identical either way.

---

## 16. Authoring artwork in XAML

A theme's ground artwork can be written as XAML instead of GDI+ calls. Drop a file in `xaml\` named `<theme>.<surface>.xaml` — `neo-dark.header.xaml` is the worked example — and it is rendered once to a bitmap at master size and fed through the same scale-and-cache path as everything else. The painter stays as the fallback, and a file that fails to parse logs once and falls back rather than breaking the window.

This is the only WPF route that fits. Hosting live WPF means an `ElementHost`, and an `ElementHost` is its own window: it can sit on top of the WinForms controls but never behind them, which is the one thing a backdrop has to do. Rendering offscreen sidesteps that entirely, because the result is a bitmap and bitmaps are what the overlay pipeline already moves around.

Measured against the hand-written painter for the same picture:

| | Colours | Spread | Render |
|---|---|---|---|
| GDI+ painter | 4034 | 193 | 256 ms |
| XAML master | 4225 | 261 | **139 ms** (warm) |

So it is faster as well as easier to author — real gradients, blur effects and rotation instead of arithmetic. The cost is a one-time ~850 ms to load `PresentationFramework` on the first file found, which is why nothing is loaded unless a `.xaml` actually exists.

All eight themes ship as XAML, one file each in `xaml\`. The surfaces differ only in how loud the artwork may be, a single number, so a per-surface file would be the same picture eight times with the opacities changed; `Get-XamlMaster` applies the surface's own quiet level instead. A `<theme>.<surface>.xaml` still wins if a surface ever needs its own composition.

**View ▸ Theme ▸ XAML mode** switches the whole set back to the GDI+ painters, which is why those are kept. Remembered per user.

Two things worth knowing before writing one:

- **`x:Shared` does not work in loose XAML.** It is honoured only in compiled resource dictionaries. A Visual has one parent, so artwork cannot be reused as a Canvas. Clown Fiesta's clown is a `VisualBrush`, which can be filled into as many rectangles as you like; that is what makes a repeated figure practical.
- **Keep bright work out of the banner's two ends.** The captions live there and the middle carries none, which is why the clowns stand in the middle. Clown Fiesta's bunting running edge to edge held the worst contrast at 1.48:1 no matter what was changed underneath it.

### One backdrop behind the whole window

With the XAML artwork on, every surface draws its own part of a single window-sized picture rather than scaling the master into its own bounds, so the panels sit on a continuous image instead of a patchwork of independent copies. Each surface washes its own region afterwards, since they carry different amounts of text. Measured at **+0.9 ms a frame** against the backdrop switched off.

It drifts, and that costs nothing. The banner animates by compositing extra transparent layers, which is why doing that on every surface once cost the better part of a second a frame. The backdrop has nothing to composite — it is one blit already — so it animates by landing that blit a few pixels further along. It ping-pongs inside the slack between the window's size and the backdrop's, quantised up to a 256px grid, so an edge can never be dragged into view.

Drifting surfaces repaint on one tick in five. The banner needs 20fps because confetti falls at 5px a tick; a backdrop that ping-pongs a couple of hundred pixels over minutes does not, and repainting all thirteen surfaces at the banner's rate took the layout suite from 25 seconds to 171 — every frame affordable, five times more of them than the picture needed.

Zones are composited (`WS_EX_COMPOSITED`) like the banner. `AutoScroll` scrolls by blitting the pixels it already has and repainting only the strip newly exposed, which is right when a background belongs to its control and wrong when it is anchored to the window: the artwork smeared and piled up as a zone scrolled. Compositing fixes it while the bar is moving; a repaint on `Scroll` fixes it when the drag ends.

**Where the artwork appears.** Behind the banner, every panel, the zones and the log; behind the splash screen; behind every dialog header (Find a computer, Settings, About — they all come from `New-ListDialog`); and as the Run button's operation glyph. The status bar needed nothing, being a registered surface already. All of it follows XAML mode, and all of it falls back to what shipped before when the toggle is off.

The Run button's glyph comes from `xaml\icons.xaml`, a sheet of five 24×24 cells rather than five files — one parse and one render for the set, cropped per cell and cached by size. The cell is chosen from the button's own caption, so what it says and what it shows cannot disagree, and the text arrow stays in the caption so the button still reads correctly with the artwork off.

Motion layers stay in code. They are scrolled to animate, so they have to tile, and that is a different job from drawing a picture.

---

## 17. Tests

```
powershell -NoProfile -File tests\Run-Tests.ps1        every test
powershell -NoProfile -File tests\Run-Tests.ps1 -Fast  skip the ones that build a window
```

The suite needs no USMT install and touches no real machine; the destructive tests run against a substituted drive letter. `tests\README.md` covers what each of the 11 tests asserts. The three referenced most often above:

| Test | Asserts |
|---|---|
| `tests\layout.ps1` | No Fill panel below 40px or without a floor; no animation frame over 15 ms; no resize-while-animating regression |
| `tests\overlay.ps1` | Each theme's banner carries at least 150 distinct colours, and WCAG contrast holds at 4.5:1 for panels and the log, 3:1 for the banner title |
| `tests\theme.ps1` | Every tagged control takes a new theme's colours, text clears its background, and every filled button's label is legible on its fill |

---

## 18. Appendix

### Reference commands

These are the base commands the tool builds on. `RWR` is the domain.

**Export, single profile**

```
.\scanstate "D:\USMT Profiles\[username]"
  /i:migapp.xml /i:miguser.xml /config:Config.xml
  /v:13 /ue:* /ui:RWR\[username]
```

**Export, single profile, excluding OneDrive**

```
.\scanstate "D:\USMT Profiles\[username]"
  /i:migapp.xml /i:miguser.xml /i:ExcludeOneDriveFolders.xml /config:Config.xml
  /v:13 /ue:* /ui:RWR\[username]
```

**Import, single profile**

```
.\loadstate "D:\USMT Profiles\[username]"
  /i:migapp.xml /i:miguser.xml /config:Config.xml
  /v:13 /c /ue:* /ui:RWR\[username]
```

**Export, all profiles**

```
.\scanstate "D:\USMT Profiles\[computername]"
  /i:migapp.xml /i:miguser.xml /config:Config.xml
  /v:13 /ui:RWR\* /ui:%computername%\*
```

**Import, all profiles**

```
.\loadstate "D:\USMT Profiles\[computername]"
  /i:migapp.xml /i:miguser.xml /config:Config.xml
  /v:13 /c /ui:RWR\* /ui:%computername%\*
```

**Export, computer settings only**

```
.\scanstate "D:\USMT Profiles\[computername]"
  /i:migapp.xml /i:miguser.xml /i:MigratePublicFolders.xml /config:Config.xml
  /v:13 /ue:*\* /c
```

**Import, computer settings only**

```
.\loadstate "D:\USMT Profiles\[computername]"
  /i:migapp.xml /i:miguser.xml /i:MigratePublicFolders.xml /config:Config.xml
  /v:13 /ue:*\* /c
```

### USMT exit codes

The full list is Microsoft's: <https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes>. UTW prints the meaning of the code and links that page when a run fails. The ones seen in practice:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Non-fatal errors, migration continued. Requires `/c` |
| 11 | Bad command line. Check the Expert panel |
| 27 | Store not found at the expected path. See the store marker in section 4 |
| 71 | Child process failed. Usually a permissions problem or a corrupt store |
| 72 | V2V arbitration failure. See section 9 |
| 73 | Catastrophic failure. Store may be corrupt or the disk full |

### Files

| File | Purpose |
|---|---|
| `UTW-Main.ps1` | GUI and run orchestration |
| `UTW-Logic.ps1` | Command building, remote execution, checks |
| `UTW-Themes.ps1` | Theme data, design tokens, background painters |
| `UTW-Launcher.bat` | Launches without a console window; elevates, or `/noadmin` |
| `xaml\` | Theme artwork and operation icons |
| `tests\` | The test suite; `Run-Tests.ps1` runs all 11 |
| `Config.xml` | Passed as `/config:`. Prevents error 72 |
| `UTW_Settings.json` | Shipped defaults. Per-operator settings save beside it as `UTW_Settings_<name>.json` and are not committed |
| `UTW_SyncRules.json` | Exclusion and scope lists for Compare & Sync. Edit without touching code |
| `UTW.ico` | Window and shortcut icon |
| `USMT\amd64\` | Microsoft's USMT binaries and migration XML. Not included |

### Paths

| Path | Contents |
|---|---|
| `[USMT]\Config.xml` | V2V exclusion config. Must be present to prevent error 72 on cross-build migrations |
| `[USMT]\MigratePublicFolders.xml` | Generated XML ensuring Public folder contents are captured in System context during computer-settings operations |
| `[USMT]\Logs\Export_*.log` | Full scanstate detail log, `/v:13` |
| `[USMT]\Logs\Import_*.log` | Full loadstate detail log. Line 3 is the exact command; search for `error code` |
| `[USMT]\Logs\*_progress_*.log` | CSV progress log, updated live. Drives the progress display |
| `[Script]\UTW_Settings_<user>.json` | Saved GUI settings: paths, names, theme, layout |
| `[Script]\CrashLog.txt` | Script-level error log for GUI and initialization failures |
| `[Store]\export_complete.json` | Completion flag written after a successful export. Source PC, timestamp, technician account |
| `[Store]\.usmt_store.json` | Store marker used to locate a store whose folder name does not match |
| `\\PC\C$\Windows\Temp\USMT_Temp\` | Remote staging folder. Created automatically, cleaned up after the operation. Holds binaries, logs and the batch file for the remote task |
