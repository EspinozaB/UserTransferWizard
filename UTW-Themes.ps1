#Requires -Version 5.1
<#
.SYNOPSIS
    Theme definitions and Apply-Theme logic for User Transfer Wizard (UTW).
    Dot-sourced by UTW-Main.ps1 - do not run directly.
#>

# ===========================================================================
#  DESIGN TOKENS
# ===========================================================================
# Taken from the Neo design system (designSystemTemplate.responsive.v10 /
# neo-template-demo-vite-v10). Those are CSS custom properties; this is the
# same set expressed where a WinForms app can use it, so the tool matches the
# house style without pretending to be a web page.
#
# WHAT TRANSFERS
#   colours    - one-for-one, mapped semantically below
#   spacing    - the 0.25rem scale, in design pixels (1rem = 16px)
#   typography - the family, with a fallback chain
#
# WHAT DOES NOT
#   --radius   - WinForms controls are rectangles. Rounded corners need
#                owner-drawn painting on every button, which is a piece of work
#                in its own right; the values are recorded here so that when
#                that is done it uses the right numbers rather than new ones.
#   shadows    - same story: no CSS box-shadow equivalent without owner-draw.
$Script:Tokens = @{
    # --spacing-1 .. --spacing-8, in design pixels at 1.0 scale.
    Space = @{ "1" = 4; "2" = 8; "3" = 12; "4" = 16; "5" = 20; "6" = 24; "8" = 32 }
    # --radius-sm .. --radius-full. Unused today; see above.
    Radius = @{ Sm = 4; Base = 8; Md = 12; Lg = 16; Full = 9999 }
    # --font-family-base, as a fallback chain. The first family actually
    # installed wins - Inter is the house font but is not on every machine, and
    # asking GDI+ for a missing family silently substitutes something arbitrary.
    # Inter is the house font. Where it is not installed the chain falls back to
    # plain Segoe UI - deliberately AHEAD of Segoe UI Variable, which is what
    # Windows 11 would otherwise pick up. Variable is arguably the closer match
    # to Inter, but it is not what this tool has ever looked like, and silently
    # restyling every machine that happens to run Win11 is not a decision a
    # font-fallback list should be making on its own.
    FontStack = @("Inter", "Segoe UI", "Segoe UI Variable Text", "Tahoma")
    MonoStack = @("Cascadia Mono", "Consolas", "Courier New")
    # The type scale, in points.
    Size = @{ Small = 8.5; Base = 9.5; Section = 10; Heading = 11; Title = 14; Display = 15 }
}

function Resolve-FontFamily {
    <#
        First installed family from a fallback chain.

        GDI+ does not fail when asked for a font that is not installed - it
        quietly substitutes, and which substitute you get varies by machine. So
        the chain is resolved once, explicitly, and the answer reused.
    #>
    param([string[]]$Stack)
    if (-not $Script:FontFamilyCache) { $Script:FontFamilyCache = @{} }
    $key = ($Stack -join "|")
    if ($Script:FontFamilyCache.ContainsKey($key)) { return $Script:FontFamilyCache[$key] }
    $chosen = $Stack[-1]
    try {
        $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
        foreach ($f in $Stack) { if ($installed -contains $f) { $chosen = $f; break } }
    } catch { }
    $Script:FontFamilyCache[$key] = $chosen
    return $chosen
}

function New-UTWFont {
    <#
        A font from the token scale, in the house family.

        Every font in the tool comes through here, so changing the family or the
        scale is one edit rather than fifty. -Name takes a token name (Base,
        Small, Section, Heading, Title, Display) or a literal point size.
    #>
    param(
        [string]$Name = "Base",
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [switch]$Mono
    )
    $pt = if ($Script:Tokens.Size.ContainsKey($Name)) { $Script:Tokens.Size[$Name] }
          else { [double]$Name }
    $family = if ($Mono) { Resolve-FontFamily $Script:Tokens.MonoStack }
              else       { Resolve-FontFamily $Script:Tokens.FontStack }
    if (-not $Script:FontCache) { $Script:FontCache = @{} }
    $key = "$family|$pt|$([int]$Style)"
    if (-not $Script:FontCache.ContainsKey($key)) {
        $Script:FontCache[$key] = New-Object System.Drawing.Font($family, [float]$pt, $Style)
    }
    return $Script:FontCache[$key]
}

# Shorthand for the palette below: the templates are written in hex.
function ConvertFrom-Hex {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(
        [Convert]::ToInt32($h.Substring(0,2),16),
        [Convert]::ToInt32($h.Substring(2,2),16),
        [Convert]::ToInt32($h.Substring(4,2),16))
}

$Script:Themes = @{
    "Dark" = @{
        Primary   = [System.Drawing.Color]::FromArgb(0, 120, 212)
        DarkBg    = [System.Drawing.Color]::FromArgb(45, 45, 48)
        MedBg     = [System.Drawing.Color]::FromArgb(60, 60, 64)
        LightBg   = [System.Drawing.Color]::FromArgb(37, 37, 38)
        Text      = [System.Drawing.Color]::White
        TextDim   = [System.Drawing.Color]::FromArgb(180, 180, 180)
        Success   = [System.Drawing.Color]::FromArgb(76, 175, 80)
        Warning   = [System.Drawing.Color]::FromArgb(255, 193, 7)
        Error     = [System.Drawing.Color]::FromArgb(244, 67, 54)
        GroupBg   = [System.Drawing.Color]::FromArgb(50, 50, 54)
        OutputBg  = [System.Drawing.Color]::FromArgb(30, 30, 34)
        OutputFg  = [System.Drawing.Color]::FromArgb(200, 200, 200)
        DarkTitle = $true
    }
    "Solarized Dark" = @{
        Primary   = [System.Drawing.Color]::FromArgb(38, 139, 210)
        DarkBg    = [System.Drawing.Color]::FromArgb(0, 43, 54)
        MedBg     = [System.Drawing.Color]::FromArgb(7, 54, 66)
        LightBg   = [System.Drawing.Color]::FromArgb(0, 34, 43)
        Text      = [System.Drawing.Color]::FromArgb(238, 232, 213)
        TextDim   = [System.Drawing.Color]::FromArgb(147, 161, 161)
        Success   = [System.Drawing.Color]::FromArgb(133, 153, 0)
        Warning   = [System.Drawing.Color]::FromArgb(181, 137, 0)
        Error     = [System.Drawing.Color]::FromArgb(220, 50, 47)
        GroupBg   = [System.Drawing.Color]::FromArgb(7, 54, 66)
        OutputBg  = [System.Drawing.Color]::FromArgb(0, 34, 43)
        OutputFg  = [System.Drawing.Color]::FromArgb(131, 148, 150)
        DarkTitle = $true
    }
    "Light" = @{
        Primary   = [System.Drawing.Color]::FromArgb(0, 99, 177)
        DarkBg    = [System.Drawing.Color]::FromArgb(243, 243, 243)
        MedBg     = [System.Drawing.Color]::FromArgb(255, 255, 255)
        LightBg   = [System.Drawing.Color]::FromArgb(250, 250, 250)
        Text      = [System.Drawing.Color]::FromArgb(30, 30, 30)
        TextDim   = [System.Drawing.Color]::FromArgb(100, 100, 100)
        Success   = [System.Drawing.Color]::FromArgb(46, 125, 50)
        Warning   = [System.Drawing.Color]::FromArgb(230, 162, 0)
        Error     = [System.Drawing.Color]::FromArgb(211, 47, 47)
        GroupBg   = [System.Drawing.Color]::FromArgb(235, 235, 235)
        OutputBg  = [System.Drawing.Color]::FromArgb(255, 255, 255)
        OutputFg  = [System.Drawing.Color]::FromArgb(50, 50, 50)
        DarkTitle = $false
    }
    "Clown Fiesta" = @{
        Primary   = [System.Drawing.Color]::FromArgb(245, 200, 66)    # gold #f5c842
        DarkBg    = [System.Drawing.Color]::FromArgb(26, 10, 46)      # #1a0a2e
        MedBg     = [System.Drawing.Color]::FromArgb(45, 16, 96)      # #2d1060
        LightBg   = [System.Drawing.Color]::FromArgb(18, 6, 42)       # #12062a
        Text      = [System.Drawing.Color]::FromArgb(255, 248, 231)   # cream #fff8e7
        TextDim   = [System.Drawing.Color]::FromArgb(180, 140, 220)   # lavender
        Success   = [System.Drawing.Color]::FromArgb(46, 196, 182)    # teal #2ec4b6
        Warning   = [System.Drawing.Color]::FromArgb(245, 200, 66)    # gold #f5c842
        Error     = [System.Drawing.Color]::FromArgb(230, 57, 70)     # red #e63946
        GroupBg   = [System.Drawing.Color]::FromArgb(45, 16, 96)      # #2d1060
        OutputBg  = [System.Drawing.Color]::FromArgb(18, 6, 42)       # #12062a
        OutputFg  = [System.Drawing.Color]::FromArgb(255, 110, 180)   # pink #ff6eb4
        DarkTitle = $true
    }
    "Fresh Water" = @{
        Primary   = [System.Drawing.Color]::FromArgb(91, 194, 231)    # WA Blue #5BC2E7
        DarkBg    = [System.Drawing.Color]::FromArgb(0, 49, 80)       # Navy #003150
        MedBg     = [System.Drawing.Color]::FromArgb(0, 70, 110)      # mid navy
        LightBg   = [System.Drawing.Color]::FromArgb(0, 38, 62)       # deep navy
        Text      = [System.Drawing.Color]::FromArgb(220, 240, 250)   # ice white
        TextDim   = [System.Drawing.Color]::FromArgb(120, 170, 200)   # muted sky
        Success   = [System.Drawing.Color]::FromArgb(162, 173, 0)     # Green #A2AD00
        Warning   = [System.Drawing.Color]::FromArgb(233, 153, 74)    # Orange #E9994A
        Error     = [System.Drawing.Color]::FromArgb(237, 27, 47)     # Red #ED1B2F
        GroupBg   = [System.Drawing.Color]::FromArgb(0, 58, 94)       # group navy
        OutputBg  = [System.Drawing.Color]::FromArgb(0, 34, 56)       # deep water
        OutputFg  = [System.Drawing.Color]::FromArgb(91, 194, 231)    # WA Blue #5BC2E7
        DarkTitle = $true
    }
    "Waste Water" = @{
        Primary   = [System.Drawing.Color]::FromArgb(108, 122, 70)    # Muted Olive / Sludge Green
        DarkBg    = [System.Drawing.Color]::FromArgb(35, 38, 32)      # Deep Murky Earth
        MedBg     = [System.Drawing.Color]::FromArgb(48, 52, 44)      # Dark Moss
        LightBg   = [System.Drawing.Color]::FromArgb(30, 32, 28)      # Deep Silt
        Text      = [System.Drawing.Color]::FromArgb(215, 220, 200)   # Pale Sage White
        TextDim   = [System.Drawing.Color]::FromArgb(130, 135, 115)   # Muted Lichen
        Success   = [System.Drawing.Color]::FromArgb(102, 140, 70)    # Algae Green
        Warning   = [System.Drawing.Color]::FromArgb(180, 140, 60)    # Brackish Yellow/Ochre
        Error     = [System.Drawing.Color]::FromArgb(165, 75, 60)     # Rust Red
        GroupBg   = [System.Drawing.Color]::FromArgb(42, 46, 38)      # Industrial Grey-Green
        OutputBg  = [System.Drawing.Color]::FromArgb(25, 28, 24)      # Sediment Black
        OutputFg  = [System.Drawing.Color]::FromArgb(145, 155, 120)   # Reclaimed Water Green
        DarkTitle = $true
    }
}

# ---------------------------------------------------------------------------
#  The Neo themes
# ---------------------------------------------------------------------------
# Mapped SEMANTICALLY from the template, not literally. Two places where a
# literal copy would be wrong:
#
#   --primary   is #f8fafc in the dark palette - near-white. In that design
#               system "primary" means a high-contrast surface. Here Primary is
#               the ACCENT: group captions, the title, the Run button. Taking
#               the name rather than the meaning would give a white Run button
#               with white text. UTW's Primary maps to --info, the palette's
#               actual accent hue.
#
#   --card      equals --background in the dark palette, which would make every
#               group box invisible against the form behind it. Panels take
#               --muted so they read as raised surfaces.
$Script:Themes["Neo Dark"] = @{
    Primary   = (ConvertFrom-Hex "#3b82f6")   # --info
    DarkBg    = (ConvertFrom-Hex "#020817")   # --background
    MedBg     = (ConvertFrom-Hex "#1e293b")   # --input
    LightBg   = (ConvertFrom-Hex "#0f172a")   # --sidebar
    Text      = (ConvertFrom-Hex "#f8fafc")   # --foreground
    TextDim   = (ConvertFrom-Hex "#94a3b8")   # --muted-foreground
    Success   = (ConvertFrom-Hex "#10b981")   # --success
    Warning   = (ConvertFrom-Hex "#f59e0b")   # --warning
    Error     = (ConvertFrom-Hex "#ef4444")   # --error, not --destructive:
                                              # #7f1d1d is a surface colour and
                                              # unreadable as text on this panel
    GroupBg   = (ConvertFrom-Hex "#1e293b")   # --muted
    OutputBg  = (ConvertFrom-Hex "#020817")   # --background
    OutputFg  = (ConvertFrom-Hex "#cbd5e1")   # --ring, legible on the log
    DarkTitle = $true
    Accents   = @{
        Cyan = "#38bdf8"; Green = "#10b981"; Orange = "#f59e0b"
        Purple = "#8b5cf6"; Slate = "#64748b"; Teal = "#14b8a6"; Stone = "#78716c"
    }
}
$Script:Themes["Neo Light"] = @{
    Primary   = (ConvertFrom-Hex "#2563eb")   # --info, a step darker for white
    DarkBg    = (ConvertFrom-Hex "#f1f5f9")   # --muted, the desk behind the cards
    MedBg     = (ConvertFrom-Hex "#f8fafc")   # field fill; --input is its border
    LightBg   = (ConvertFrom-Hex "#ffffff")
    Text      = (ConvertFrom-Hex "#0f172a")   # --foreground
    TextDim   = (ConvertFrom-Hex "#64748b")   # --muted-foreground
    Success   = (ConvertFrom-Hex "#059669")
    Warning   = (ConvertFrom-Hex "#b45309")   # darkened: #f59e0b on white fails
    Error     = (ConvertFrom-Hex "#dc2626")
    GroupBg   = (ConvertFrom-Hex "#ffffff")   # --card
    OutputBg  = (ConvertFrom-Hex "#ffffff")
    OutputFg  = (ConvertFrom-Hex "#334155")
    DarkTitle = $false
    Accents   = @{
        Cyan = "#0284c7"; Green = "#059669"; Orange = "#b45309"
        Purple = "#7c3aed"; Slate = "#475569"; Teal = "#0d9488"; Stone = "#57534e"
    }
}

# The accent colours every theme falls back to. These are the values the tool
# shipped with, so a theme that says nothing about accents looks exactly as it
# did before tokens existed.
$Script:DefaultAccents = @{
    Orange = "#e67e22"; Cyan = "#00bcd4"; Purple = "#9c27b0"
    Green  = "#4caf50"; Slate = "#606e7d"; Teal = "#008996"; Stone = "#6e6058"
}

function Set-AccentColors {
    <#
        Publishes the active theme's accent set as $Script:AccentOrange and
        friends, which is how the ~30 places that use them read them.

        These used to be seven fixed FromArgb literals in UTW-Main, so the
        operation colours - Extract orange, Import green, the combo purple -
        stayed the same in every theme whether they suited it or not. Now they
        are part of the theme, and a theme that does not define them gets the
        original values.
    #>
    $set = $Script:DefaultAccents.Clone()
    if ($Script:T.Accents) {
        foreach ($k in $Script:T.Accents.Keys) { $set[$k] = $Script:T.Accents[$k] }
    }
    $Script:AccentOrange = ConvertFrom-Hex $set.Orange
    $Script:AccentCyan   = ConvertFrom-Hex $set.Cyan
    $Script:AccentPurple = ConvertFrom-Hex $set.Purple
    $Script:AccentGreen  = ConvertFrom-Hex $set.Green
    $Script:AccentSlate  = ConvertFrom-Hex $set.Slate
    $Script:AccentTeal   = ConvertFrom-Hex $set.Teal
    $Script:AccentStone  = ConvertFrom-Hex $set.Stone
}

# The shipped default is the house theme. Everything the window builds reads
# $Script:T as it is created, so this has to be the theme the picker also shows
# - set the picker to one thing and this to another and the window is built in
# one palette while claiming to be in the other.
# What the tool starts as when nothing has been saved yet. Kept in step with the
# Theme written into UTW_Settings.json by New-FactorySettingsFile - if the two
# disagree, a first run and a reset land on different themes.
$Script:DefaultTheme = "Dark"
$Script:T = $Script:Themes[$Script:DefaultTheme]
Set-AccentColors

# ===========================================================================
#  BACKGROUND OVERLAYS
# ===========================================================================
# A themed backdrop painted behind the panels. Off by default; toggled from
# View > Theme > Background graphics and remembered.
#
# HOW IT STAYS CHEAP
#   The art is rendered ONCE into a bitmap the size of the surface and blitted
#   on every paint. A resize frame is already down to ~10 ms and a divider drag
#   repaints constantly, so drawing 250 shapes per paint would have undone the
#   work of the last few rounds. Re-render happens only when the size, the
#   theme, or the toggle changes - and the perf test gates it.
#
# WHERE IT SHOWS
#   The group boxes are opaque, so the backdrop appears in the margins, in the
#   gaps between panels, and - most visibly - behind the header block, whose
#   labels are transparent.
$Script:OverlayEnabled = $false
$Script:OverlayCache   = @{}
$Script:OverlayTints   = @{}
# The expensive part: one real render per (theme, surface, layer). Every size the
# window actually asks for is a scaled copy of one of these.
$Script:OverlayMasters = @{}
# The most recent bitmap per (theme, surface, layer), so a drag can reach for
# one in a single lookup instead of scanning the whole cache.
$Script:OverlayLast    = @{}

function Clear-OverlayCache {
    <#
        Called when the theme changes or the backdrop is toggled - NOT on a
        resize, which is the whole point of the split below.

        The masters go too, because a painter reads the live theme's colours and
        a theme change makes them wrong. That costs one render per surface once,
        against the old behaviour of re-running the painters at every new size
        for the rest of the session.
    #>
    foreach ($k in @($Script:OverlayCache.Keys)) {
        try { $Script:OverlayCache[$k].Dispose() } catch { }
    }
    $Script:OverlayCache = @{}
    $Script:OverlayLast  = @{}
    $Script:OverlayTints = @{}

    # THE MASTERS ARE KEPT, up to a couple of themes' worth.
    #
    # They are keyed by theme, so a master for a theme you are not looking at is
    # still correct - and switching back to a theme you were just on is then
    # free rather than a fresh render of every surface. That is the delay when
    # flipping between themes. Only when the cache grows past two themes'
    # worth does the oldest theme get thrown away.
    $keep = @{}
    foreach ($k in @($Script:OverlayMasters.Keys)) {
        $themeOf = ($k -split '\|')[0]
        $keep[$themeOf] = $true
    }
    if ($keep.Count -gt 2) {
        foreach ($k in @($Script:OverlayMasters.Keys)) {
            if (($k -split '\|')[0] -eq $Script:CurrentThemeName) { continue }
            try { $Script:OverlayMasters[$k].Dispose() } catch { }
            $Script:OverlayMasters.Remove($k)
        }
    }
}

# Which themes have something worth moving. A theme not listed here is drawn
# once and never touched again, so the animation timer costs it nothing.
# Every theme with artwork now has something that drifts, so the switch is
# meaningful wherever the graphics are.
$Script:AnimatedThemes = @("Clown Fiesta", "Neo Dark", "Neo Light", "Fresh Water", "Waste Water",
                           "Dark", "Light", "Solarized Dark")
# On by default, so switching the artwork on gives you the artwork MOVING and
# the switch below it is there to turn that off. The graphics themselves are
# still off by default, so nothing animates until somebody asks for a backdrop.
$Script:OverlayAnimate = $true
$Script:OverlayPhase   = 0

# WHICH SURFACES MOVE, and why it is not all of them.
#
# Animating everything was tried and measured: one tick cost ~180 ms, because a
# tick means alpha-blending a full-size transparent layer twice onto each of six
# surfaces, and the zone layers are the size of the window. At 20 frames a
# second that is not an animation, it is a stall.
#
# The header is small (~950x105) and it is where the artwork is actually visible
# - the panels below it are opaque and show the backdrop only through 8px gaps,
# where drifting confetti reads as flicker rather than motion. So the banner
# moves and the rest stays put, which costs a twentieth as much and looks better
# than the alternative did.
#
# Animating the panels as well was tried, and it HUNG THE APPLICATION. With
# Clown Fiesta on every panel a tick costs more than the 50 ms interval, so
# there is always a fresh timer message waiting, Application.DoEvents never
# drains the queue and never returns, and the window stops responding. The
# earlier "~180 ms a frame" measurement was the same fact stated politely.
#
# So the answer to "the animation is barely noticeable" is not more surfaces,
# it is more movement on the surface that can afford it: the banner now carries
# two layers travelling in opposite directions at 5 and 3 px a tick instead of
# one drifting at 2, and the panels keep their full artwork standing still.
#
# MEASURED AGAIN, with the panels switched on and the timer instrumented:
# frames arrived 643, 674 and finally 1,105 ms apart, and the window still
# stopped responding after the animation had backed itself off to 400 ms. One
# repaint of every panel costs the better part of a second.
#
# The blits inside that account for about 20 ms of it - a panel-sized ground
# plus four motion blits measures 1.5 ms. The rest is WinForms compositing the
# 48 transparent captions: a caption with a transparent background is rendered
# by asking its PARENT to paint again, clipped to the caption, so invalidating
# one panel does not cost one paint, it costs one per caption on it. That is the
# same transparency that removed the boxes from behind the text, and it is worth
# far more than moving confetti behind a form nobody is watching.
$Script:AnimatedSurfaces = @("header")

# WHAT MOVES, WHICH WAY, AND HOW FAST.
#
# One scrolling layer in one direction reads as a slide, not as motion. Each
# theme gets two, going opposite ways at different speeds, which is what makes
# it look like confetti falling past balloons rising rather than a picture being
# dragged. Speed is pixels per tick at 20 fps; Axis is which way it wraps.
$Script:MotionSpec = @{
    "Clown Fiesta" = @( @{ Layer = "motion";  Axis = "Y"; Speed =  5 }    # confetti falling
                        @{ Layer = "motion2"; Axis = "Y"; Speed = -3 } )  # balloons rising
    # Motes rise (the canvas loop); the aurora ribbons drift sideways and very
    # slowly, the way a 34-50 second CSS animation does.
    "Neo Dark"    = @( @{ Layer = "motion";  Axis = "Y"; Speed = -3 }    # rising motes
                        @{ Layer = "motion2"; Axis = "X"; Speed =  1 } )  # aurora drift
    "Neo Light"   = @( @{ Layer = "motion";  Axis = "Y"; Speed = -3 }
                        @{ Layer = "motion2"; Axis = "X"; Speed =  1 } )
    "Fresh Water"  = @( @{ Layer = "motion";  Axis = "Y"; Speed = -4 }    # bubbles rising
                        @{ Layer = "motion2"; Axis = "X"; Speed =  3 } )  # shimmer sliding
    "Waste Water"  = @( @{ Layer = "motion";  Axis = "Y"; Speed = -3 }
                        @{ Layer = "motion2"; Axis = "X"; Speed =  2 } )  # scum drifting
    "Dark"         = @( @{ Layer = "motion";  Axis = "X"; Speed =  4 }    # the 'crawl'
                        @{ Layer = "motion2"; Axis = "X"; Speed = -2 } )
    "Light"        = @( @{ Layer = "motion";  Axis = "X"; Speed =  4 }
                        @{ Layer = "motion2"; Axis = "X"; Speed = -2 } )
    # The wheel turns very slowly in the source (300s a revolution), so this
    # one drifts rather than races.
    "Solarized Dark" = @( @{ Layer = "motion";  Axis = "X"; Speed =  2 }
                          @{ Layer = "motion2"; Axis = "Y"; Speed = -2 } )
}

function Get-OverlayTint {
    <#
        The artwork's own average colour, blended into a control's background.

        A RichTextBox and a ListView are opaque and WinForms gives no supported
        way round it. WS_EX_TRANSPARENT was built and measured: it made 300
        appends take 1387 ms against 489 ms - 2.8x - on the one control that
        tells anybody what a migration actually did, and RichEdit smears it on
        scroll. Not worth it.

        So instead of showing THROUGH the log, the log is coloured FROM the
        artwork. With the group painting the real picture in the margin around
        it, the log reads as sitting on the backdrop rather than as a grey hole
        punched in it, and it costs one 64x40 render per theme.
    #>
    param([string]$Surface, $Base, [double]$Mix = 0.45)
    if (-not $Script:OverlayEnabled) { return $Base }
    $key = "tint|$Script:CurrentThemeName|$Surface"
    if ($Script:OverlayTints.ContainsKey($key)) { return $Script:OverlayTints[$key] }
    $r = 0; $g2 = 0; $b = 0; $n = 0
    try {
        $bmp = New-Object System.Drawing.Bitmap(64, 40)
        $gr = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gr.Clear($Script:T.DarkBg)
            $painter = if ($Script:OverlayPainters.ContainsKey($Script:CurrentThemeName)) {
                           $Script:OverlayPainters[$Script:CurrentThemeName]
                       } else { $Script:OverlayPainters["*"] }
            & $painter $gr 64 40 $Surface "ground"
        } finally { $gr.Dispose() }
        for ($x = 0; $x -lt 64; $x += 4) {
            for ($y = 0; $y -lt 40; $y += 4) {
                $p = $bmp.GetPixel($x, $y); $r += $p.R; $g2 += $p.G; $b += $p.B; $n++
            }
        }
        $bmp.Dispose()
    } catch { return $Base }
    if ($n -eq 0) { return $Base }
    $out = [System.Drawing.Color]::FromArgb(
        [int]($Base.R + ((($r / $n) - $Base.R) * $Mix)),
        [int]($Base.G + ((($g2 / $n) - $Base.G) * $Mix)),
        [int]($Base.B + ((($b / $n) - $Base.B) * $Mix)))
    $Script:OverlayTints[$key] = $out
    return $out
}

function Get-MotionSpec {
    param([string]$ThemeName)
    if ($Script:MotionSpec.ContainsKey($ThemeName)) { return $Script:MotionSpec[$ThemeName] }
    return @()
}

function Test-OverlayAnimated {
    param([string]$ThemeName, [string]$Surface = "header")
    return ($Script:OverlayEnabled -and $Script:OverlayAnimate -and
            ($Script:AnimatedThemes -contains $ThemeName) -and
            ($Script:AnimatedSurfaces -contains $Surface))
}

function Get-OverlayBitmap {
    <#
        One LAYER of the backdrop for one surface, at one size, in the current
        theme - rendered on first use and cached until something invalidates it.

        Two layers, because the animation is done by SCROLLING rather than by
        redrawing:
          ground - the radial background, the bunting, the shimmer. Static.
          motion - confetti and balloons on a transparent bitmap. Drawn twice,
                   offset, so it drifts endlessly for the cost of two blits.
        Redrawing 250 shapes at 20 frames a second was never going to be
        affordable; moving two pictures is.
    #>
    param([string]$Surface, [int]$Width, [int]$Height, [string]$ThemeName, [string]$Layer = "ground")
    if (-not $Script:OverlayEnabled -or $Width -lt 8 -or $Height -lt 8) { return $null }

    # SIZE QUANTISING. Caching on the exact pixel size means a window resize is
    # a cache miss for every panel on every frame, and a miss now costs 20-40 ms
    # because the artwork is real. Rounding up to a 64px grid makes a resize
    # reuse the same bitmap until it crosses a boundary; the surplus is simply
    # clipped by the control it is drawn into.
    #
    # The banner is exempt. It is the one surface whose composition is anchored
    # to its own edges - the clowns stand on the bottom of it - so it is drawn
    # at exactly the size it will be shown at. There is only one of it, so the
    # miss storm this avoids was never coming from there anyway.
    if ($Surface -ne "header") {
        $grid = 64
        $Width  = [int]([Math]::Ceiling($Width  / $grid) * $grid)
        $Height = [int]([Math]::Ceiling($Height / $grid) * $grid)
    }
    $key = "$ThemeName|$Surface|$Layer|$Width|$Height"
    if ($Script:OverlayCache.ContainsKey($key)) { return $Script:OverlayCache[$key] }

    # MID-DRAG: reuse whatever was last drawn for this surface rather than
    # rendering a new one.
    #
    # "Cache by size" is exactly wrong during a resize - the size changes every
    # frame, so every frame is a miss, and a miss costs 46 ms (66 for Clown
    # Fiesta). That would have handed back all of the resize performance the
    # moment somebody switched the backdrop on. The stale bitmap is the wrong
    # size for a few hundred milliseconds, which at worst leaves a sliver of
    # plain background at one edge while the mouse is down; the correct one is
    # rendered when the drag ends.
    # Straight to the last one drawn for this surface. Scanning every cache key
    # with a wildcard was O(cache) on every paint of every surface, which grows
    # as a drag accumulates sizes - and a diagonal drag accumulates them twice as
    # fast as a horizontal one, because both dimensions cross their grid.
    $lastKey = "$ThemeName|$Surface|$Layer"
    if ($Script:Dragging) {
        if ($Script:OverlayLast.ContainsKey($lastKey)) { return $Script:OverlayLast[$lastKey] }
        return $null          # nothing to reuse yet - draw nothing, not slowly
    }

    # Anything cached for a different size or theme is dead weight; a divider
    # drag would otherwise leave a bitmap per pixel of travel.
    foreach ($k in @($Script:OverlayCache.Keys)) {
        if ($k -notlike "$ThemeName|$Surface|$Layer|*" ) { continue }
        try { $Script:OverlayCache[$k].Dispose() } catch { }
        $Script:OverlayCache.Remove($k)
    }

    # SCALED FROM A MASTER, not painted again.
    #
    # Every size used to re-run the painter, and the painters are now real
    # artwork - a Clown Fiesta banner is 250-odd shapes and a Solarized wheel is
    # 16 gradient-filled wedges. That made a theme change and a window resize
    # both cost a burst of full renders, which is what "switching themes with
    # backgrounds slows things down" was.
    #
    # So each (theme, surface, layer) is painted ONCE at a generous master size
    # and every actual size is a scaled blit off that master. Same idea as
    # pre-rendering the SVGs to an image, except the master is produced by the
    # same painter, so there is nothing to keep in step and no files to ship.
    $master = Get-OverlayMaster -Surface $Surface -Layer $Layer -ThemeName $ThemeName
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        if ($Layer -eq "ground") { $g.Clear($Script:T.DarkBg) }
        else                     { $g.Clear([System.Drawing.Color]::Transparent) }
        if ($master) {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
            $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
            # COVER-CROP, the way the source files are full-viewport backgrounds:
            # take the largest region of the master with the target's aspect and
            # scale it to fit, rather than stretching and distorting. Anchored to
            # the BOTTOM, because that is where the bottom-anchored artwork lives
            # - the clowns stand on the bottom edge.
            $ar = $Width / [double]$Height
            $mw = $master.Width; $mh = $master.Height
            $sw2 = $mw; $sh2 = [int]($mw / $ar)
            if ($sh2 -gt $mh) { $sh2 = $mh; $sw2 = [int]($mh * $ar) }
            $sx = [int](($mw - $sw2) / 2); $sy = $mh - $sh2
            $dst = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
            $src = New-Object System.Drawing.Rectangle($sx, $sy, $sw2, $sh2)
            $g.DrawImage($master, $dst, $src, [System.Drawing.GraphicsUnit]::Pixel)
        }
        # THE BANNER'S SCRIM, in place of a text halo.
        #
        # All of the banner's captions live in its top band - the title and
        # subtitle on the left, the mode and administrator warning on the right -
        # and the artwork below them carries no text at all. So the top fades
        # down into the theme's own dark ground and the bottom keeps the picture
        # at full strength, which is where the clowns are standing anyway.
        #
        # This replaces the halo, which could not be made to work: a Label paints
        # with GDI and a halo paints with GDI+, and the two lay the same string
        # out 1px apart, so the outline always landed off-centre. A gradient is
        # not text and cannot be misaligned with anything.
        # HELD across the caption band, then faded. A gradient that starts fading
        # at the top row protects the title and abandons the subtitle, which sits
        # at 40-70% of the height - measured at 1.00:1 with exactly that bug.
        # SIDEWAYS, not downwards.
        #
        # A band across the top covered 62% of the banner, and the artwork lives
        # there - the clowns stand on the bottom edge and reach most of the way
        # up, so all that survived was their shoes. Every theme lost most of its
        # banner the same way.
        #
        # The captions are not spread over the banner though: the title and
        # subtitle are anchored left, the mode and administrator warnings right,
        # and the MIDDLE CARRIES NOTHING. So the scrim covers the two ends and
        # leaves the middle clear, which is where the picture now goes.
        if ($Layer -eq "ground" -and $Surface -eq "header" -and $Script:HeaderScrim -gt 0) {
            $sc = [System.Drawing.Color]::FromArgb($Script:HeaderScrim, $Script:T.DarkBg)
            $clear = [System.Drawing.Color]::FromArgb(0, $Script:T.DarkBg)
            $hh = [Math]::Max(1, $Height)
            # left end: solid to 34%, faded out by 50%
            $lSolid = [Math]::Max(1, [int]($Width * 0.34))
            $lFade  = [Math]::Max(2, [int]($Width * 0.16))
            $sbL = New-Object System.Drawing.SolidBrush($sc)
            try { $g.FillRectangle($sbL, 0, 0, $lSolid, $hh) } finally { $sbL.Dispose() }
            $lr = New-Object System.Drawing.Rectangle($lSolid, 0, $lFade, $hh)
            $lb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($lr, $sc, $clear, 0)
            try { $g.FillRectangle($lb, $lr) } finally { $lb.Dispose() }
            # right end: faded in from 72%, solid from 82%
            $rStart = [Math]::Max(1, [int]($Width * 0.72))
            $rFade  = [Math]::Max(2, [int]($Width * 0.10))
            $rr = New-Object System.Drawing.Rectangle($rStart, 0, $rFade, $hh)
            $rb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rr, $clear, $sc, 0)
            try { $g.FillRectangle($rb, $rr) } finally { $rb.Dispose() }
            $sbR = New-Object System.Drawing.SolidBrush($sc)
            try { $g.FillRectangle($sbR, ($rStart + $rFade), 0, [Math]::Max(1, ($Width - $rStart - $rFade)), $hh) }
            finally { $sbR.Dispose() }
        }
        # The readability veil: a flat wash of the surface's own colour over the
        # finished art. Applied HERE and not on the master, because it depends on
        # the live theme's panel colour and costs one rectangle.
        if ($Layer -eq "ground" -and $Script:SurfaceVeil.ContainsKey($Surface)) {
            $v = $Script:SurfaceVeil[$Surface]
            if ($v -gt 0) {
                $vc = if ($Surface -eq "log") { $Script:T.OutputBg } else { $Script:T.GroupBg }
                $vb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($v, $vc))
                try { $g.FillRectangle($vb, 0, 0, $Width, $Height) } finally { $vb.Dispose() }
            }
        }
    } catch {
        Write-CrashLog "Overlay '$ThemeName/$Surface/$Layer' failed to render: $($_.Exception.Message)"
    } finally { $g.Dispose() }
    $Script:OverlayCache[$key] = $bmp
    $Script:OverlayLast[$lastKey] = $bmp
    return $bmp
}

# How big each master is drawn. Wide enough that scaling down is the normal
# case - upscaling a backdrop is forgiving, but there is no reason to do it -
# and shaped roughly like the surface it serves, so the cover-crop throws away
# as little of the picture as possible.
$Script:MasterSize = @{
    header = @(1200, 200)
    panel  = @(800, 560)
    zone   = @(1000, 720)
    log    = @(900, 560)
}

$Script:XamlRoot    = Join-Path $PSScriptRoot "xaml"
# Which artwork the themes use. On means the hand-authored XAML pictures; off
# falls every theme back to the GDI+ painters, which are kept for exactly that
# reason. Remembered per user, like the other backdrop switches.
$Script:UseXamlArt  = $true
# How often the drifting surfaces repaint, in animation ticks. The banner needs
# every tick - confetti falls at 5px each one. The backdrop is thirteen surfaces
# carrying forty-eight transparent captions between them, and repainting all of
# it every tick took the layout suite from 25 seconds to 171. This is the dial
# between "fluid" and "affordable", and there is a CLIFF between 1 and 2:
#   every tick  = 167 s   (repaints cannot finish inside the tick, work piles up)
#   every 2nd   =  19 s
#   every 3rd   =  19 s
# So 2 is free and 1 is not affordable at any framing - this is the fastest
# setting the tool can actually sustain, not a cautious one.
$Script:DriftEvery  = 2
# Pixels of travel per repaint. Raised with the interval, so the drift covers
# the same ground per second whatever the rate is set to.
$Script:DriftStep   = 2
$Script:XamlLoaded  = $false
$Script:XamlBroken  = @{}

function Get-XamlMaster {
    <#
        Artwork authored in XAML instead of in GDI+ calls, rendered once to a
        bitmap at master size.

        This is the one WPF route that fits this tool. Hosting live WPF would
        mean an ElementHost, and an ElementHost is its own window - it can sit
        on top of the WinForms controls but never behind them, which is the one
        thing a backdrop has to do. Rendering offscreen has no such problem: the
        result is a bitmap, and bitmaps are already what the whole overlay
        pipeline moves around.

        Costs nothing unless a file exists. The WPF assemblies are only loaded
        the first time one is found, so a tool with no xaml folder never pays
        for the feature.
    #>
    param([string]$ThemeName, [string]$Surface, [int]$W, [int]$H)
    if (-not $Script:UseXamlArt) { return $null }
    $key  = "$ThemeName|$Surface"
    if ($Script:XamlBroken.ContainsKey($key)) { return $null }
    # ONE FILE PER THEME, not one per surface.
    #
    # The surfaces differ only in how loud the artwork is allowed to be, and
    # that is a single number - so a per-surface file would be the same picture
    # eight times with the opacities changed, which is eight times the work and
    # eight places to forget. A <theme>.<surface>.xaml is still honoured first
    # if a surface ever needs its own composition.
    $slug = ($ThemeName -replace ' ', '-').ToLower()
    $file = Join-Path $Script:XamlRoot "$slug.$Surface.xaml"
    $quiet = 1.0
    if (-not (Test-Path $file)) {
        $file = Join-Path $Script:XamlRoot "$slug.xaml"
        if (-not (Test-Path $file)) { return $null }
        # The generic file is authored at full strength, so the surface's own
        # level is applied here - the same number the painters pass through
        # Get-OverlayAlpha.
        if ($Script:SurfaceQuiet.ContainsKey($Surface)) { $quiet = $Script:SurfaceQuiet[$Surface] }
    }
    try {
        if (-not $Script:XamlLoaded) {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
            $Script:XamlLoaded = $true
        }
        $xml = [System.Xml.XmlReader]::Create($file)
        try { $el = [System.Windows.Markup.XamlReader]::Load($xml) } finally { $xml.Dispose() }
        if ($quiet -lt 1.0) { $el.Opacity = $quiet }
        # RENDERED AT THE SIZE ASKED FOR, as vectors - not drawn small and blown
        # up afterwards.
        #
        # The artwork is authored on a fixed 1200x200 canvas, and a Canvas does
        # not stretch, so asking for a window-sized picture used to mean scaling
        # a 1200x200 bitmap up six times over. That is a blurry mess, and it
        # throws away the one thing this format is for. A Viewbox scales the
        # geometry instead, so every gradient and edge is resolved at the final
        # size however large that is.
        #
        # UniformToFill rather than Fill: the art has a shape and stretching it
        # to a window's proportions distorts everything in it. Filling and
        # cropping keeps circles round.
        # Uniform, not UniformToFill. The caller asks for a size that already has
        # the artwork's proportions, so there is nothing to crop; asking to fill
        # a differently-shaped box is what produced a 7.7x magnified fragment.
        $root = New-Object System.Windows.Controls.Viewbox
        $root.Stretch = [System.Windows.Media.Stretch]::Uniform
        $root.Child = $el
        $root.Measure((New-Object System.Windows.Size($W, $H)))
        $root.Arrange((New-Object System.Windows.Rect(0, 0, $W, $H)))
        $root.UpdateLayout()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
                    $W, $H, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $ms = New-Object System.IO.MemoryStream
        try {
            $enc.Save($ms)
            $ms.Position = 0
            # Copied out of the stream: a Bitmap built ON a stream keeps it alive
            # and faults later if it is disposed.
            $tmp = New-Object System.Drawing.Bitmap($ms)
            try {
                $out = New-Object System.Drawing.Bitmap($tmp.Width, $tmp.Height)
                $gg = [System.Drawing.Graphics]::FromImage($out)
                try { $gg.DrawImageUnscaled($tmp, 0, 0) } finally { $gg.Dispose() }
                return $out
            } finally { $tmp.Dispose() }
        } finally { $ms.Dispose() }
    } catch {
        # Once only - a broken file should not be retried on every render.
        $Script:XamlBroken[$key] = $true
        Write-CrashLog "XAML master '$key' failed, using the painter instead: $($_.Exception.Message)"
        return $null
    }
}

$Script:IconCache = @{}

function Get-XamlIcon {
    <#
        One operation glyph from xaml\icons.xaml, rendered at the size asked for.

        The sheet is five 24x24 cells side by side; this renders the whole thing
        at five times the icon size and crops the cell, which is one parse and
        one render for the set rather than five of each. Cached by size, because
        the Run button asks for the same glyph every time the operation changes.

        Returns $null when the artwork is switched off or the file is missing, and
        the caller simply keeps the text arrow it has always had.
    #>
    param([string]$Name, [int]$Size = 20)
    if (-not $Script:UseXamlArt) { return $null }
    if (-not $Name) { return $null }
    $key = "icon|$Name|$Size"
    if ($Script:IconCache.ContainsKey($key)) { return $Script:IconCache[$key] }
    # ONE FILE PER GLYPH, rendered straight at the size wanted.
    #
    # A five-cell sprite sheet was tried first and cropped wrong however exact
    # the arithmetic looked - the layout measured 120x24 into 135x27, cells on
    # clean 27px multiples, and the glyphs still came out shifted and clipped.
    # Rendering each file on its own removes the cropping step altogether, which
    # is the step that could be wrong. Five small parses instead of one, once
    # per size, and then they are cached.
    $file = Join-Path $Script:XamlRoot "icon.$Name.xaml"
    if (-not (Test-Path $file)) { return $null }
    $sheet = $null
    if ($true) {
        try {
            if (-not $Script:XamlLoaded) {
                Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
                $Script:XamlLoaded = $true
            }
            $xr = [System.Xml.XmlReader]::Create($file)
            try { $el = [System.Windows.Markup.XamlReader]::Load($xr) } finally { $xr.Dispose() }
            $vb = New-Object System.Windows.Controls.Viewbox
            $vb.Stretch = [System.Windows.Media.Stretch]::Uniform
            $vb.Child = $el
            $sw = $Size; $sh = $Size
            $vb.Measure((New-Object System.Windows.Size($sw, $sh)))
            $vb.Arrange((New-Object System.Windows.Rect(0, 0, $sw, $sh)))
            $vb.UpdateLayout()
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
                        $sw, $sh, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($vb)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $ms = New-Object System.IO.MemoryStream
            try {
                $enc.Save($ms); $ms.Position = 0
                $tmp = New-Object System.Drawing.Bitmap($ms)
                try {
                    $sheet = New-Object System.Drawing.Bitmap($tmp.Width, $tmp.Height)
                    $gg = [System.Drawing.Graphics]::FromImage($sheet)
                    try { $gg.DrawImageUnscaled($tmp, 0, 0) } finally { $gg.Dispose() }
                } finally { $tmp.Dispose() }
            } finally { $ms.Dispose() }
        } catch {
            Write-CrashLog "Icon '$Name' failed, using the text arrow: $($_.Exception.Message)"
            return $null
        }
    }
    if (-not $sheet) { return $null }
    $Script:IconCache[$key] = $sheet
    return $sheet
}

function Get-WindowBackdrop {
    <#
        ONE picture, the size of the window, that every surface draws its own
        part of.

        Without this each panel scales the master into its own bounds, so the
        window shows a dozen independent copies of the artwork - each correct,
        but together a patchwork. Rendering it once at window size and having
        every surface blit the region that falls under it makes the backdrop
        continuous, the way it looks behind the banner.

        No veil is applied here: the surfaces have different readability needs
        and each one washes its own region after blitting, so this stays a
        single shared picture rather than one per quiet level.
    #>
    param([int]$Width, [int]$Height, [string]$ThemeName)
    if ($Width -lt 8 -or $Height -lt 8) { return $null }
    # Quantised hard - this is the biggest bitmap the tool holds, and a resize
    # must not mint a new one every 64px.
    # DELIBERATE OVERSIZE, not just whatever the grid rounds up to.
    #
    # The backdrop drifts by being drawn at an offset, so how far it can travel
    # is the difference between its size and the window's. Left to the grid that
    # was anything from 1 to 255 pixels, and on a theme whose artwork is smooth -
    # Neo Dark is auroras and gradients, with no hard feature to track - a short
    # travel is invisible. It reads as "that theme has no animation". A fixed
    # margin gives every theme the same distance to move through.
    $grid = 256
    $margin = 320
    $w2 = [int]([Math]::Ceiling(($Width + $margin) / $grid) * $grid)
    $h2 = [int]([Math]::Ceiling(($Height + $margin) / $grid) * $grid)
    $key = "window|$ThemeName|$w2|$h2"
    if ($Script:OverlayCache.ContainsKey($key)) { return $Script:OverlayCache[$key] }
    if ($Script:Dragging) {
        if ($Script:OverlayLast.ContainsKey("window|$ThemeName")) { return $Script:OverlayLast["window|$ThemeName"] }
        return $null
    }
    foreach ($k in @($Script:OverlayCache.Keys)) {
        if ($k -notlike "window|$ThemeName|*") { continue }
        try { $Script:OverlayCache[$k].Dispose() } catch { }
        $Script:OverlayCache.Remove($k)
    }
    # A BANNER ACROSS THE TOP, not the banner stretched over the window.
    #
    # The artwork is composed 6:1 and a window is about 1.2:1. Filling the window
    # with it means scaling nearly eight times and cropping to a fragment - the
    # clowns come out enormous, cut off at the bottom, and unrecognisable. Fitting
    # it instead distorts nothing: it is drawn at the window's WIDTH, keeping its
    # own proportions, and the rest of the window is the theme's ground beneath
    # it. That is also what was actually asked for - the header's picture carried
    # across the whole window rather than a separate composition.
    $bandH = [int]($w2 * 200.0 / 1200.0)
    if ($bandH -gt $h2) { $bandH = $h2 }
    $band = Get-XamlMaster -ThemeName $ThemeName -Surface "window" -W $w2 -H $bandH
    if ($band) {
        $bmp = New-Object System.Drawing.Bitmap($w2, $h2)
        $g2 = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g2.Clear($Script:T.DarkBg)
            $g2.DrawImageUnscaled($band, 0, 0)
            # Fade the band's bottom edge into the ground so it does not end on a
            # hard line halfway down the window.
            $fade = [Math]::Min(160, [Math]::Max(24, [int]($bandH * 0.35)))
            $fr = New-Object System.Drawing.Rectangle(0, ($bandH - $fade), $w2, $fade)
            $fb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $fr, [System.Drawing.Color]::FromArgb(0, $Script:T.DarkBg),
                    [System.Drawing.Color]::FromArgb(255, $Script:T.DarkBg), 90)
            try { $g2.FillRectangle($fb, $fr) } finally { $fb.Dispose() }
        } finally { $g2.Dispose() }
        $Script:OverlayCache[$key] = $bmp
        $Script:OverlayLast["window|$ThemeName"] = $bmp
        return $bmp
    }
    $bmp = $null
    if (-not $bmp) {
        # No XAML for this theme: fall back to magnifying the painter's master,
        # which is the best available and is what the painters have always done.
        $master = Get-OverlayMaster -Surface "header" -Layer "ground" -ThemeName $ThemeName
        if (-not $master) { return $null }
        $bmp = New-Object System.Drawing.Bitmap($w2, $h2)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear($Script:T.DarkBg)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
            $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
            $g.DrawImage($master, (New-Object System.Drawing.Rectangle(0, 0, $w2, $h2)),
                         (New-Object System.Drawing.Rectangle(0, 0, $master.Width, $master.Height)),
                         [System.Drawing.GraphicsUnit]::Pixel)
        } catch {
            Write-CrashLog "Window backdrop '$ThemeName' failed: $($_.Exception.Message)"
        } finally { $g.Dispose() }
    }
    $Script:OverlayCache[$key] = $bmp
    $Script:OverlayLast["window|$ThemeName"] = $bmp
    return $bmp
}

function Get-OverlayMaster {
    <#
        The one real render per (theme, surface, layer). Everything the window
        actually draws is a scaled copy of one of these.

        Kept in its own cache so that clearing the per-size bitmaps - which
        happens on every resize - does not throw away the expensive part.
    #>
    param([string]$Surface, [string]$Layer, [string]$ThemeName)
    $mk = "$ThemeName|$Surface|$Layer"
    if ($Script:OverlayMasters.ContainsKey($mk)) { return $Script:OverlayMasters[$mk] }
    $dims = if ($Script:MasterSize.ContainsKey($Surface)) { $Script:MasterSize[$Surface] } else { @(1200, 800) }
    $mw = $dims[0]; $mh = $dims[1]
    # A hand-authored XAML picture wins over the painter when one exists. The
    # ground layer only: the motion layers are scrolled, so they have to tile,
    # and that is a different job from drawing a picture.
    if ($Layer -eq "ground") {
        $x = Get-XamlMaster -ThemeName $ThemeName -Surface $Surface -W $mw -H $mh
        if ($x) { $Script:OverlayMasters[$mk] = $x; return $x }
    }
    $bmp = New-Object System.Drawing.Bitmap($mw, $mh)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        # The motion layer must stay transparent where nothing is drawn, or it
        # would paint over the ground it is supposed to drift across.
        if ($Layer -eq "ground") { $g.Clear($Script:T.DarkBg) }
        else                     { $g.Clear([System.Drawing.Color]::Transparent) }
        $painter = if ($Script:OverlayPainters.ContainsKey($ThemeName)) { $Script:OverlayPainters[$ThemeName] }
                   else { $Script:OverlayPainters["*"] }
        & $painter $g $mw $mh $Surface $Layer
    } catch {
        Write-CrashLog "Overlay master '$ThemeName/$Surface/$Layer' failed: $($_.Exception.Message)"
    } finally { $g.Dispose() }
    $Script:OverlayMasters[$mk] = $bmp
    return $bmp
}

# --- the painters -----------------------------------------------------------
# Each takes ($g, $w, $h, $surface). $surface is "header" or "zone": the header
# is a wide short banner and carries the strongest treatment, the zones are seen
# only through gaps and stay quiet.
$Script:OverlayPainters = @{}

# ---------------------------------------------------------------------------
#  How loud a surface is allowed to be
# ---------------------------------------------------------------------------
# The banner can carry the full artwork - nothing sits on it but a title and a
# subtitle, both large. The panels are different: every label, field and check
# box in the tool sits directly on one, and artwork behind small text is the
# fastest way to make a window that cannot be read. So a panel gets the same
# picture at roughly a third of the strength, and the zones (seen through 8px
# gaps) sit in between.
#
# These were pitched far too low on the first pass - "the graphics need to pop
# out more, they are almost hidden". Readability is now protected by the VEIL
# below rather than by drawing the art so faintly it disappears, which is a
# better trade: the picture keeps its shape and contrast, and a flat wash of the
# panel colour on top is what pulls the text back off it.
#
# These are SEARCHED, not guessed - see the contrast table in tests\overlay.ps1.
# The banner keeps the artwork at full strength because its text is protected by
# a halo (Add-TextHalo) rather than by dimming the picture; the panels and the
# log have to earn their legibility the ordinary way, so they are the values
# that measured out as the boldest still clearing WCAG for small text.
$Script:SurfaceQuiet = @{ header = 1.0; zone = 0.85; panel = 0.42; log = 0.26 }

# How much of the panel's own colour is washed back over the finished art. The
# header gets none - nothing sits on it but a title. The log gets the most,
# because it is a wall of small mono text and it is how anyone knows what the
# migration actually did.
# The banner's number is a UNIFORM wash over the whole surface, which is the
# difference that matters here: it dims the picture evenly and has no edge, so
# there is nothing that reads as a box. The plate it replaced covered only the
# caption bands, and an edge is exactly what made it look like one.
$Script:SurfaceVeil = @{ header = 145; zone = 26; panel = 140; log = 202 }

# How dark the banner's caption bands are plated. ZERO, by explicit choice: the
# plate is what "the weird box around the text in the header" always was - a
# solid slab behind the captions with the picture carrying on either side of it.
# Nothing was wrong with the rendering; the box was drawn on purpose.
#
# The trade is stated plainly because it is a real one. With no plate the title
# sits straight on the artwork and the contrast is whatever the picture happens
# to be under it, which for Clown Fiesta's white gloves is poor. That is the
# call the tool's owner made - a banner is decoration and its title is large -
# and tests\overlay.ps1 still prints the measurement on every run so a
# regression elsewhere is not mistaken for this decision.
$Script:HeaderScrim = 0

function Add-TextHalo {
    <#
        A dark (or light) glow drawn tightly around a caption, before the caption
        itself is drawn on top of it.

        This is the ONLY thing that makes bold artwork and readable text possible
        at the same time on the banner. The numbers are not close: with Clown
        Fiesta's white gloves under light title text, the worst contrast on the
        banner is 1.01:1, and dimming cannot fix it - the veil needed to pull a
        white pixel down to a legible level is 193 of 255, which erases the
        picture entirely. A halo sidesteps the whole problem by making the text's
        immediate surround a known colour, and it is what the source files do:
        "text-shadow: 0 0 34px var(--glow)".

        Drawn from the PARENT's paint handler, because a Label raises its Paint
        event after it has already drawn its text - so a halo added there would
        land on top of the words instead of behind them. Children paint after
        their parent, which puts this in exactly the right order.
    #>
    param($g, [string]$Text, $Font, [single]$X, [single]$Y, $HaloColor, [int]$Alpha = 190, [int]$Radius = 2)
    if ([string]::IsNullOrEmpty($Text) -or -not $Font) { return }
    try {
        # GRADUATED, not a solid stamp at every offset.
        #
        # The centre pass is what actually backs the letter: without it a 3px
        # bold stem shifted by 2px only partly overlaps itself, the middle of
        # the stroke shows the artwork through and the contrast sits around 2:1.
        # But the centre pass is INVISIBLE - the glyph is drawn straight over it -
        # so it can be as strong as it likes.
        #
        # What you actually see is the part that spills past the glyph, and
        # stamping that at full strength too is what made it "a harsh outline"
        # and put a black shadow behind the small dim captions. So the ring
        # falls off: solid behind the letter, 45% one pixel out, 20% two pixels
        # out. That reads as a soft shadow rather than an ink outline.
        # The visible part is deliberately FAINT - 18% of one pixel, and nothing
        # beyond that. At 45% over two pixels it read as an ink outline on the
        # title and as a black shadow sitting behind the small dim captions on
        # the right of the banner, which is what kept getting reported. All the
        # legibility comes from the centre pass, which cannot be seen, so the
        # ring only has to soften the glyph's antialiased edge.
        $rings = @(
            @{ R = 0; A = $Alpha }
            @{ R = 1; A = [int]($Alpha * 0.18) }
        )
        foreach ($ring in $rings) {
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($ring.A, $HaloColor))
            try {
                if ($ring.R -eq 0) {
                    $g.DrawString($Text, $Font, $br, $X, $Y)
                    continue
                }
                $r = $ring.R
                foreach ($d in @(@(-$r, 0), @($r, 0), @(0, -$r), @(0, $r),
                                 @(-$r, -$r), @($r, -$r), @(-$r, $r), @($r, $r))) {
                    $g.DrawString($Text, $Font, $br, ($X + $d[0]), ($Y + $d[1]))
                }
            } finally { $br.Dispose() }
        }
    } catch { }
}

function Get-HaloColor {
    <#
        Whichever of near-black and near-white the caption contrasts with MOST.

        "Light text gets a dark halo, dark text gets a light one" is the obvious
        rule and it is wrong for the accent colours these titles are actually
        drawn in. A medium blue like #3b82f6 counts as dark, so that rule handed
        it a near-white halo - and blue on white is 3.8:1, which is what the
        contrast test kept catching. Measured both ways it prefers black at
        5.2:1. Mid-luminance colours have no "opposite"; they have a better and
        a worse, so pick by measurement.
    #>
    param($TextColor)
    $lin = {
        param($c)
        $v = @($c.R, $c.G, $c.B) | ForEach-Object {
            $s = $_ / 255.0
            if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow((($s + 0.055) / 1.055), 2.4) }
        }
        (0.2126 * $v[0]) + (0.7152 * $v[1]) + (0.0722 * $v[2])
    }
    $dark  = [System.Drawing.Color]::FromArgb(8, 6, 14)
    $light = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $lt = & $lin $TextColor
    $ratio = {
        param($la, $lb)
        (([Math]::Max($la, $lb)) + 0.05) / (([Math]::Min($la, $lb)) + 0.05)
    }
    if ((& $ratio $lt (& $lin $dark)) -ge (& $ratio $lt (& $lin $light))) { return $dark }
    return $light
}

function Get-OverlayAlpha {
    param([int]$Base, [string]$Surface)
    $q = if ($Script:SurfaceQuiet.ContainsKey($Surface)) { $Script:SurfaceQuiet[$Surface] } else { 0.5 }
    $a = [int]($Base * $q)
    if ($a -lt 0) { return 0 }
    if ($a -gt 255) { return 255 }
    return $a
}

# --- shared drawing helpers -------------------------------------------------
# Every painter is built from these, so they all behave the same way about
# strength, determinism and shape count.

function New-RoundRectPath {
    # SVG's rx on a <rect>, and the --radius token on the glass panes.
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0 -or $W -le 0 -or $H -le 0) {
        $p.AddRectangle((New-Object System.Drawing.RectangleF($X, $Y, [Math]::Max(1, $W), [Math]::Max(1, $H))))
        return $p
    }
    $d = [single]([Math]::Min($R, [Math]::Min($W, $H) / 2) * 2)
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Add-QuadTo {
    # SVG's "Q" - a quadratic curve. GDI+ only has cubics, so lift the control
    # point: C1 = P0 + 2/3(Q-P0), C2 = P1 + 2/3(Q-P1). The clown's smile,
    # eyebrows and arms are all quadratics in the source file.
    param($Path, [single]$X0, [single]$Y0, [single]$Qx, [single]$Qy, [single]$X1, [single]$Y1)
    $c1x = $X0 + (2.0 / 3.0) * ($Qx - $X0); $c1y = $Y0 + (2.0 / 3.0) * ($Qy - $Y0)
    $c2x = $X1 + (2.0 / 3.0) * ($Qx - $X1); $c2y = $Y1 + (2.0 / 3.0) * ($Qy - $Y1)
    $Path.AddBezier($X0, $Y0, $c1x, $c1y, $c2x, $c2y, $X1, $Y1)
}

function Add-OverlayGradient {
    # The ground fill: a linear wash between two colours.
    param($g, [int]$w, [int]$h, $From, $To, [single]$Angle = 135)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $From, $To, $Angle)
    try { $g.FillRectangle($br, $rect) } finally { $br.Dispose() }
}

function Add-OverlayGlow {
    # A soft radial blob - what every one of the source files builds its
    # background out of ("radial-gradient(... at 18% 12% ...)"), and what the
    # Neo files blur to 90px and call an aurora.
    param($g, [int]$w, [int]$h, [double]$Cx, [double]$Cy, [double]$Radius, $Color, [int]$Alpha)
    if ($Alpha -le 0) { return }
    $r = [single]($Radius * [Math]::Max($w, $h))
    if ($r -lt 1) { return }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse([single]($w * $Cx - $r), [single]($h * $Cy - $r), [single]($r * 2), [single]($r * 2))
    $pb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $pb.CenterColor = [System.Drawing.Color]::FromArgb($Alpha, $Color)
    $pb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $Color))
    try { $g.FillRectangle($pb, 0, 0, $w, $h) } finally { $pb.Dispose(); $path.Dispose() }
}

function Add-OverlayScatter {
    <#
        Small shapes spread over the surface - confetti, bubbles, motes.

        Deterministic: a fixed seed means they land in the same place on every
        render, so resizing does not reshuffle the background, which would be
        far more distracting than the pattern itself. Also capped, so a
        maximised window does not quietly cost more to draw than a small one.
    #>
    param(
        $g, [int]$w, [int]$h, [string[]]$Hexes, [string]$Surface,
        [int]$Seed = 42, [double]$Density = 9000, [int]$Cap = 140,
        [int]$MinSize = 3, [int]$MaxSize = 9, [int]$BaseAlpha = 45,
        [switch]$Rects
    )
    $rand = New-Object System.Random($Seed)
    $n = [int](($w * $h) / $Density)
    if ($n -gt $Cap) { $n = $Cap }
    for ($i = 0; $i -lt $n; $i++) {
        $col = ConvertFrom-Hex $Hexes[$rand.Next(0, $Hexes.Count)]
        $a = Get-OverlayAlpha ($rand.Next([int]($BaseAlpha * 0.5), $BaseAlpha)) $Surface
        if ($a -le 2) { continue }
        $sz = $rand.Next($MinSize, $MaxSize)
        $x = $rand.Next(0, [Math]::Max(1, $w)); $y = $rand.Next(0, [Math]::Max(1, $h))
        $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, $col))
        try {
            if ($Rects -and $rand.Next(0, 2) -eq 0) {
                $st = $g.Save()
                $g.TranslateTransform([single]$x, [single]$y)
                $g.RotateTransform([single]$rand.Next(0, 90))
                $g.FillRectangle($br, 0, 0, $sz, [int]($sz * 1.7))
                $g.Restore($st)
            } else {
                $g.FillEllipse($br, $x, $y, $sz, $sz)
            }
        } finally { $br.Dispose() }
    }
}

function Add-OverlayBubbles {
    # Rising bubbles - the 'rise' keyframe shared by freshwater and wastewater.
    # Outlined rather than filled, so they read as bubbles and not as dots.
    param($g, [int]$w, [int]$h, $Color, [string]$Surface, [int]$Seed = 7, [int]$Count = 18, [int]$Alpha = 54)
    $rand = New-Object System.Random($Seed)
    for ($i = 0; $i -lt $Count; $i++) {
        $sz = $rand.Next(4, 20)
        $a = Get-OverlayAlpha ($rand.Next([int]($Alpha * 0.4), $Alpha)) $Surface
        if ($a -le 2) { continue }
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($a, $Color), 1.4)
        try { $g.DrawEllipse($pen, $rand.Next(0, [Math]::Max(1, $w)), $rand.Next(0, [Math]::Max(1, $h)), $sz, $sz) }
        finally { $pen.Dispose() }
    }
}

function Add-OverlayPolka {
    # ".polka { background-image: radial-gradient(circle, rgba(255,255,255,0.04)
    #  2px, transparent 2px); background-size: 40px 40px; }" - a dot grid under
    # everything else. Cheap and it is what stops the ground reading as flat.
    param($g, [int]$w, [int]$h, $Color, [string]$Surface, [int]$Alpha = 26, [int]$Step = 40)
    $a = Get-OverlayAlpha $Alpha $Surface
    if ($a -le 2) { return }
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, $Color))
    try {
        for ($y = [int]($Step / 2); $y -lt $h; $y += $Step) {
            for ($x = [int]($Step / 2); $x -lt $w; $x += $Step) { $g.FillEllipse($br, $x, $y, 4, 4) }
        }
    } finally { $br.Dispose() }
}

function Add-OverlayRays {
    # The <polygon> light shafts in the source design files: white wedges fading down the
    # surface, screen-blended. Drawn as gradient-filled parallelograms.
    param($g, [int]$w, [int]$h, $Color, [string]$Surface, [int]$Alpha = 46, [int]$Seed = 3)
    $rand = New-Object System.Random($Seed)
    foreach ($spec in @(@(0.10, 0.13), @(0.28, 0.07), @(0.44, 0.04))) {
        $a = Get-OverlayAlpha ([int]($Alpha * (0.6 + $rand.NextDouble() * 0.5))) $Surface
        if ($a -le 2) { continue }
        $x0 = [single]($w * $spec[0]); $wd = [single]($w * $spec[1])
        $pts = @(
            (New-Object System.Drawing.PointF($x0, [single](-2))),
            (New-Object System.Drawing.PointF(($x0 + $wd), [single](-2))),
            (New-Object System.Drawing.PointF(($x0 + $wd + $w * 0.42), [single]($h + 2))),
            (New-Object System.Drawing.PointF(($x0 + $w * 0.42), [single]($h + 2)))
        )
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddPolygon($pts)
        $rect = New-Object System.Drawing.Rectangle(0, -2, [Math]::Max(1, $w), [Math]::Max(2, $h + 4))
        $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $rect, [System.Drawing.Color]::FromArgb($a, $Color),
                [System.Drawing.Color]::FromArgb(0, $Color), 90)
        try { $g.FillPath($br, $path) } finally { $br.Dispose(); $path.Dispose() }
    }
}

function Add-OverlayGlassPane {
    <#
        The Aero pane from the source design files - and the thing that made those
        backgrounds look like anything at all, which the first port left out
        entirely.

        Four parts, all of them in the source CSS: a pale diagonal fill, a 1px
        light border, a gloss over the top 48%, and (on the motion layer) the
        specular streak that sweeps across it.
    #>
    param($g, [single]$X, [single]$Y, [single]$W, [single]$H, [single]$Rot,
          [string]$Surface, [int]$Alpha = 40, [single]$Radius = 18)
    if ($W -lt 6 -or $H -lt 6) { return }
    $st = $g.Save()
    try {
        $g.TranslateTransform(($X + $W / 2), ($Y + $H / 2))
        $g.RotateTransform($Rot)
        $g.TranslateTransform(-($W / 2), -($H / 2))
        $path = New-RoundRectPath 0 0 $W $H $Radius
        try {
            $aFill = Get-OverlayAlpha $Alpha $Surface
            if ($aFill -gt 2) {
                $rect = New-Object System.Drawing.Rectangle(0, 0, [int]$W, [int]$H)
                $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                        $rect, [System.Drawing.Color]::FromArgb($aFill, 255, 255, 255),
                        [System.Drawing.Color]::FromArgb([int]($aFill * 0.15), 255, 255, 255), 150)
                try { $g.FillPath($br, $path) } finally { $br.Dispose() }
                # the glossy top half - the Vista/Aero tell
                $gloss = New-RoundRectPath 0 0 $W ($H * 0.48) $Radius
                $gr = New-Object System.Drawing.Rectangle(0, 0, [int]$W, [Math]::Max(1, [int]($H * 0.48)))
                $gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                        $gr, [System.Drawing.Color]::FromArgb([int]($aFill * 1.4), 255, 255, 255),
                        [System.Drawing.Color]::FromArgb(0, 255, 255, 255), 90)
                try { $g.FillPath($gb, $gloss) } finally { $gb.Dispose(); $gloss.Dispose() }
            }
            $aLine = Get-OverlayAlpha ([int]($Alpha * 1.6)) $Surface
            if ($aLine -gt 2) {
                $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($aLine, 255, 255, 255), 1.2)
                try { $g.DrawPath($pen, $path) } finally { $pen.Dispose() }
            }
        } finally { $path.Dispose() }
    } finally { $g.Restore($st) }
}

function Add-OverlayClown {
    <#
        A clown, ported shape for shape from the <svg class="clown-svg"> in
        clown-fiesta-bg_2.html - shoes, polka suit, ruffled collar, hair, top
        hat with a flower, eyes, nose, smile, arms and the balloon on a string.

        It was the missing piece: the first port drew confetti and bunting and
        called it Clown Fiesta, which is a fiesta with no clowns in it.

        Coordinates are the source viewBox (200x320) and the transform does the
        rest, so this reads against the original file rather than against a set
        of numbers somebody scaled by hand.
    #>
    param($g, [single]$Cx, [single]$BaseY, [single]$Scale, [string]$Surface,
          [int]$Alpha = 210, [int]$Variant = 0)
    if ($Scale -le 0.02) { return }
    $sets = @(
        @{ shoeL = "#e63946"; shoeR = "#2ec4b6"; suit = "#9b59b6"; dot = "#f5c842"
           ruf = "#ff6eb4";  hair = "#f5a623"; hat = "#1a0a2e"; band = "#f5c842"; bal = "#e63946" },
        @{ shoeL = "#f5c842"; shoeR = "#ff6eb4"; suit = "#2ec4b6"; dot = "#e63946"
           ruf = "#9b59b6";  hair = "#e63946"; hat = "#2d1060"; band = "#2ec4b6"; bal = "#f5c842" },
        @{ shoeL = "#2ec4b6"; shoeR = "#9b59b6"; suit = "#e63946"; dot = "#fff8e7"
           ruf = "#f5c842";  hair = "#ff6eb4"; hat = "#1a0a2e"; band = "#ff6eb4"; bal = "#2ec4b6" }
    )
    $c = $sets[$Variant % $sets.Count]
    $junk = New-Object System.Collections.ArrayList
    $B = {
        param([string]$hex, [double]$op = 1.0)
        $a = Get-OverlayAlpha ([int]($Alpha * $op)) $Surface
        if ($a -lt 0) { $a = 0 }
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, (ConvertFrom-Hex $hex)))
        [void]$junk.Add($b); return $b
    }
    $P = {
        param([string]$hex, [single]$wid, [double]$op = 1.0)
        $a = Get-OverlayAlpha ([int]($Alpha * $op)) $Surface
        if ($a -lt 0) { $a = 0 }
        $p = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($a, (ConvertFrom-Hex $hex)), $wid)
        $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $p.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        [void]$junk.Add($p); return $p
    }
    # <ellipse cx cy rx ry> and <circle cx cy r> in the source's own terms
    $E = { param($br, [single]$cx, [single]$cy, [single]$rx, [single]$ry)
           $g.FillEllipse($br, ($cx - $rx), ($cy - $ry), ($rx * 2), ($ry * 2)) }
    $O = { param($br, [single]$cx, [single]$cy, [single]$r)
           $g.FillEllipse($br, ($cx - $r), ($cy - $r), ($r * 2), ($r * 2)) }
    $R = { param($br, [single]$x, [single]$y, [single]$ww, [single]$hh, [single]$rad)
           $p = New-RoundRectPath $x $y $ww $hh $rad; try { $g.FillPath($br, $p) } finally { $p.Dispose() } }

    $st = $g.Save()
    try {
        $g.TranslateTransform($Cx, $BaseY)
        $g.ScaleTransform($Scale, $Scale)
        $g.TranslateTransform(-100.0, -320.0)      # viewBox bottom-centre to the anchor

        & $E (& $B $c.shoeL)  65 298 52 18                 # big shoes
        & $E (& $B $c.shoeR) 135 298 52 18
        & $R (& $B "#fff8e7")  72 240 22 60 10             # legs
        & $R (& $B "#fff8e7") 106 240 22 60 10
        & $E (& $B $c.suit)  100 210 52 60                 # polka dot suit
        foreach ($d in @(@(85, 185, 8), @(115, 185, 8), @(100, 210, 8), @(78, 230, 7), @(122, 230, 7))) {
            & $O (& $B $c.dot) $d[0] $d[1] $d[2]
        }
        & $E (& $B $c.ruf)   100 158 48 20                 # collar ruffles
        & $E (& $B $c.shoeL)  75 152 22 14
        & $E (& $B $c.shoeR) 125 152 22 14
        & $E (& $B $c.dot)   100 148 20 12
        & $R (& $B "#ffe0c0")  88 138 24 20 8              # neck
        & $E (& $B "#ffe0c0") 100 108 55 60                # head
        foreach ($hpt in @(@(30, 85, 28), @(20, 70, 20), @(38, 62, 18),
                           @(170, 85, 28), @(180, 70, 20), @(162, 62, 18))) {
            & $O (& $B $c.hair) $hpt[0] $hpt[1] $hpt[2]    # curly hair, both sides
        }
        & $R (& $B $c.hat)     62 32 76 55 6               # top hat
        & $R (& $B $c.band)    50 82 100 14 4
        & $R (& $B $c.dot)     68 36 64 6 2
        & $O (& $B $c.ruf)    120 50 10                    # hat flower
        & $O (& $B $c.shoeL)  110 45 8
        & $O (& $B $c.shoeR)  130 45 8
        & $O (& $B $c.dot)    120 38 7
        & $O (& $B "#ffffff") 120 50 5
        & $E (& $B "#ffffff")  80 110 14 16                # eyes
        & $E (& $B "#ffffff") 120 110 14 16
        & $O (& $B "#2d1060")  82 113 8
        & $O (& $B "#2d1060") 122 113 8
        & $O (& $B "#ffffff")  85 110 3
        & $O (& $B "#ffffff") 125 110 3
        foreach ($brow in @(@(68, 97, 80, 88, 92, 97), @(108, 97, 120, 88, 132, 97))) {
            $bp = New-Object System.Drawing.Drawing2D.GraphicsPath
            try {
                Add-QuadTo $bp $brow[0] $brow[1] $brow[2] $brow[3] $brow[4] $brow[5]
                $g.DrawPath((& $P "#8B4513" 4), $bp)
            } finally { $bp.Dispose() }
        }
        & $E (& $B "#e63946") 100 128 16 13                # BIG RED NOSE
        & $E (& $B "#ff6b6b" 0.6) 95 124 5 4
        $sm = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {                                              # big smile
            Add-QuadTo $sm 70 145 100 172 130 145
            $g.FillPath((& $B "#ffe0c0"), $sm)
            $g.DrawPath((& $P "#c0392b" 4), $sm)
        } finally { $sm.Dispose() }
        & $E (& $B "#ff9999" 0.5)  68 135 14 10            # rosy cheeks
        & $E (& $B "#ff9999" 0.5) 132 135 14 10
        foreach ($arm in @(@(50, 175, 20, 155, 10, 130), @(150, 175, 180, 155, 190, 130))) {
            $ap = New-Object System.Drawing.Drawing2D.GraphicsPath
            try {
                Add-QuadTo $ap $arm[0] $arm[1] $arm[2] $arm[3] $arm[4] $arm[5]
                $g.DrawPath((& $P "#ffe0c0" 18), $ap)
            } finally { $ap.Dispose() }
        }
        & $O (& $B "#ffffff")  10 125 18                   # gloves
        & $O (& $B "#ffffff") 190 125 18
        & $O (& $B $c.ruf)      0 110 7                    # left hand: flower
        & $O (& $B $c.dot)     10 105 7
        & $O (& $B "#e63946")  20 108 7
        & $O (& $B "#2ec4b6")  10 115 5
        & $O (& $B "#ffffff")  10 108 5
        $g.DrawLine((& $P "#888888" 2), 190, 108, 195, 60) # right hand: balloon
        & $E (& $B $c.bal)    196 48 14 18
        & $E (& $B "#ff6b6b" 0.5) 191 42 5 6
    } finally {
        $g.Restore($st)
        foreach ($d in $junk) { try { $d.Dispose() } catch { } }
    }
}

function Add-OverlayBalloon {
    # <svg class="balloon"> - a teardrop with a highlight, a knot and a string.
    param($g, [single]$Cx, [single]$Cy, [single]$R, $Color, [string]$Surface, [int]$Alpha = 150)
    $a = Get-OverlayAlpha $Alpha $Surface
    if ($a -le 2 -or $R -lt 2) { return }
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, $Color))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int]($a * 0.5), 200, 200, 200), 1.2)
    $hi = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int]($a * 0.45), 255, 255, 255))
    try {
        $g.FillEllipse($br, ($Cx - $R), ($Cy - $R * 1.25), ($R * 2), ($R * 2.5))
        $g.FillEllipse($hi, ($Cx - $R * 0.5), ($Cy - $R * 0.85), ($R * 0.45), ($R * 0.6))
        $pts = @(
            (New-Object System.Drawing.PointF(($Cx - $R * 0.18), ($Cy + $R * 1.25))),
            (New-Object System.Drawing.PointF(($Cx + $R * 0.18), ($Cy + $R * 1.25))),
            (New-Object System.Drawing.PointF($Cx, ($Cy + $R * 1.55))))
        $g.FillPolygon($br, $pts)
        $g.DrawLine($pen, $Cx, ($Cy + $R * 1.55), ($Cx + $R * 0.35), ($Cy + $R * 3.2))
    } finally { $br.Dispose(); $pen.Dispose(); $hi.Dispose() }
}

function Add-OverlayBunting {
    # <svg class="banner-string"> - the swagged string of triangular flags
    # across the top of the fiesta.
    param($g, [int]$w, [int]$h, [string[]]$Hexes, [string]$Surface, [int]$Alpha = 170)
    $a = Get-OverlayAlpha $Alpha $Surface
    if ($a -le 2) { return }
    $dip = [single]([Math]::Min($h * 0.22, 26))
    $top = [single]($h * 0.06)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($a, 255, 255, 255), 1.6)
    $curve = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        Add-QuadTo $curve 0 $top ($w / 2) ($top + $dip * 2) $w $top
        $g.DrawPath($pen, $curve)
        $n = [Math]::Max(4, [int]($w / 46))
        $flag = [single]([Math]::Min(18, $h * 0.16))
        for ($i = 0; $i -le $n; $i++) {
            $t = $i / [double]$n
            $x = [single]($t * $w)
            # the same quadratic, evaluated - so the flags hang ON the string
            $y = [single]((1 - $t) * (1 - $t) * $top + 2 * (1 - $t) * $t * ($top + $dip * 2) + $t * $t * $top)
            $col = ConvertFrom-Hex $Hexes[$i % $Hexes.Count]
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, $col))
            try {
                $g.FillPolygon($br, @(
                    (New-Object System.Drawing.PointF(($x - $flag * 0.42), $y)),
                    (New-Object System.Drawing.PointF(($x + $flag * 0.42), $y)),
                    (New-Object System.Drawing.PointF($x, ($y + $flag)))))
            } finally { $br.Dispose() }
        }
    } finally { $pen.Dispose(); $curve.Dispose() }
}

function Add-OverlayStreaks {
    # The specular sweep (".pane::after") and the metro "crawl" - diagonal
    # highlights that live on a scrolling layer, so they cross the surface for
    # the price of a blit rather than a redraw.
    param($g, [int]$w, [int]$h, $Color, [string]$Surface, [int]$Alpha = 60,
          [int]$Count = 3, [single]$Tilt = 18)
    if ($Count -lt 1) { return }
    $step = [single]($w / $Count)
    for ($i = 0; $i -lt $Count; $i++) {
        $a = Get-OverlayAlpha $Alpha $Surface
        if ($a -le 2) { continue }
        $x = [single]($i * $step)
        $st = $g.Save()
        try {
            $g.TranslateTransform($x, ($h / 2))
            $g.RotateTransform($Tilt)
            $bw = [single]([Math]::Max(6, $w * 0.05))
            $rect = New-Object System.Drawing.Rectangle([int](-$bw / 2), [int](-$h), [int]$bw, [int]($h * 2))
            $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $rect, [System.Drawing.Color]::FromArgb(0, $Color),
                    [System.Drawing.Color]::FromArgb($a, $Color), 0)
            $br.WrapMode = [System.Drawing.Drawing2D.WrapMode]::TileFlipX
            try { $g.FillRectangle($br, $rect) } finally { $br.Dispose() }
        } finally { $g.Restore($st) }
    }
}

# ---------------------------------------------------------------------------
#  The default, for any theme without art of its own
# ---------------------------------------------------------------------------
$Script:OverlayPainters["*"] = {
    param($g, $w, $h, $surface, $layer)
    if ($layer -ne "ground") { return }
    $mix = if ($surface -eq "header") { 0.35 } else { 0.15 }
    $c1 = $Script:T.DarkBg
    $tint = [System.Drawing.Color]::FromArgb(
        [int]($c1.R + (($Script:T.Primary.R - $c1.R) * $mix)),
        [int]($c1.G + (($Script:T.Primary.G - $c1.G) * $mix)),
        [int]($c1.B + (($Script:T.Primary.B - $c1.B) * $mix)))
    Add-OverlayGradient $g $w $h $tint $Script:T.GroupBg 135
    Add-OverlayGlow $g $w $h 0.15 0.10 0.55 $Script:T.Primary (Get-OverlayAlpha 46 $surface)
    Add-OverlayGlow $g $w $h 0.88 0.85 0.45 $Script:T.Primary (Get-OverlayAlpha 30 $surface)
    # A faint mote field, so a theme with no art of its own still reads as a
    # designed surface rather than a gradient with a line on it.
    $hx = "#{0:x2}{1:x2}{2:x2}" -f $Script:T.Primary.R, $Script:T.Primary.G, $Script:T.Primary.B
    Add-OverlayScatter $g $w $h @($hx) $surface -Seed 23 -Density 20000 -Cap 46 -MinSize 2 -MaxSize 7 -BaseAlpha 40
}

# ---------------------------------------------------------------------------
#  Clown Fiesta                 (clown-fiesta-bg_2.html)
# ---------------------------------------------------------------------------
# The source is 308 SVG elements: a polka ground, a bunting string, drifting
# confetti, four balloons and FIVE CLOWNS. The clowns are the point of it.
$Script:ClownPalette = @("#e63946", "#f5c842", "#2ec4b6", "#ff6eb4", "#9b59b6", "#f5a623")

$Script:OverlayPainters["Clown Fiesta"] = {
    param($g, $w, $h, $surface, $layer)

    if ($layer -eq "motion") {
        # Falling confetti. Dense, because this layer scrolls and a thin one
        # reads as "a piece of confetti slightly moved" rather than as weather.
        Add-OverlayScatter $g $w $h $Script:ClownPalette $surface `
            -Seed 91 -Density 2600 -Cap 150 -MinSize 4 -MaxSize 11 -BaseAlpha 190 -Rects
        return
    }
    if ($layer -eq "motion2") {
        # Balloons, rising the other way at half the speed. Two layers moving
        # in opposite directions is what sells it as motion rather than slide.
        $rand = New-Object System.Random(33)
        $n = [Math]::Max(2, [Math]::Min(7, [int]($w / 190)))
        for ($i = 0; $i -lt $n; $i++) {
            $col = ConvertFrom-Hex $Script:ClownPalette[$rand.Next(0, $Script:ClownPalette.Count)]
            Add-OverlayBalloon $g ([single]$rand.Next(10, [Math]::Max(20, $w))) `
                ([single]$rand.Next(10, [Math]::Max(20, $h))) `
                ([single]$rand.Next(9, 18)) $col $surface 150
        }
        return
    }

    # --- ground -------------------------------------------------------------
    Add-OverlayGradient $g $w $h (ConvertFrom-Hex "#2d1060") (ConvertFrom-Hex "#1a0a2e") 120
    Add-OverlayGlow $g $w $h 0.50 0.35 0.80 (ConvertFrom-Hex "#9b59b6") (Get-OverlayAlpha 120 $surface)
    Add-OverlayGlow $g $w $h 0.12 0.85 0.45 (ConvertFrom-Hex "#ff6eb4") (Get-OverlayAlpha 70 $surface)
    Add-OverlayGlow $g $w $h 0.88 0.15 0.40 (ConvertFrom-Hex "#2ec4b6") (Get-OverlayAlpha 60 $surface)
    Add-OverlayPolka $g $w $h ([System.Drawing.Color]::White) $surface 34 40
    Add-OverlayBunting $g $w $h $Script:ClownPalette $surface 180

    # Balloons behind the clowns, standing still on the ground layer so the
    # picture is complete with the animation switched off.
    $rb = New-Object System.Random(12)
    $nb = [Math]::Max(2, [Math]::Min(6, [int]($w / 210)))
    for ($i = 0; $i -lt $nb; $i++) {
        $col = ConvertFrom-Hex $Script:ClownPalette[$rb.Next(0, $Script:ClownPalette.Count)]
        Add-OverlayBalloon $g ([single]($w * (0.08 + 0.84 * $rb.NextDouble()))) `
            ([single]($h * (0.14 + 0.34 * $rb.NextDouble()))) `
            ([single]([Math]::Max(7, $h * 0.10))) $col $surface 140
    }

    # THE CLOWNS. Sized off the surface height and anchored to the bottom, the
    # way the source anchors them with "bottom:60px". A short banner gets the
    # three big ones; a tall panel gets all five.
    # On the banner the clowns stand in the bottom half only, clear of the
    # caption band that the scrim darkens. Everywhere else they get the full
    # height, because nothing is written over a panel's backdrop.
    # Full height on the banner now that the scrim runs down its two ENDS rather
    # than across its top - the middle is clear, so a clown can stand up in it.
    $share = 0.94
    $clownH = [single]([Math]::Min($h * $share, 300))
    $scale  = [single]($clownH / 320.0)
    # Only where they can actually be seen. A clown is ~50 shapes and five of
    # them is the single most expensive thing any painter does - it is why this
    # theme took a second to switch to. On a panel the artwork is dimmed to 42%
    # and then washed with 140 of panel colour, and on the log 26% and 202; at
    # that strength the clowns are not visible, so drawing them is pure cost.
    # The banner only. On a zone they are almost entirely hidden behind the
    # panels sitting on top of it, and five clowns is the most expensive thing
    # any painter draws - it is most of what made this theme slow to switch to.
    $showClowns = ($surface -eq "header")
    if ($showClowns -and $scale -gt 0.02 -and $w -gt 120) {
        $baseY = [single]($h * 1.02)
        # On the banner they gather in the clear middle, between the two scrimmed
        # ends. Elsewhere they spread right across, because nothing is written
        # over a panel's backdrop.
        $spots = if ($surface -eq "header") {
            @(@(0.58, 1.00, 0), @(0.46, 0.78, 1), @(0.68, 0.74, 2), @(0.38, 0.58, 2))
        } else {
            @(@(0.50, 1.00, 0), @(0.13, 0.70, 1), @(0.87, 0.72, 2))
        }
        if ($w -gt 620 -and $surface -ne "header") { $spots += , @(0.30, 0.52, 2); $spots += , @(0.70, 0.55, 1) }
        foreach ($s in $spots) {
            Add-OverlayClown $g ([single]($w * $s[0])) $baseY ([single]($scale * $s[1])) $surface 215 ([int]$s[2])
        }
    }
    # Static confetti over the top, so the ground alone still looks like a party.
    Add-OverlayScatter $g $w $h $Script:ClownPalette $surface `
        -Seed 5 -Density 3400 -Cap 120 -MinSize 4 -MaxSize 11 -BaseAlpha 170 -Rects
}

# ---------------------------------------------------------------------------
#  Neo Dark / Neo Light       (neo-dark-bg.html, neo-light-bg.html)
# ---------------------------------------------------------------------------
# "Aero glass": a base wash, three blurred aurora ribbons, light shafts, four
# floating glass panes each crossed by a slow specular sweep, and rising motes.
# The panes are the signature and the first port did not have them at all.
$Script:NeoPainter = {
    param($g, $w, $h, $surface, $layer, $bg0, $bg1, $bg2, $a1, $a2, $a3, [bool]$light)
    $boost = if ($light) { 2.0 } else { 1.0 }

    if ($layer -eq "motion") {
        # RISING MOTES - the <canvas id="motes"> loop, which is the movement the
        # source file actually leads with: soft bokeh drifting up through the
        # glass. Drawn as radial dots rather than flat ones so they read as
        # out-of-focus light and not as confetti.
        $rand = New-Object System.Random(71)
        $n = [Math]::Min(80, [int](($w * $h) / 5200))
        for ($i = 0; $i -lt $n; $i++) {
            $r = [single]($rand.Next(3, 11))
            $a = Get-OverlayAlpha ([int]((40 + $rand.Next(0, 70)) * $boost)) $surface
            if ($a -le 2) { continue }
            $cx = [single]$rand.Next(0, [Math]::Max(1, $w)); $cy = [single]$rand.Next(0, [Math]::Max(1, $h))
            $col = ConvertFrom-Hex $(if ($rand.Next(0, 3) -eq 0) { $a1 } else { $a3 })
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddEllipse(($cx - $r), ($cy - $r), ($r * 2), ($r * 2))
            $pb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
            $pb.CenterColor = [System.Drawing.Color]::FromArgb($a, $col)
            $pb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $col))
            try { $g.FillEllipse($pb, ($cx - $r), ($cy - $r), ($r * 2), ($r * 2)) }
            finally { $pb.Dispose(); $path.Dispose() }
        }
        return
    }
    if ($layer -eq "motion2") {
        # THE AURORA RIBBONS DRIFTING - drift1/drift2/drift3, three big blurred
        # blobs crossing the surface. This replaces a hard diagonal streak that
        # was doing duty as the 'sweep' and read as a generic ray; the source's
        # own movement is these, and they are soft enough to belong under text.
        Add-OverlayGlow $g $w $h 0.22 0.30 0.45 (ConvertFrom-Hex $a1) (Get-OverlayAlpha ([int](54 * $boost)) $surface)
        Add-OverlayGlow $g $w $h 0.62 0.72 0.38 (ConvertFrom-Hex $a2) (Get-OverlayAlpha ([int](44 * $boost)) $surface)
        Add-OverlayGlow $g $w $h 0.88 0.20 0.32 (ConvertFrom-Hex $a3) (Get-OverlayAlpha ([int](38 * $boost)) $surface)
        return
    }

    Add-OverlayGradient $g $w $h (ConvertFrom-Hex $bg1) (ConvertFrom-Hex $bg0) 160
    Add-OverlayGlow $g $w $h 0.18 0.12 0.70 (ConvertFrom-Hex $bg2) (Get-OverlayAlpha ([int](110 * $boost)) $surface)
    # the three aurora ribbons
    Add-OverlayGlow $g $w $h 0.10 0.05 0.62 (ConvertFrom-Hex $a1) (Get-OverlayAlpha ([int](96 * $boost)) $surface)
    Add-OverlayGlow $g $w $h 0.92 0.45 0.54 (ConvertFrom-Hex $a2) (Get-OverlayAlpha ([int](80 * $boost)) $surface)
    Add-OverlayGlow $g $w $h 0.45 1.05 0.62 (ConvertFrom-Hex $a3) (Get-OverlayAlpha ([int](62 * $boost)) $surface)
    Add-OverlayRays $g $w $h ([System.Drawing.Color]::White) $surface ([int](40 * $boost)) 3

    # the four glass panes - g1..g4, at the source's proportions and rotations
    $panes = @(
        @(0.08, 0.16, 0.30, 0.44, -6),
        @(0.66, 0.10, 0.24, 0.30,  5),
        @(0.62, 0.58, 0.30, 0.28, -3),
        @(0.40, 0.62, 0.18, 0.34,  8)
    )
    foreach ($p in $panes) {
        Add-OverlayGlassPane $g ([single]($w * $p[0])) ([single]($h * $p[1])) `
            ([single]($w * $p[2])) ([single]($h * $p[3])) ([single]$p[4]) `
            $surface ([int](34 * $boost)) ([single][Math]::Min(18, $h * 0.16))
    }
    Add-OverlayScatter $g $w $h @($a3, $a1) $surface `
        -Seed 5 -Density 9000 -Cap 70 -MinSize 2 -MaxSize 8 -BaseAlpha ([int](70 * $boost))
}
$Script:OverlayPainters["Neo Dark"] = { param($g,$w,$h,$surface,$layer)
    & $Script:NeoPainter $g $w $h $surface $layer "#04121c" "#082334" "#06323d" "#35c3f3" "#4de2b0" "#8ad6ff" $false }
$Script:OverlayPainters["Neo Light"] = { param($g,$w,$h,$surface,$layer)
    & $Script:NeoPainter $g $w $h $surface $layer "#ffffff" "#dcf1f8" "#cfeee4" "#0f9bd7" "#21b58e" "#7fd8f7" $true }

# ---------------------------------------------------------------------------
#  Fresh Water                  (freshwater-bg.html)
# ---------------------------------------------------------------------------
# A lit water surface: 'shimmerLine' across the top, three 'swoosh' polygons
# sliding past each other, and bubbles on the 'rise' keyframe.
$Script:OverlayPainters["Fresh Water"] = {
    param($g, $w, $h, $surface, $layer)
    $acc = @("#7ad9f5", "#6ff0c8", "#b9ecfb")
    if ($layer -eq "motion") {
        # Bubbles, three sizes, and plenty of them.
        Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#dff6ff") $surface 19 60 170
        Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#6ff0c8") $surface 37 35 140
        return
    }
    if ($layer -eq "motion2") {
        # Caustics, not a diagonal streak. The wavy bright lines that light
        # makes on the floor of a pool - what a water theme should be doing,
        # and specific to this theme rather than the generic sweep every other
        # one was borrowing.
        $rand = New-Object System.Random(64)
        for ($i = 0; $i -lt 7; $i++) {
            $a = Get-OverlayAlpha ($rand.Next(40, 90)) $surface
            if ($a -le 2) { continue }
            $pen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::FromArgb($a, (ConvertFrom-Hex "#b9ecfb")), [single]($rand.NextDouble() * 2 + 1))
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            try {
                $y0 = [single]($h * $rand.NextDouble())
                $amp = [single]($h * (0.04 + $rand.NextDouble() * 0.07))
                $step = [single]($w / 6)
                for ($k = 0; $k -lt 6; $k++) {
                    $x0 = [single]($k * $step)
                    $dir = if ($k % 2) { 1 } else { -1 }
                    Add-QuadTo $path $x0 $y0 ($x0 + $step / 2) ($y0 + $amp * $dir) ($x0 + $step) $y0
                }
                $g.DrawPath($pen, $path)
            } finally { $pen.Dispose(); $path.Dispose() }
        }
        return
    }
    Add-OverlayGradient $g $w $h (ConvertFrom-Hex "#1583c4") (ConvertFrom-Hex "#073b52") 160
    Add-OverlayGlow $g $w $h 0.30 -0.05 0.80 (ConvertFrom-Hex "#8fe2f6") (Get-OverlayAlpha 150 $surface)
    Add-OverlayGlow $g $w $h 0.80 0.30 0.50 (ConvertFrom-Hex "#24c9e8") (Get-OverlayAlpha 90 $surface)
    # the three sliding swooshes
    foreach ($s in @(@(0.34, 0.30, 70), @(0.58, 0.26, 50), @(0.80, 0.22, 36))) {
        $a = Get-OverlayAlpha ([int]$s[2]) $surface
        if ($a -le 2) { continue }
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {
            Add-QuadTo $path (-$w * 0.05) ($h * $s[0]) ($w * 0.45) ($h * ($s[0] - $s[1])) ($w * 1.05) ($h * $s[0])
            Add-QuadTo $path ($w * 1.05) ($h * $s[0]) ($w * 0.55) ($h * ($s[0] + $s[1] * 0.5)) (-$w * 0.05) ($h * $s[0])
            $path.CloseFigure()
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, (ConvertFrom-Hex "#6ff0c8")))
            try { $g.FillPath($br, $path) } finally { $br.Dispose() }
        } finally { $path.Dispose() }
    }
    # 'shimmerLine' - the bright band along the surface
    $sa = Get-OverlayAlpha 120 $surface
    if ($sa -gt 2) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($sa, (ConvertFrom-Hex "#dff6ff")), 2.4)
        try { $g.DrawLine($pen, 0, [int]($h * 0.16), $w, [int]($h * 0.11)) } finally { $pen.Dispose() }
    }
    Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#dff6ff") $surface 7 22 140
    Add-OverlayScatter $g $w $h $acc $surface -Seed 3 -Density 9000 -Cap 70 -MinSize 3 -MaxSize 9 -BaseAlpha 90
}

# ---------------------------------------------------------------------------
#  Waste Water                  (wastewater-bg.html)
# ---------------------------------------------------------------------------
# Settled bands, slow morphing blobs ('morph'/'wander') and drifting scum.
$Script:OverlayPainters["Waste Water"] = {
    param($g, $w, $h, $surface, $layer)
    if ($layer -eq "motion") {
        # A LOT more bubbles, in three sizes, rising fast. This is a tank of
        # aerated water: a dozen outlines drifting up was too sparse to read as
        # anything at all.
        Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#93a352") $surface 23 70 170
        Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#c9d98a") $surface 51 45 150
        Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#5d6b33") $surface 77 30 130
        return
    }
    if ($layer -eq "motion2") {
        # driftScum - slow, sideways, lumpy - plus a second bubble field going
        # up at a different rate, so the water has depth rather than one plane.
        Add-OverlayScatter $g $w $h @("#5d6b33", "#2c4a19") $surface `
            -Seed 44 -Density 4200 -Cap 80 -MinSize 6 -MaxSize 22 -BaseAlpha 90
        Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#93a352") $surface 91 40 120
        return
    }
    Add-OverlayGradient $g $w $h (ConvertFrom-Hex "#2b3a1c") (ConvertFrom-Hex "#0c1109") 150
    # the settled bands
    foreach ($b in @(@(0.22, 0.16, "#48562f", 90), @(0.52, 0.20, "#2f3a25", 80), @(0.80, 0.24, "#1a2115", 70))) {
        $a = Get-OverlayAlpha ([int]$b[3]) $surface
        if ($a -le 2) { continue }
        $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, (ConvertFrom-Hex ([string]$b[2]))))
        try { $g.FillRectangle($br, 0, [int]($h * $b[0]), $w, [Math]::Max(1, [int]($h * $b[1]))) } finally { $br.Dispose() }
    }
    Add-OverlayGlow $g $w $h 0.22 0.30 0.55 (ConvertFrom-Hex "#54692c") (Get-OverlayAlpha 130 $surface)
    Add-OverlayGlow $g $w $h 0.78 0.72 0.48 (ConvertFrom-Hex "#93a352") (Get-OverlayAlpha 90 $surface)
    Add-OverlayGlow $g $w $h 0.55 0.10 0.35 (ConvertFrom-Hex "#2c4a19") (Get-OverlayAlpha 80 $surface)
    Add-OverlayBubbles $g $w $h (ConvertFrom-Hex "#93a352") $surface 11 20 120
    Add-OverlayScatter $g $w $h @("#5d6b33", "#93a352", "#2c4a19") $surface `
        -Seed 9 -Density 5200 -Cap 90 -MinSize 4 -MaxSize 16 -BaseAlpha 95
}

# ---------------------------------------------------------------------------
#  Solarized Dark               (solarized-dark-bg.html)
# ---------------------------------------------------------------------------
# A sun below the horizon: a wheel of coloured rays turning very slowly out of
# the bottom edge ('spin', 300s), a warm corona breathing over it, horizon haze,
# and a fine terminal-style cell grid over everything.
$Script:SolarHues = @("#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#268bd2", "#2aa198", "#859900")

$Script:OverlayPainters["Solarized Dark"] = {
    param($g, $w, $h, $surface, $layer)

    if ($layer -eq "motion") {
        # The wheel turning. A rotation cannot be done by scrolling a bitmap, so
        # this is the honest approximation: soft warm rays sweeping sideways.
        Add-OverlayStreaks $g $w $h (ConvertFrom-Hex "#b58900") $surface 44 2 12
        return
    }
    if ($layer -eq "motion2") {
        Add-OverlayScatter $g $w $h @("#2aa198", "#268bd2") $surface `
            -Seed 88 -Density 7000 -Cap 70 -MinSize 2 -MaxSize 6 -BaseAlpha 90
        return
    }

    # base: #00202a -> base03 -> #00323e, top to bottom
    Add-OverlayGradient $g $w $h (ConvertFrom-Hex "#00202a") (ConvertFrom-Hex "#00323e") 90
    Add-OverlayGlow $g $w $h 0.18 0.10 0.62 (ConvertFrom-Hex "#073642") (Get-OverlayAlpha 130 $surface)

    # the ray wheel, radiating from just below the bottom centre
    $cx = [single]($w * 0.5); $cy = [single]($h * 1.04)
    $len = [single]([Math]::Sqrt(($w * $w) + ($h * $h)) * 1.3)
    $n = 16
    for ($i = 0; $i -lt $n; $i++) {
        $a = Get-OverlayAlpha ([int](60 - ($i % 4) * 9)) $surface
        if ($a -le 2) { continue }
        $col = ConvertFrom-Hex $Script:SolarHues[$i % $Script:SolarHues.Count]
        # only the wedges that point up into the surface are worth drawing
        $mid = -180.0 + ($i * (180.0 / $n))
        $half = 3.6
        $p1 = [double]($mid - $half) * [Math]::PI / 180.0
        $p2 = [double]($mid + $half) * [Math]::PI / 180.0
        $pts = @(
            (New-Object System.Drawing.PointF($cx, $cy)),
            (New-Object System.Drawing.PointF(($cx + $len * [Math]::Cos($p1)), ($cy + $len * [Math]::Sin($p1)))),
            (New-Object System.Drawing.PointF(($cx + $len * [Math]::Cos($p2)), ($cy + $len * [Math]::Sin($p2))))
        )
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddPolygon($pts)
        # bright at the hub, gone by the rim - one radialGradient per hue
        $pg = New-Object System.Drawing.Drawing2D.GraphicsPath
        $pg.AddEllipse(($cx - $len), ($cy - $len), ($len * 2), ($len * 2))
        $br = New-Object System.Drawing.Drawing2D.PathGradientBrush($pg)
        $br.CenterPoint  = New-Object System.Drawing.PointF($cx, $cy)
        $br.CenterColor  = [System.Drawing.Color]::FromArgb($a, $col)
        $br.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $col))
        try { $g.FillPath($br, $path) } finally { $br.Dispose(); $pg.Dispose(); $path.Dispose() }
    }

    # the corona sitting just under the horizon, and the haze above it
    Add-OverlayGlow $g $w $h 0.50 1.06 0.75 (ConvertFrom-Hex "#fdf6e3") (Get-OverlayAlpha 95 $surface)
    Add-OverlayGlow $g $w $h 0.50 1.02 0.55 (ConvertFrom-Hex "#b58900") (Get-OverlayAlpha 85 $surface)
    $ha = Get-OverlayAlpha 90 $surface
    if ($ha -gt 2) {
        $hz = New-Object System.Drawing.Rectangle(0, [int]($h * 0.58), [Math]::Max(1, $w), [Math]::Max(1, [int]($h * 0.42)))
        $hb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $hz, [System.Drawing.Color]::FromArgb(0, (ConvertFrom-Hex "#0a4b59")),
                [System.Drawing.Color]::FromArgb($ha, (ConvertFrom-Hex "#0a4b59")), 90)
        try { $g.FillRectangle($hb, $hz) } finally { $hb.Dispose() }
    }

    # the cell grid - 1px every 9px across, every 18px down
    $ca = Get-OverlayAlpha 30 $surface
    if ($ca -gt 2) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($ca, (ConvertFrom-Hex "#586e75")), 1)
        try {
            for ($x = 0; $x -lt $w; $x += 9)  { $g.DrawLine($pen, $x, 0, $x, $h) }
            for ($y = 0; $y -lt $h; $y += 18) { $g.DrawLine($pen, 0, $y, $w, $y) }
        } finally { $pen.Dispose() }
    }
}

# ---------------------------------------------------------------------------
#  Dark / Light (Metro)         (metro-dark-bg.html, metro-light-bg.html)
# ---------------------------------------------------------------------------
# The sparsest pair: a flat ground and six long diagonals on a 90s 'crawl'.
$Script:MetroPainter = {
    param($g, $w, $h, $surface, $layer, $bg1, $bg2, $a1, $a2)
    # A light ground swallows a mark the dark one shows plainly, so the washes
    # are scaled to the ground they sit on. Small hard-edged marks are NOT
    # boosted: a dark accent dot on white is already a far bigger jump than the
    # same dot on charcoal, and boosting those is what turns art into noise.
    $bgc = ConvertFrom-Hex $bg2
    $isLight = ((0.299 * $bgc.R) + (0.587 * $bgc.G) + (0.114 * $bgc.B)) -ge 150
    $boost = if ($isLight) { 1.75 } else { 1.0 }
    $dots  = if ($isLight) { 1.10 } else { 1.0 }

    if ($layer -eq "motion") {
        Add-OverlayStreaks $g $w $h (ConvertFrom-Hex $a1) $surface ([int](40 * $boost)) 2 26
        return
    }
    if ($layer -eq "motion2") {
        Add-OverlayStreaks $g $w $h (ConvertFrom-Hex $a2) $surface ([int](30 * $boost)) 2 -26
        return
    }
    Add-OverlayGradient $g $w $h (ConvertFrom-Hex $bg1) (ConvertFrom-Hex $bg2) 100
    Add-OverlayGlow $g $w $h 0.20 0.15 0.55 (ConvertFrom-Hex $a1) (Get-OverlayAlpha ([int](60 * $boost)) $surface)
    Add-OverlayGlow $g $w $h 0.82 0.80 0.45 (ConvertFrom-Hex $a2) (Get-OverlayAlpha ([int](46 * $boost)) $surface)
    Add-OverlayScatter $g $w $h @($a1, $a2) $surface `
        -Seed 17 -Density 15000 -Cap 64 -MinSize 2 -MaxSize 8 -BaseAlpha ([int](44 * $dots))
    # the six crawling diagonals
    $i = 0
    foreach ($pair in @(@($a1, 0.18), @($a2, 0.34), @($a1, 0.50), @($a2, 0.66), @($a1, 0.82), @($a2, 0.95))) {
        $i++
        $a = Get-OverlayAlpha ([int]((46 - $i * 4) * $dots)) $surface
        if ($a -le 2) { continue }
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($a, (ConvertFrom-Hex $pair[0])), 3)
        try {
            $y = [int]($h * $pair[1])
            $g.DrawLine($pen, [int](-$w * 0.1), ($y + [int]($h * 0.25)), $w, ($y - [int]($h * 0.25)))
        } finally { $pen.Dispose() }
    }
}
$Script:OverlayPainters["Dark"]  = { param($g,$w,$h,$surface,$layer)
    & $Script:MetroPainter $g $w $h $surface $layer "#2e2e2e" "#1c1c1c" "#ff7a18" "#a97bec" }
$Script:OverlayPainters["Light"] = { param($g,$w,$h,$surface,$layer)
    & $Script:MetroPainter $g $w $h $surface $layer "#ffffff" "#f0f0f0" "#ca5010" "#8764b8" }
function Get-ContrastingText {
    <#
        Readable text for a filled surface - the token system's
        --primary-foreground, worked out rather than assumed.

        Every button painted in an accent colour used a hard-coded White. That
        is right on this tool's dark accents and wrong the moment a palette has
        a light one - and the Neo light theme has several. Deciding from the
        surface's own brightness means a new theme cannot introduce white text
        on a pale button by accident.
    #>
    param([System.Drawing.Color]$OnColor)
    $lum = (0.299 * $OnColor.R) + (0.587 * $OnColor.G) + (0.114 * $OnColor.B)
    if ($lum -ge 150) { return [System.Drawing.Color]::FromArgb(15, 23, 42) }  # --foreground
    return [System.Drawing.Color]::White
}

function Get-DividerColor {
    <#
        One colour for every divider in the window: the splitter bars, the rule
        between the Options columns, and anything else that separates rather
        than contains.

        Dividers used to take whatever colour was nearest to hand - the splitter
        bars were the form background (invisible, so there was nothing to aim
        at with the mouse) and the accent bar was Primary, which is a dark blue
        in the dark themes and disappears against the panels around it. This
        derives one shade from the theme instead: a step from the group colour
        TOWARDS the text colour, so it is always visible whichever way round the
        theme is, and always the same weight.
    #>
    param($Theme = $null)
    $th = if ($Theme) { $Theme } else { $Script:T }
    $bg = $th.GroupBg; $fg = $th.Text
    $mix = 0.32
    return [System.Drawing.Color]::FromArgb(
        [int]($bg.R + (($fg.R - $bg.R) * $mix)),
        [int]($bg.G + (($fg.G - $bg.G) * $mix)),
        [int]($bg.B + (($fg.B - $bg.B) * $mix)))
}

function Set-ActiveTheme {
    param([string]$Name)
    if ($Script:Themes.ContainsKey($Name)) {
        $Script:T = $Script:Themes[$Name]
        # The accents belong to the theme now, so they move with it.
        Set-AccentColors
    }
}

function Get-ThemeNames {
    # Ordered for the menu: the house themes first, then the rest.
    $first = @("Neo Dark", "Neo Light")
    return @($first + @($Script:Themes.Keys | Where-Object { $first -notcontains $_ } | Sort-Object))
}

function Apply-Theme {
    param([System.Windows.Forms.Form]$Form, [string]$ThemeName)
    Set-ActiveTheme $ThemeName
    $t = $Script:T

    if ($Script:DwmAvailable -and $Form.IsHandleCreated) {
        try { [DwmHelper]::SetDarkTitleBar($Form.Handle, $t.DarkTitle) } catch { }
        $Form.Refresh()
    }

    # The menu is drawn by a renderer, not by control colours, so recolouring it
    # means updating the colour table and forcing a repaint. Skipped silently
    # when the renderer could not be compiled - the fallback is a system-drawn
    # menu with dark text, which is readable in every theme.
    try {
        if ($Script:MenuRendererAvailable -and $Form.MainMenuStrip) {
            [UTWMenuColors]::Bg     = $t.GroupBg
            [UTWMenuColors]::Sel    = $t.Primary
            [UTWMenuColors]::Border = $t.MedBg
            $Form.MainMenuStrip.BackColor = $t.GroupBg
            $Form.MainMenuStrip.ForeColor = $t.Text
            # BackColor as well as ForeColor, on the TOP-LEVEL items too. Only
            # ForeColor was set here, so File/View/Help kept whatever BackColor
            # they were created with - the dark GroupBg of the startup theme -
            # and the menu bar stayed dark in every light theme afterwards. An
            # item's own BackColor beats the renderer's colour table, so it has
            # to be re-set or cleared on every theme change.
            foreach ($top in $Form.MainMenuStrip.Items) {
                $top.BackColor = $t.GroupBg; $top.ForeColor = $t.Text
                if ($top.HasDropDownItems) {
                    try { $top.DropDown.BackColor = $t.GroupBg; $top.DropDown.ForeColor = $t.Text } catch { }
                    foreach ($sub in $top.DropDownItems) {
                        $sub.BackColor = $t.GroupBg; $sub.ForeColor = $t.Text
                        if ($sub.HasDropDownItems) {
                            try { $sub.DropDown.BackColor = $t.GroupBg; $sub.DropDown.ForeColor = $t.Text } catch { }
                            foreach ($s2 in $sub.DropDownItems) { $s2.BackColor = $t.GroupBg; $s2.ForeColor = $t.Text }
                        }
                    }
                }
            }
            $Form.MainMenuStrip.Invalidate()
        }
    } catch { }

    # Context menus are not in Form.Controls, so the walk below never sees them.
    # Any strip that wants to follow the theme registers itself here.
    try {
        foreach ($strip in @($Script:ThemedStrips)) {
            if (-not $strip) { continue }
            $strip.BackColor = $t.GroupBg; $strip.ForeColor = $t.Text
            foreach ($mi in $strip.Items) {
                $mi.BackColor = $t.GroupBg; $mi.ForeColor = $t.Text
            }
        }
    } catch { }

    $divider = Get-DividerColor $t

    $applyToControl = {
        param($ctrl)
        if ($ctrl -is [System.Windows.Forms.SplitContainer]) {
            # The BAR is the divider colour so it can be seen and aimed at; the
            # PANELS stay the form colour so the two halves read as one surface.
            # The bar used to be the form colour too, which made the thing you
            # are meant to drag completely invisible.
            $ctrl.BackColor = $divider
            $ctrl.Panel1.BackColor = $t.DarkBg
            $ctrl.Panel2.BackColor = $t.DarkBg
        } elseif ($ctrl -is [System.Windows.Forms.TableLayoutPanel]) {
            $ctrl.BackColor = $t.DarkBg
        } elseif ($ctrl -is [System.Windows.Forms.Panel]) {
            # Every divider in the window is now the SAME derived shade. The
            # header rule was Primary, which is a dark blue in the dark themes
            # and unreadable against the panel behind it.
            if     ($ctrl.Tag -eq "accent-bar")  { $ctrl.BackColor = $divider }
            elseif ($ctrl.Tag -eq "rule")        { $ctrl.BackColor = $divider }
            elseif ($ctrl.Tag -eq "danger-rule") { $ctrl.BackColor = $t.Error }
            # A panel used purely as a toolbar strip INSIDE a group box has to
            # take the group's colour, not the form's, or it paints a darker
            # band across the top of the group on every theme change.
            elseif ($ctrl.Tag -eq "group-panel") { $ctrl.BackColor = $t.GroupBg }
            else                                 { $ctrl.BackColor = $t.DarkBg }
        } elseif ($ctrl -is [System.Windows.Forms.GroupBox]) {
            $ctrl.BackColor = $t.GroupBg; $ctrl.ForeColor = $t.Primary
        } elseif ($ctrl -is [System.Windows.Forms.ListView]) {
            # There was no branch for ListView at all, so the lookup panel's
            # list kept the dark colours it was built with and stayed dark in
            # every light theme. Rows that were dimmed on purpose (a store that
            # has already been restored) are re-dimmed rather than reset, or
            # they would come back as ordinary rows.
            # With the backdrop on, take the artwork's own colour so the list
            # belongs to the picture around it instead of sitting on it as a
            # flat slab. Off, this returns the base colour unchanged.
            $ctrl.BackColor = Get-OverlayTint "panel" $t.MedBg 0.5
            $ctrl.ForeColor = $t.Text
            foreach ($item in $ctrl.Items) {
                # Tag is a hashtable from the logic layer, so ask for the key
                # rather than for a property - a hashtable has no PSObject
                # property called ImportedOn and the test would always fail.
                $done = $false
                try {
                    if ($item.Tag -is [hashtable]) { $done = [bool]$item.Tag["ImportedOn"] }
                    elseif ($item.Tag)             { $done = [bool]$item.Tag.ImportedOn }
                } catch { }
                $item.ForeColor = if ($done) { $t.TextDim } else { $t.Text }
            }
        } elseif ($ctrl -is [System.Windows.Forms.RichTextBox]) {
            # The summary pane sits INSIDE a group box and has no border, so it
            # has to take the group's colour. Painting it the output-log colour
            # drew a dark rectangle inside a lighter panel - "the panel retains
            # the original colour of what it was opened with".
            if ($ctrl.Tag -eq "plan") {
                $ctrl.BackColor = Get-OverlayTint "panel" $t.GroupBg 0.55; $ctrl.ForeColor = $t.Text
            } else {
                # The output log takes the strongest tint of anything: it is the
                # biggest single surface in the window, so leaving it flat while
                # everything round it carries artwork is what made the backdrop
                # look like it stopped at the log.
                $ctrl.BackColor = Get-OverlayTint "log" $t.OutputBg 0.6; $ctrl.ForeColor = $t.OutputFg
            }
        } elseif ($ctrl -is [System.Windows.Forms.TextBox]) {
            if ($ctrl.Tag -eq "output") { $ctrl.BackColor = $t.OutputBg; $ctrl.ForeColor = $t.OutputFg }
            # The Expert command box is built on the FORM colour, not the field
            # colour, so it reads as a console rather than as another input.
            # Without this it flipped to the field colour on every theme change
            # and never went back.
            elseif ($ctrl.Tag -eq "command") { $ctrl.BackColor = $t.DarkBg; $ctrl.ForeColor = $t.Text }
            else { $ctrl.BackColor = $t.MedBg; $ctrl.ForeColor = $t.Text }
        } elseif ($ctrl -is [System.Windows.Forms.ComboBox]) {
            $ctrl.BackColor = $t.MedBg; $ctrl.ForeColor = $t.Text
        } elseif ($ctrl -is [System.Windows.Forms.Button]) {
            # Tag-based colour preservation for special buttons
            if ($ctrl.Tag -eq "stop-btn") {
                $ctrl.BackColor = $t.Error; $ctrl.ForeColor = [System.Drawing.Color]::White
            } elseif ($ctrl.Tag -eq "run-btn") {
                # Run button colour is managed by Update-RunButtonColor; just keep white text
                $ctrl.ForeColor = [System.Drawing.Color]::White
            } elseif ($ctrl.Tag -eq "toggle-details") {
                $ctrl.BackColor = $t.GroupBg; $ctrl.ForeColor = $t.Primary
            } elseif ($ctrl.Tag -eq "browse") {
                $ctrl.BackColor = $t.MedBg; $ctrl.ForeColor = $t.Text
            } elseif ($ctrl.Tag -eq "danger" -or $ctrl.Tag -eq "danger-head") {
                # Destructive options stay in the error colour in every theme.
                # Falling back to the ordinary text colour would make them look
                # like any other checkbox, which is the one thing they are not.
                $ctrl.ForeColor = $t.Error
            } elseif ($ctrl.Tag -eq "btn-clear" -or $ctrl.Tag -eq "btn-logs" -or $ctrl.Tag -eq "btn-newwin") {
                # Fixed accents, set by the form - keep the white text and let
                # the form own the fill so each Actions button stays distinct.
                $ctrl.ForeColor = [System.Drawing.Color]::White
            } else {
                $ctrl.BackColor = $t.MedBg; $ctrl.ForeColor = $t.Text
            }
        } elseif ($ctrl -is [System.Windows.Forms.RadioButton]) {
            $ctrl.ForeColor = $t.Text
        } elseif ($ctrl -is [System.Windows.Forms.CheckBox]) {
            # "danger" was handled ONLY in the Button branch, so the two
            # destructive check boxes fell through to ordinary text and lost
            # their red the first time the theme was changed - which is the one
            # thing about them that must never change.
            if     ($ctrl.Tag -eq "danger") { $ctrl.ForeColor = $t.Error }
            elseif ($ctrl.Tag -eq "dim")    { $ctrl.ForeColor = $t.TextDim }
            else                            { $ctrl.ForeColor = $t.Text }
        } elseif ($ctrl -is [System.Windows.Forms.Label]) {
            if ($ctrl.Tag -eq "title")             { $ctrl.ForeColor = $t.Primary }
            elseif ($ctrl.Tag -eq "dim")            { $ctrl.ForeColor = $t.TextDim }
            elseif ($ctrl.Tag -eq "status-warning") { $ctrl.ForeColor = $t.Warning }
            elseif ($ctrl.Tag -eq "status-ok")      { $ctrl.ForeColor = $t.Success }
            # Same omission as the check boxes: the "ADVANCED - these change or
            # destroy data" heading turned plain white on a theme change.
            elseif ($ctrl.Tag -eq "danger" -or $ctrl.Tag -eq "danger-head") { $ctrl.ForeColor = $t.Error }
            elseif ($ctrl.Tag -eq "accent-cyan")    { } # preserve cyan accent - do not override
            elseif ($ctrl.Tag -eq "accent-purple")  { } # preserve purple accent - do not override
            else                                    { $ctrl.ForeColor = $t.Text }
        }
        foreach ($child in $ctrl.Controls) { & $applyToControl $child }
    }

    $Form.BackColor = $t.DarkBg; $Form.ForeColor = $t.Text
    foreach ($ctrl in $Form.Controls) { & $applyToControl $ctrl }
    $Form.Invalidate($true)
}

