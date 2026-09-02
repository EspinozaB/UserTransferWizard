# Changelog

## 2026-09-02

Repository restructured into `Core\`, `Docs\`, `Modified USMT Config
Files\`, `xaml\`, and `USMT\`. Remote migration reliability fixes, USMT
version handling, licence files, and a rewrite of both documents.

### Fixed

**Remote migrations failed instantly with a blank log.**

* `Get-RemoteTaskStatus` never detected task completion. It called
  `schtasks` without `/v`, so the CSV had no Last Result column and the
  code fell back to a literal `267011` on every poll. It now uses `/v`,
  parses Status and Last Result by column position (works on
  non-English Windows), and maps the `SCHED_S_*` states correctly:
  RUNNING, QUEUED, HAS_NOT_RUN, TERMINATED, and real exit codes. The
  comment describing `267011` as `STILL_ACTIVE` was also wrong; it is
  HAS_NOT_RUN.
* `RunScan.bat` and `RunLoad.bat` gave no diagnostic on an early
  failure. New `Get-UsmtRunBatchContent` helper creates the log folder
  first, writes a `[RunScan]` or `[RunLoad]` banner before the
  executable, records the exit code after, and preserves that exit code
  past the trailing echo so the task's Last Result stays meaningful. The
  full command line is written to `CrashLog.txt`.
* The tool tailed an empty log forever when USMT never started. New
  `Test-RemoteUsmtStarted` watchdog: if no detail log appears within
  five minutes it prints one line pointing at
  `C:\Windows\Temp\USMT_Temp` and Task Scheduler history, then stays
  quiet. It never fires once USMT is logging.
* Timer phase 1 and 3 handlers now explain exit `267014` (task
  terminated) and `267011` (action never ran) instead of passing them to
  `Write-USMTExit` as though they were USMT codes.

**scanstate and loadstate exited with `0xC0000139`.**

Root cause: `amd64\` held USMT from a pre-release Insider ADK (build
28000), which does not load on released Windows.

* `Format-USMTExitLines` now decodes `-1073741511`, `-1073741515`, and
  `-1073741701` as Windows loader failures and says to swap the binaries
  for a released ADK's.
* Pre-flight check before every run (`Start-ExportNow`, standalone
  remote import, `Start-LocalOperation`): reads both machines' Windows
  builds and `scanstate.exe`'s build, and stops with a Yes/No prompt if
  the binary is newer than every machine.

**Config.xml was forced onto every run,** which broke same-build
captures. It is now opt-in through File > Settings > Cross-build fix
(Config.xml): `auto` (default, applies only when the two machines report
different builds), `yes`, or `no`. Gated at all five places that touched
`Config.xml`. Adds `$Script:ConfigXmlMode`, `Should-ApplyConfigXml`, and
`Get-RemoteOSBuild`.

`ConfigXmlMode` was saved to settings but never loaded back.
`Load-SettingsCache` now returns it and `Ensure-FactoryCache` includes
it in the defaults.

**The `Core\` and `Docs\` reorganisation broke three script paths.**

* `$Script:XamlRoot` pointed at `Core\xaml`, so the Run button icons
  silently fell back to the text arrow.
* Help > "UTW notes (README)" and every "see README" link pointed at
  `Core\README.md`. It is in `Docs\`.
* The "Config.xml beside the scripts" staging fallback pointed at
  `Core\Config.xml`.

Fixed with a new `Get-UTWResource` helper in `UTW-Main.ps1` that
resolves shipped files across `Core\`, the repo root, `Docs\`, and
`Modified USMT Config Files\`. Used for `$Script:XamlRoot` (reassigned
after modules load), the Help items, `Get-UTWDocsRef`, and both
`Config.xml` fallbacks.

### Added

* `Core\UTW.vbs`. Launcher with no console window. Self-elevating, and
  converts a mapped-drive path to UNC so it works from a network share.
  Supports `/noadmin`.
* `Core\UTW_Settings.json`. Generic shipped defaults: empty domain and
  paths, `ConfigXmlMode: auto`.
* Multi-version USMT auto-selection (`Get-USMTPathForVersion`, wired
  into `Get-USMTPathForRun`). Drop in `amd64-<build>` sibling folders,
  or a `USMT\Build <n>\amd64` folder per version. UTW reads each target
  machine's Windows build and picks the newest set not newer than that
  machine.
* USMT folder verdict. Setting the USMT folder now reports the build and
  whether it looks like a released ADK (`Get-UsmtFolderInfo`,
  `$Script:KnownUsmtBuilds`). Amber if newer than any known release.
* `USMT-VERSION.txt` written into the USMT folder
  (`Write-UsmtVersionStamp`). Best-effort and informational only.
* Help > "UTW documentation" menu item, opens `DOCUMENTATION.md`.
* Compare installed programs: a one-time-per-session prompt to run it
  before wiping the old PC.

### Changed

* `Start-RemoteScanTask` and `Start-RemoteLoadTask` return `Started` (a
  timestamp), used by the watchdog.
* `.gitignore`: added `amd64/`, `amd64-*/`, `x86/`, `x86-*/`. Removed
  stale entries for reference projects that are not in the tree.
* USMT binaries are no longer expected in the tree at all. They are
  Microsoft's and are obtained from the ADK or attached to a release.
* Code references to `UTW-README.md` corrected to `README.md`.
* Example names in code comments genericised; real usernames removed.

### Removed

* Seven per-theme `xaml\*.xaml` files and
  `clown-fiesta.xaml.needs-work`. XAML mode still works and draws the
  continuous window backdrop from the GDI painters. The five
  `xaml\icon.*.xaml` Run button glyphs stay.
* `CrashLog.txt`. It regenerates and is gitignored.
* `USMT\Build 26100\amd64\usmtutils.log`, which contained a real
  username and paths.
* Empty `USMT\Build 28000\amd64\Logs\`.
* The `tests\` folder and every reference to it. It is no longer used.

### USMT payload (release zip)

* `USMT\Build 26100\amd64\#command-line-examples.txt` sanitised: the
  real domain replaced with `contoso\`.
* Copied `Config.xml` and `MigratePublicFolders.xml` into
  `USMT\Build 26100\amd64\`. Both were missing and are needed for the
  cross-build fix and computer-settings runs. Both builds now carry all
  four tuned XML files, byte-identical to the masters.

### Documentation

* `README.md` and `DOCUMENTATION.md` rewritten: plainer wording, no
  em-dashes, the `Core\` and `Docs\` layout, the repo versus release-zip
  split, a full USMT version compatibility section, an installing and
  updating section, and expanded troubleshooting.
* `DOCUMENTATION.md` restructured into 17 numbered sections with
  subsection numbering and cross-references.
* `RWR` replaced with `DOMAIN` in the reference commands.
* Corrected: the shipped default theme is Dark, not Neo Dark.
* Corrected: animation is off in the shipped settings file, so a fresh
  install starts with graphics and animation both off.
* Removed the Tests section and renumbered Reference to section 16.
* Added section 2.8, shipping the USMT binaries: the ADK licence
  question, and why a release asset beats committing them to Git.
* Added section 2.9, licence, plus `LICENSE` (MIT) and
  `THIRD-PARTY-NOTICES.md` in the repo root recording what MIT does not
  cover: the USMT binaries, `MigUser.xml` as a modified copy of
  Microsoft's file, and `Config.xml` as edited `/genconfig` output.
