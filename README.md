# User Transfer Wizard (UTW)

A GUI wrapper around Microsoft's USMT (scanstate.exe / loadstate.exe) for PC
refresh migrations. Windows PowerShell 5.1 and WinForms; no modules to install,
nothing to compile.

It captures a user profile off the old machine and restores it onto the new one,
locally or over the network, and does the surrounding work USMT does not: staging
the tools on the far machine, pre-flight checks, watching the logs, cleaning up
afterwards, and comparing the two machines once the migration is done.

## Getting started

**You need**

- Windows PowerShell 5.1 (in the box on Windows 10/11 — not PowerShell 7)
- Microsoft's USMT from the Windows ADK. **It is not included here**: those
  binaries are Microsoft's to distribute. Install the ADK's *User State
  Migration Tool* feature and point UTW at the `amd64` folder on first run.
- Local administrator rights on both machines for a remote migration, and the
  `C$` admin share reachable on each.

**Running it**

    UTW-Launcher.bat            elevates, then opens the window
    UTW-Launcher.bat /noadmin   no elevation - local browsing and Compare only

Or, if you prefer the console:

    powershell -NoProfile -ExecutionPolicy Bypass -STA -File UTW-Main.ps1

Settings are written next to the script as `UTW_Settings_<you>.json`, one per
operator, so two people sharing a folder do not overwrite each other.

**Checking it still works**

    powershell -NoProfile -File tests\Run-Tests.ps1        every test
    powershell -NoProfile -File tests\Run-Tests.ps1 -Fast  skip the ones that build a window

The suite needs no USMT install and touches no real machine; the destructive
tests run against a substituted drive letter. `tests\README.md` says what each
one covers.

**USMT problems** — anything with a USMT exit code — are Microsoft's:
<https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes>
The tool prints the meaning of the code and links that page when a run fails.

**UTW problems** are the ones below. These are steps UTW performs *around* USMT
— staging tools, creating shares, scheduling tasks, locking a destination — and
they have no USMT error code, which is why they are documented here instead.

---

## How a remote migration actually works

There is no WinRM in this environment. UTW therefore:

1. Copies the USMT binaries to `C:\Windows\Temp\USMT_Temp` on the target, over
   its `C$` admin share.
2. Writes a `.bat` there that runs scanstate/loadstate and captures the exit code.
3. Creates a one-shot **scheduled task** via `schtasks.exe` over DCOM/RPC, running
   as `SYSTEM`, and starts it.
4. Tails the USMT progress and detail logs back over the same admin share.

**The single most important consequence:** the task runs as `SYSTEM`, and
SYSTEM's identity *on the network* is the **computer account**
(`DOMAIN\PCNAME$`), not you. Any network location the capture writes to must
grant access to that computer account. This explains most "access is denied"
failures that appear halfway through an otherwise healthy run.

---

## UTW-level failures

### "could not stage the USMT tools"
UTW cannot reach `\\PC\C$\Windows\Temp`. Check the machine is on, that you are a
local administrator on it, and that File and Printer Sharing is open to it.

Note that being an administrator is what matters here, **not** whether UTW is
running elevated: a network logon by a domain admin account gets an unfiltered
token regardless. A *local* (non-domain) account does not.

### "access is denied" partway through a remote capture
The store location does not grant the **source computer account** write access.
Either use *New PC (direct)* mode — which creates a temporary share granting
exactly that account, then removes it — or add `Domain Computers` to the share
and NTFS ACLs of the network location.

Effective SMB access is the **intersection** of the share ACL and the NTFS ACL.
Both must allow it.

### Network share (UNC) mode does nothing / fails with 0x5
The share needs `Domain Computers` write access for the same reason as above.
Without that ACL change this mode cannot work, whatever the tool does.

### "the destination store is in use by another window"
A second UTW window is already migrating to that store. Two captures writing one
store folder produce a `.MIG` that restores badly, so the second is refused.
Finish or stop the other window, or point this one elsewhere. A lock left behind
by a crashed window is released automatically once that process is gone.

### "not a valid computer name"
Clean Up only accepts plain machine names — letters, digits, dots and hyphens.
Anything that could change the shape of the UNC path it builds is refused, since
that path is handed to a recursive delete.

### Clean Up says a machine is unreachable that is plainly on
It reports the underlying reason now — "access is denied" and "network path not
found" mean different things. The first is rights on the target; the second is
name resolution or the firewall.

### Clean Up did not offer a folder that is clearly in the store area
Only folders that really contain `USMT\USMT.MIG` are offered for deletion.
Anything else is listed as "left alone". This is deliberate.

### Clean Up did not offer a profile I expected
Every profile is listed either as removable or with the reason it is not:
*system profile*, *built-in account*, *lives under Windows*, *signed in right
now*, *that is you*, or *used N days ago*.

"Signed in right now" is the common surprise: `Win32_UserProfile.Loaded` is true
for **any** profile with a loaded registry hive, including other sessions and
service accounts, so on a live machine most profiles look busy. Run the clean up
against a machine the users have signed out of.

---

## Drive stores are two runs, not one

**Select Export + Import and *External / USB drive* greys out in the Save to
list.**

Every other store type works in one run because both machines can reach the
store at the same moment — Direct writes into a share on the new PC, Network
share writes to a UNC both can see. A drive is reachable by exactly one machine
at a time, and the step that changes that is a person carrying it. There is no
point at which LoadState could succeed.

The *destination* is what goes unavailable, never the operation: choosing
Export + Import moves the store to the new PC without comment, because the drive
greying out in the same instant explains itself. The only message is if you go
on to click the greyed drive anyway.

The workflow is:

| | Where | What |
|---|---|---|
| 1 | old PC (or remotely, to *its* drive) | **Export** → `D:\USMT Profiles\<user>` |
| 2 | — | unplug, carry, plug in |
| 3 | new PC | **Import** → Browse to the store on the drive |

Import accepts the store root, the `USMT` subfolder, or the `.MIG` file itself.

The export leg can still be remote: fill in *Capture from* and ScanState runs on
the old machine writing to that machine's own drive — the answer when the old PC
is full but has an external disk plugged in.

---

## Deleting stale user profiles

`sysdm.cpl` — System Properties ▸ Advanced ▸ User Profiles ▸ Settings — has no
command line and cannot be pointed at another machine, so it cannot be
automated. UTW uses **`Win32_UserProfile`**, which is what that dialog drives
underneath and *is* remotable over DCOM.

This matters beyond convenience: `Win32_UserProfile.Delete()` removes the
profile folder **and** its `ProfileList` registry entry. Deleting `C:\Users\<name>`
by hand leaves the registry entry behind, and the next sign-in gets a
**temporary profile** — a worse problem than the disk space it freed.

Turn on **Delete stale user profiles** in Options. It applies to **Clean Up and
to a capture** — see *Tidying up the old machine* below for the capture case.
Either way it is the same two steps:

1. **A ticklist**, one row per profile, with the computer, account, age and
   folder. **Nothing is ticked when it opens** — you say yes to each account
   rather than no to the ones you did not mean. *Select all* / *Select none* are
   there for when you do mean all of them. Profiles that cannot be deleted are
   listed too, greyed out with the reason, so none go quietly missing.
2. **A confirmation** listing exactly what you ticked, and nothing else.

Cancelling the ticklist abandons the whole clean up, including anything you
already agreed to on the earlier dialogs.

**Age is evidence, not proof.** `LastUseTime` is often empty, in which case the
profile folder's own timestamp stands in — the output says which was used. A
backup agent or AV sweep touching a profile can also refresh either date.

Never offered: system and built-in profiles, anything under `\Windows`, profiles
that are signed in, your own, and anything used inside the inactivity window
(90 days). The rules are re-checked at delete time too, since someone can sign
in while the confirmation is on screen.

---

## OneDrive detection

Before a single-profile capture, UTW checks whether the profile is on OneDrive
and offers to exclude it. Two signals: a matching folder in the profile, and
membership of the AD group named in `OneDriveGroup` (default `OneDriveUsers`).

**Where OneDrive is deployed to everyone, both signals are true of everyone** and
so discriminate nothing. That is what the size threshold is for: the prompt only
appears when the OneDrive folders actually hold more than *Ask above* MB **on
disk**. Cloud-only files count as nothing, so a fully dehydrated OneDrive never
prompts however large it looks in Explorer — because excluding it would save
nothing.

Settings live in **File ▸ Settings**, under *OneDrive detection*. (They used to be
duplicated on the Expert panel as well; Settings is now the one place, and it is
reachable without turning Expert mode on.)

| Setting | Meaning |
|---|---|
| **Check OneDrive before a capture** | `no` = never ask about OneDrive at all. |
| **OneDrive group** | AD group whose members are treated as OneDrive users. |
| **OneDrive folders** | Wildcard for what counts as OneDrive. `OneDrive*` matches the tenant folder *and* a personal one; `OneDrive - *` matches only tenant folders. `<user>` expands to the profile name, e.g. `OneDrive - <user>`. |
| **Ask about OneDrive above (MB)** | MB of locally-held data before prompting. `0` = ask whenever a folder exists. |

A measurement always beats group membership: if the folders were measured and
came in under the threshold, being in the group does not re-raise the prompt.

## Expert mode

*Mode: Expert* in the header (or **View ▸ Expert**) adds a panel showing the exact
USMT command line each leg of the operation will run — two of them for Export +
Import, since that is genuinely two runs on two machines.

The panel reads top to bottom: the command, the buttons that act on it, the USMT
build to use, log-on-exit, and then — fenced off below a red rule — the two
options that change or destroy data.

- Editing the text updates the Options above (removing `/o` unticks *Overwrite*,
  removing the OneDrive XML unticks *Exclude OneDrive folders*), and vice versa.
- Switches UTW does not model — `/vsc`, `/encrypt`, `/hardlink`, `/nocompress`,
  `/uel`, `/md`, `/mu` and the rest — are **kept exactly as you typed them** and
  survive regeneration.
- **Regenerate** discards your edits *and* your custom switches.
- **Copy** / **Paste** move the whole command in and out of the clipboard.
  Pasting replaces the panel and the options follow it; Ctrl+V still inserts at
  the cursor.
- **Switching back to Simple does not undo an edit.** UTW asks what you want:
  discard the edits, or keep them. If you keep them the title bar says
  *custom command*, and every run announces that it is using your edited
  command rather than the one the options describe.
- Nothing validates USMT syntax. There are too many options for that to be
  anything but a source of false rejections; USMT reports a bad command line
  clearly as exit 11.

Full switch reference:
- ScanState: <https://learn.microsoft.com/windows/deployment/usmt/usmt-scanstate-syntax>
- LoadState: <https://learn.microsoft.com/windows/deployment/usmt/usmt-loadstate-syntax>

The pre-check options (*Profile exists*, *Free disk space*, *Inactive profiles*,
*Measure profile size*) are UTW's own and deliberately have no command-line
equivalent, so they do not appear in the panel.

---

## Files

| File | Purpose |
|---|---|
| `UTW-Main.ps1` | GUI, run orchestration |
| `UTW-Logic.ps1` | Command building, remote execution, checks |
| `UTW-Themes.ps1` | Theme data, design tokens, background painters |
| `UTW-Launcher.bat` | Launches without a console window; elevates, or `/noadmin` |
| `xaml\` | Theme artwork and operation icons |
| `tests\` | The test suite — `Run-Tests.ps1` runs all 11; see `tests\README.md` |
| `Config.xml` | Passed as `/config:` — **prevents error 72** (V2V arbitration) |
| `UTW_Settings.json` | Shipped defaults. Per-operator settings are saved beside it as `UTW_Settings_<name>.json` and are not committed |
| `UTW_SyncRules.json` | Exclusion and scope lists for Compare & Sync. Edit without touching code |
| `UTW.ico` | Window and shortcut icon |
| `USMT\amd64\` | Microsoft's USMT binaries and migration XML — **not included**, see above |

`Config.xml` must be present beside the script or in the USMT folder. It is
staged with the tools on remote runs. Without it, **exit 72** is likely.

Multiple windows: **File ▸ New window** (Ctrl+N) opens a second instance carrying
the same settings, for migrating two machines at once. Machine names are
deliberately left blank in the new window. Only the first window saves settings
on close.

---

## Themes and the Neo design system

The palette, type scale and spacing come from the Neo design system
(`designSystemTemplate.responsive.v10` / `neo-template-demo-vite-v10`). Those
are CSS custom properties; `UTW-Themes.ps1` holds the same set in the form a
WinForms app can use, under `$Script:Tokens`.

**Neo Dark** is the default. **Neo Light** is the same palette inverted. The
six original themes are unchanged and still there.

Two places the mapping is deliberately *not* literal, both noted in the code:

- `--primary` is near-white in the dark palette — in that system "primary" means
  a high-contrast surface. In UTW `Primary` is the *accent*: group captions, the
  title, the Run button. Taking the name rather than the meaning gives a white
  Run button with white text, so UTW's `Primary` maps to `--info`.
- `--card` equals `--background` in the dark palette, which would make every
  group box invisible against the form. Panels take `--muted`.

**What does not transfer:** `--radius` and the shadows. WinForms controls are
rectangles; rounded corners need owner-drawn painting on every button. The
values are recorded in `$Script:Tokens.Radius` so that work, when it happens,
uses the right numbers.

### Background graphics

**View ▸ Theme ▸ Background graphics** turns a themed backdrop on. Off by
default, remembered per user.

**Every theme has its own artwork**, ported from the HTML background files
rather than generated from its palette:

| Theme | Source | What it draws |
|---|---|---|
| Clown Fiesta | `clown-fiesta-bg_2.html` | polka ground, bunting, balloons, drifting confetti, and **five clowns** |
| Neo Dark / Neo Light | `neo-*-bg.html` | base wash, three aurora ribbons, light shafts, four Aero glass panes with a specular sweep, rising motes |
| Fresh Water | `freshwater-bg.html` | lit water, three sliding swooshes, a shimmer band, bubbles |
| Waste Water | `wastewater-bg.html` | settled bands, morphing blobs, drifting scum, bubbles |
| Solarized Dark | `solarized-dark-bg.html` | a sun below the horizon: a wheel of coloured rays, a breathing corona, horizon haze and a terminal cell grid |
| Dark / Light | `metro-*-bg.html` | two accent glows and six crawling diagonals |

The **clowns** are ported shape for shape from the source `<svg class="clown-svg">` —
shoes, polka suit, ruffled collar, curly hair, top hat with a flower, eyes, red
nose, smile, arms and the balloon on a string — drawn in the file's own viewBox
coordinates so the code reads against the original rather than against numbers
somebody scaled by hand. The **glass panes** are the source design files' signature and
were the reason those backgrounds looked like anything at all.

None is a pixel copy — the Clown Fiesta source alone is 308 SVG elements
including 41 bezier paths — but each is made of the same things in the same
palette. Any theme added later without artwork of its own falls back to a
default painter that still draws a picture, not just a gradient.

**The backdrop runs behind the panels too**, not only the header — 14 surfaces
carry it. A Label with no background of its own inherits its parent's *colour*
and then fills itself with it, which over a painted panel is a grey box with a
word in it, so no caption is left that way.

All 48 of them are **transparent**, and nothing cheaper works. Two flat-colour
schemes were tried and both showed: one colour per surface cannot match, because
every panel is a different size and shows a different crop of the artwork; and
sampling the backdrop under each caption is closer but still a flat fill over a
gradient, so a wide caption sits in a visible patch. The artwork behind text is
not flat, so no flat colour will ever disappear into it.

Transparency was never the wrong answer — **the paint handler being expensive
was**. A transparent caption is drawn by asking its parent to paint again clipped
to the caption, so the handler runs once per caption, ~48 times per panel
repaint. It now takes two fast paths when the clip is partial: the motion layers
are skipped (only the banner animates anyway) and the group box caption is
skipped unless the caption band is in the clip. With those, a divider frame is
**49.6 ms against 65.2 ms** when the panels were using flat colours — the
transparent version is not merely affordable, it is faster.

**Group boxes paint their border and caption in `OnPaint`, and the Paint event
fires afterwards** — so blitting the backdrop over the client area covered both,
and every panel lost its title the moment the graphics went on. The handler
redraws them, using `TextRenderer` because that is what the control itself uses.

**Legibility is bought two different ways.** The panels and the log dim the
artwork (to 42% and 26%) and wash the panel colour back over it, at levels that
were *searched* rather than guessed — see the contrast table below. The banner
does the opposite: it keeps the artwork at full strength and protects its title
with a **halo** instead, which is what the source files do
(`text-shadow: 0 0 34px var(--glow)`). That is not a stylistic choice — with
Clown Fiesta's white gloves under light title text the banner measures 1.01:1,
and the dimming needed to fix it is 193 of 255, which erases the picture.

**There is no text halo, and there cannot be one.** It was built three times. A
Label paints its text with `TextRenderer` (GDI); a halo drawn with
`Graphics.DrawString` is GDI+, and the two lay the same string out **1px apart** —
measured. An outline around text that is itself a pixel off lands 2px on one side
and flush on the other, which is what kept being reported as a weird duplicate or
one-sided shadow. GDI text cannot be drawn translucently, so there is no aligned
version of the effect to fall back on.

Instead the banner's **caption band is scrimmed**: the top 62% fades into the
theme's own dark ground and the bottom keeps the picture at full strength, which
is where the clowns are standing anyway. A gradient is not text and cannot be
misaligned with anything. The clowns are drawn at 62% height on the banner so
they stay clear of the band, and full height everywhere else.

Two things go wrong with a painted backdrop and neither is visible in the
source, so `tests\overlay.ps1` asserts both. **It draws nothing:** the first
version of the Clown Fiesta artwork put the confetti and balloons on the motion
layer only, so with animation off the backdrop was a gradient and a stripe. Each
theme's banner must carry at least 150 distinct colours — they now run from 962
to 2422, against 119–260 before. **It draws too much:** the test measures WCAG
contrast between each theme's own text colour and the worst pixel that text
could land on, holding panels and the log to 4.5:1 (small text) and the haloed
banner title to 3:1 (large text).

That contrast check replaced a cruder one that gated on "how far the busiest
pixel strays from the average", which cannot tell a big smooth clown from a
field of hard-edged confetti and failed the clown for being a picture.

Light grounds are tuned on their own numbers rather than sharing the dark ones —
a wash that reads clearly over `#04121c` disappears entirely over `#ffffff`.
Broad glows there take roughly double the alpha, but the small hard-edged marks
do **not**: a dark accent dot on white is already a far bigger jump than the same
dot on charcoal, and boosting those is what turns a backdrop into noise.

**The output log is tinted, not transparent.** A RichTextBox and a ListView are
opaque and WinForms gives no supported way round it. The see-through route was
built and measured before being abandoned: a `WS_EX_TRANSPARENT` RichTextBox took
**1387 ms to append 300 lines against 489 ms opaque** — 2.8× — on the one control
that tells anybody what a migration actually did, and RichEdit smears it on
scroll. So the log is joined to the picture from both sides instead: its group
paints the real artwork and its padding leaves a frame wide enough to see it,
and the log's own background colour is sampled *from* that artwork, so the two
meet in the same family of colour rather than the log reading as a grey hole
punched in the backdrop.

One thing follows the theme rather than the artwork: in **Clown Fiesta only**, a
finished run is announced as **★ HONK HONK! Migration Successful!** and a failed
one as **★ HONK! Migration failed!** — two honks good, one honk bad. Every other
theme reports in the usual words. It is cosmetic: the verdict itself, the exit
code and the log are identical either way.

**It costs nothing per frame**, and that is enforced. The art is rendered once
into a bitmap and blitted; measured with the backdrop on, a resize frame is
44 ms against 50 ms with it off — i.e. no difference. `tests\layout.ps1` fails
if it ever adds more than 15 ms.

**Each theme is pre-rendered once, then scaled.** The painters are real artwork
now — a Clown Fiesta banner is 250-odd shapes, a Solarized ray wheel is 16
gradient-filled wedges — and re-running them at every size made resizing and
theme-switching both stall. So each `(theme, surface, layer)` is painted **once**
into a master bitmap, and every size the window actually asks for is a scaled
blit off that master, cover-cropped to the target's aspect (anchored to the
bottom, because that is where the clowns stand). This is the "pre-render it to an
image" idea, except the master is produced by the same painter, so there is
nothing to keep in step and no files to ship.

| | before | after |
|---|---|---|
| a new size (what a resize pays) | 20–40 ms | **1.4–2.0 ms** |
| a theme switch, all surfaces cold | this, repeatedly, at every size | ~300–550 ms once |

Masters survive a resize, and **two themes' worth are kept**, so flipping back to
a theme you were just on costs **47 ms** instead of re-rendering every surface
(272 ms, or 847 ms for Clown Fiesta). Toggling the *animation* does not discard
them either — that used to route through the same path and stalled for a full
re-render to change something that alters no pixels.

Clown Fiesta draws its clowns on the banner only. A clown is ~50
shapes and five of them is the most expensive thing any painter does; on a panel
the artwork is dimmed to 42% and then washed with 140 of panel colour, and on a
zone they sit behind the panels - so they were being drawn where they cannot be
seen. First visit to Clown Fiesta went 1072 -> 707 ms.

**Caching by size is wrong during a drag.** The size changes every frame, so
every frame is a miss. Mid-drag the last bitmap is reused and the correct one is
drawn when the drag ends; sizes are also quantised to a 64px grid so small
movements do not miss at all.

### Animation

**View ▸ Theme ▸ Enable animations** — **on by default**, so switching the
graphics on gives you the artwork moving and this is the switch to turn that off.
The graphics themselves are still off by default, so nothing animates until
somebody asks for a backdrop. It is greyed out unless the graphics are on and the
theme has something that moves, which every theme with artwork now does.

Whether the timer runs is decided in exactly one place, `Set-OverlayEnabled`.
Restoring the saved settings used to set the animate flag and then turn the
graphics on, which left the flag true and the timer stopped — so a tool closed
with the animation running came back up showing a still picture.

It costs **7.3 ms a frame at 20 fps — about 15% of one core**, and it is done by
scrolling rather than redrawing:

- The backdrop is layered. **Ground** is static. **Motion** and **motion2** are
  transparent bitmaps each drawn *twice* at a wrapping offset, so they drift
  endlessly for the cost of two blits apiece.
- **Two layers, travelling opposite ways at different speeds** — confetti
  falling at 5px a tick past balloons rising at 3. One layer drifting at 2px a
  tick was the old version, and it read as a picture sliding rather than as
  motion: *"I see a piece of confetti slightly move."*
- **Only the header moves**, and this was measured twice rather than assumed.
  With the panels animated and the timer instrumented, frames arrived **643, 674
  and finally 1,105 ms apart** — the window stopped responding even after the
  animation had backed itself off to 400 ms, because `Application.DoEvents` never
  drains a queue that is filling faster than it empties.

  The blits are not the problem: a panel-sized ground plus four motion blits
  measures **1.5 ms**, so all of them together are about 20 ms. The rest is
  WinForms compositing the 48 **transparent captions** — a caption with a
  transparent background is rendered by asking its *parent* to paint again,
  clipped to the caption, so invalidating one panel costs one paint per caption
  on it. That is the same transparency that removed the boxes from behind the
  text, and it is worth more than moving confetti behind a form.

  There is an **overrun guard** regardless, for slow machines and remote
  sessions: it compares the frame interval actually achieved against the one
  asked for and backs off to a 400 ms ceiling. (The first version timed the tick
  body and never fired — the body only posts `Invalidate` calls and is fast by
  construction; the expense is the painting that follows.)
- **The painting stands down during a resize**, not just the timer. Otherwise
  every resize frame still paid for four alpha blits of a banner-sized layer.
- The **halo is cached** too. Drawing it live cost 1.2 ms per caption on every
  frame — a quarter of the budget spent redrawing an identical picture.
- Surfaces other than the banner **quantise their size to a 64px grid**, so a
  window resize reuses one bitmap instead of missing the cache on every frame at
  20–40 ms a miss. The banner is exempt: its composition is anchored to its own
  edges, because the clowns stand on the bottom of it.
- The timer **stands down** during a resize or a divider drag, while a migration
  is running, and while the window is minimised. Resizing with it on measures
  48.8 ms against 58.6 ms with it off — i.e. no cost.

`tests\layout.ps1` fails if a frame exceeds 15 ms or if resizing-while-animating
regresses.

### Authoring artwork in XAML

A theme's ground artwork can be written as **XAML** instead of as GDI+ calls.
Drop a file in `xaml\` named `<theme>.<surface>.xaml` — `neo-dark.header.xaml`
is the worked example — and it is rendered once to a bitmap at master size and
fed through the same scale-and-cache path as everything else. The painter stays
as the fallback, and a file that fails to parse logs once and falls back rather
than breaking the window.

This is the only WPF route that fits. Hosting live WPF means an `ElementHost`,
and an `ElementHost` is its own window: it can sit *on top of* the WinForms
controls but never behind them, which is the one thing a backdrop has to do.
Rendering offscreen sidesteps that entirely, because the result is a bitmap and
bitmaps are what the overlay pipeline already moves around.

Measured against the hand-written painter for the same picture:

| | colours | spread | render |
|---|---|---|---|
| GDI+ painter | 4034 | 193 | 256 ms |
| XAML master | 4225 | 261 | **139 ms** (warm) |

So it is *faster* as well as easier to author — real gradients, blur effects and
rotation instead of arithmetic. The cost is a one-time ~850 ms to load
`PresentationFramework` on the first file found, which is why nothing is loaded
unless a `.xaml` actually exists.

**All eight themes ship as XAML**, one file each in `xaml\`. The surfaces differ
only in how loud the artwork may be — a single number — so a per-surface file
would be the same picture eight times with the opacities changed;
`Get-XamlMaster` applies the surface's own quiet level instead. A
`<theme>.<surface>.xaml` still wins if a surface ever needs its own composition.

**View ▸ Theme ▸ XAML mode** switches the whole set back to the
GDI+ painters, which is why those are kept. Remembered per user.

Two things worth knowing before writing one:

- **`x:Shared` does not work in loose XAML** — it is honoured only in compiled
  resource dictionaries. A Visual has one parent, so artwork cannot be reused as
  a Canvas. Clown Fiesta's clown is a `VisualBrush`, which can be filled into as
  many rectangles as you like; that is what makes a repeated figure practical.
- **Keep bright work out of the banner's two ends.** The captions live there and
  the middle carries none, which is why the clowns stand in the middle. Clown
  Fiesta's bunting run edge to edge held the worst contrast at 1.48:1 no matter
  what was changed underneath it.

**One backdrop behind the whole window.** With the XAML artwork on, every surface
draws its own part of a single window-sized picture rather than scaling the
master into its own bounds — so the panels sit on a continuous image instead of a
patchwork of independent copies. Each surface washes its own region afterwards,
since they carry different amounts of text. Measured at **+0.9 ms a frame**
against the backdrop switched off.

**It drifts, and that costs nothing.** The banner animates by compositing extra
transparent layers, which is why doing that on every surface once cost the better
part of a second a frame. The backdrop has nothing to composite — it is one blit
already — so it animates by landing that blit a few pixels further along. It
ping-pongs inside the slack between the window's size and the backdrop's
(quantised up to a 256px grid), so an edge can never be dragged into view.

Drifting surfaces repaint on **one tick in five**. The banner needs 20fps because
confetti falls at 5px a tick; a backdrop that ping-pongs a couple of hundred
pixels over minutes does not, and repainting all thirteen surfaces at the
banner's rate took the layout suite from 25 seconds to 171 — every frame
affordable, five times more of them than the picture needed.

**Zones are composited** (`WS_EX_COMPOSITED`) like the banner. `AutoScroll`
scrolls by blitting the pixels it already has and repainting only the strip newly
exposed, which is right when a background belongs to its control and wrong when
it is anchored to the window — the artwork smeared and piled up as a zone
scrolled. Compositing fixes it while the bar is moving; a repaint on `Scroll`
fixes it when the drag ends.

**Where the artwork appears.** Behind the banner, every panel, the zones and the
log; behind the **splash screen**; behind every **dialog header** (Find a
computer, Settings, About — they all come from `New-ListDialog`); and as the
**Run button's operation glyph**. The status bar needed nothing: it is a
registered surface already. All of it follows XAML mode, and all of it falls
back to what shipped before when the toggle is off.

The Run button's glyph comes from `xaml\icons.xaml`, a sheet of five 24x24 cells
rather than five files — one parse and one render for the set, cropped per cell
and cached by size. The cell is chosen from the button's own caption, so what it
says and what it shows cannot disagree, and the text arrow stays in the caption
so the button still reads correctly with the artwork off.

Motion layers stay in code: they are scrolled to animate, so they have to tile,
and that is a different job from drawing a picture.

### Adding or changing a theme

Add an entry to `$Script:Themes` and it appears in **View ▸ Theme** on its own —
the menu and the picker both read `Get-ThemeNames`. Optionally give it an
`Accents` block; anything it leaves out falls back to the colours the tool
shipped with, so the operation colours stay recognisable.

`tests\theme.ps1` then checks it automatically: every tagged control type takes
the new colours, body and dim text clear their panel, the log clears its
background, the divider is visible, and every filled button's label is legible
on its fill. Text on an accent is *computed* (`Get-ContrastingText`) rather than
assumed white, so a pale accent gets dark text by itself.

Fonts come from `New-UTWFont`, which resolves `Inter → Segoe UI → …` once. Where
Inter is not installed the tool looks exactly as it always has.

---

## Tidying up the old machine

**Delete stale user profiles** (in Options) applies to a **capture** as well as
to Clean Up. Tick it before an Export or an Export + Import and, once the store
has been written and recorded, UTW lists the profiles on the source machine that
have not been used for the configured number of days and offers to remove them —
folder and registry entry together, the way System Properties does it.

- The profile this run just captured is **never** in that list. Removing it is a
  different decision with its own Expert option and its own confirmation.
- Signed-in, system and your own profiles are never offered.
- Nothing is deleted without ticking the option, ticking the rows, and
  confirming a list that reads back exactly what was ticked.

**Clean up USMT files** now also removes the store folder itself (`USMT Profiles`
by default) once the stores inside it have gone, so a cleaned machine has no
leftover folder on the root of C:. It refuses unless the folder's name matches
the configured store folder exactly, it sits directly under a drive or share
root, and there is not a single file left anywhere inside it.

---

## Finding your way around the window

The window is three **zones** with two draggable dividers, and every panel can be
sent to any zone.

| Where | What starts there |
|---|---|
| Left column | The setup, top to bottom in the order you fill it in: Header, USMT Location, Operation, Migration Details, Options, (Expert), Actions, Summary. |
| Right, top | **Lookup** — the profiles on the machine being captured, or the stores this operation would read. Fills the fields on the left from what you pick: double-click uses a row, right-click can *add* a user to the list for a multi-user capture. |
| Right, bottom | **Output log** — what this window has done. Right-click to copy, save or clear it. Not the USMT log and not the crash log. |
| Foot | Status, progress, and the **Logs:** path — click it to open the folder. |

### Why a panel never collapses to nothing

The zones stack their panels with `Dock`, and the one marked *Fill* takes
whatever the fixed-height ones leave. When they add up to more than the zone,
that is **nothing at all** — measured, the Fill panel goes to height 0. Turning
Expert mode on adds a tall panel and did exactly that to the summary: it
vanished, and no amount of scrolling brought it back, because a zero-height
control adds nothing to scroll to.

Every Fill panel therefore carries a **minimum height** as well as a minimum
width, so it keeps its size.

That alone was not enough to reach it. `AutoScroll` works its range out from
children *positioned* past the edge, and a docked child never is — Dock lays out
inside whatever room is left. So the scroll range stayed at the visible height
and stopped at the last panel that happened to fit: "you can't scroll past the
actions bar", with the summary below it real, sized and unreachable. Each zone
now sets `AutoScrollMinSize` to the true height of its stack, which it knows
exactly, because it just laid it out.

`tests\layout.ps1` fails if any Fill panel drops below 40px or has no floor.

### Moving the panels

**View ▸ Panels** has a tick for every panel — turn any of them off and back on
from there.

**View ▸ Panels ▸ Customize layout** is the full editor:

- **Drag a row** to move it — anywhere within its zone to reorder, or onto
  another zone's heading to send it there. An insertion mark shows where it will
  land.
- **Click a row's "Where" cell** and pick a zone from a list. Same result; this
  is the discoverable half of the same feature.
- There is a **Hidden** section at the bottom. Drag a panel into it to put it
  away, or out of it to bring it back.

Actions and the header can be moved but not hidden — without them there is no way
to start a migration and no way back to Expert mode. **Reset** puts everything
back.

Every dialog in the tool — Settings, the store browser, the user picker, AD
search, Customize layout — can be resized and maximized, and the last column of
each list takes up the slack so widening the window widens the column most
likely to be truncated.

**Summary** is a panel like any other. It fills whatever space is left in the
left column and says, in plain English, what pressing Run will do: which
machines, which user, where the store lands, which options are on, and — in red
— anything that will change or destroy data.

**Expert mode** is the toggle in the header, mirrored by the **Expert** entry in
View ▸ Panels. Those are the same two places every other panel has; there is no
third Simple/Expert pair in the View menu.

Panels stretch to fill their zone, and their contents stretch with them: drag the
divider right and the machine boxes, the Run button and the Expert command line
all get wider. They will not shrink below the width they were designed at —
nothing can make a labelled row narrower than its label plus its box — so the
divider stops there, and a panel sent to a zone narrower than that gets a scroll
bar rather than having its right-hand end clipped off.

Both divider positions and the whole panel arrangement are remembered between
sessions, stored at design scale so they mean the same thing on a laptop and on
a 4K monitor.

This is not foobar2000's free-form docking — you cannot drag a panel anywhere and
split arbitrarily. It is zone placement plus ordering plus two dividers, which is
what fits in a WinForms app without carrying a docking framework.

Three different logs, so it is worth being precise:

| Log | What it is | Where |
|---|---|---|
| Output log | UTW's running commentary on this session | the pane on the right; **File ▸ Save output log** |
| USMT logs | `scanstate.log` / `loadstate.log` / `progress.log` | the **Logs:** folder in the status bar |
| `CrashLog.txt` | UTW's own diagnostics, including the finished window geometry | beside the script |

**View ▸ Layout** sets the width of the setup column, hides the lookup panel when
you want the whole right side for the log, and resets everything. Where you leave
the dividers is remembered between sessions, and stored in design pixels so it
means the same thing on a laptop and on a 4K monitor.
