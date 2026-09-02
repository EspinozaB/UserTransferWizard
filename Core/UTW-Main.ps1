#Requires -Version 5.1
<#
.SYNOPSIS
    User Transfer Wizard (UTW)  -  GUI for network-based and USB profile migration.
    Supports running locally OR remotely exporting from a tech workstation
    without WinRM by using scheduled tasks (schtasks.exe) over DCOM/RPC.
.NOTES
    UTW is this tool. USMT is Microsoft's User State Migration Toolset that UTW
    drives - scanstate.exe, loadstate.exe, migapp.xml and friends. Names that
    refer to those keep the USMT prefix; names for this application do not.

    Run as Administrator. Launch via UTW-Launcher.bat for no console.
    Place a custom UTW.ico / icon.ico / app.ico next to this script.

    All three .ps1 files must live in the same folder:
        UTW-Main.ps1     <- this file (GUI)
        UTW-Logic.ps1    <- business logic + remote export
        UTW-Themes.ps1   <- theme data + Apply-Theme
        UTW_Settings.json
#>

param(
    # Path to a one-shot JSON file written by the "New Window" button of an
    # existing instance. It carries that window's field values so the second
    # migration starts from the same settings instead of being retyped. The
    # file is consumed and deleted on read, and its presence is what marks this
    # process as a SECONDARY window - see $Script:IsSecondary.
    [string]$Handoff = ""
)

# Startup timing from the first line that can be timed. Written to the crash
# log at each phase, because "the loading screen feels slow" needs a number
$Script:BootClock = [Diagnostics.Stopwatch]::StartNew()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ONE Add-Type for every helper class in the tool.
#
# These were three separate Add-Type calls, and each one spawns the C# compiler:
# measured at 316 + 194 + 224 ms on this machine, against 203 ms for all three
# in a single compilation. Half a second of the startup was the compiler being
# started three times over. The classes are unrelated to each other; the only
# thing they share is that they must all exist before the first window does.
#
# DPI awareness in particular MUST be declared before the process creates a
# window, which is why this block stays at the top of the file.
$Script:NativeHelpers = $false
try {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class DwmHelper {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void SetDarkTitleBar(IntPtr handle, bool dark) {
        int val = dark ? 1 : 0;
        DwmSetWindowAttribute(handle, 20, ref val, sizeof(int));
    }
}

// A Panel that composites itself and its children in ONE bottom-up pass.
//
// A caption with a transparent background is painted from its parent, but it
// repaints on its own schedule - so over an animating surface its rectangle can
// show a frame slightly out of step with the artwork around it. That is the
// stutter in the banner's text while the particles drift past.
//
// WS_EX_COMPOSITED makes Windows buffer the whole container and its children
// together and present them in one go, which is the documented cure for exactly
// that tearing. It costs a buffer the size of the panel, which is why it is on
// the banner alone and not on the window.
public class UTWCompositedPanel : System.Windows.Forms.Panel {
    protected override System.Windows.Forms.CreateParams CreateParams {
        get {
            System.Windows.Forms.CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x02000000;   // WS_EX_COMPOSITED
            return cp;
        }
    }
}

public class DpiHelper {
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] private static extern int  SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] private static extern int  GetDpiForMonitor(IntPtr hmon, int type, out uint x, out uint y);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    // WHY PER-MONITOR AND NOT SYSTEM.
    //
    // A System-aware process tells Windows "I was built for the DPI this
    // session started at". When that changes underneath it - which is exactly
    // what an RDP session does when you reconnect from a different machine -
    // Windows keeps its promise by BITMAP-STRETCHING the window to the new
    // scale. Stretching a rendered window is what made the output log blurry
    // and unreadable after moving between a 4K monitor and a laptop; nothing
    // was re-drawn, it was resampled.
    //
    // Per-Monitor V2 turns the stretching off: the window is always drawn at
    // the real DPI, so text stays sharp. The price is that Windows no longer
    // resizes anything for us - a DPI change now has to be caught and the
    // layout rescaled by hand, which is what the display watchdog does. That
    // suits this layout, which is fixed-pixel and scales itself anyway.
    //
    // -4 is DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, Windows 10 1703 and up.
    // Older Windows falls through to the System behaviour it had before.
    public static string MakeBestAware(bool perMonitor) {
        if (perMonitor) {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) { return "PerMonitorV2"; } } catch { }
        }
        try { if (SetProcessDpiAwareness(1) == 0) { return "System"; } } catch { }
        try { if (SetProcessDPIAware())          { return "System (legacy)"; } } catch { }
        return "Unchanged";
    }
    public static string MakeSystemAware() { return MakeBestAware(false); }

    // The monitor's REAL scale, whatever this process claims to be.
    //
    // Graphics.DpiX and GetDeviceCaps both report the DPI the process was
    // pinned to at start, so under System awareness they keep answering 144
    // long after the session has moved to a 96 DPI laptop - they cannot see
    // the change that caused the problem. GetDpiForMonitor is a query about
    // the hardware and is not virtualised, so it can. 0 means "could not tell",
    // and the caller keeps whatever it had.
    public static int MonitorDpi(IntPtr hwnd) {
        try {
            IntPtr mon = MonitorFromWindow(hwnd, 2);   // MONITOR_DEFAULTTONEAREST
            uint x, y;
            if (GetDpiForMonitor(mon, 0, out x, out y) == 0 && x > 0) { return (int)x; }
        } catch { }
        return 0;
    }
}

// Freezes a window's painting while a batch of controls is moved, then puts it
// back with ONE repaint of the whole subtree.
//
// SuspendLayout only stops the LAYOUT pass; each control still paints itself as
// it is moved, so dragging a divider repainted forty controls one at a time and
// the eye caught the intermediate states - most visibly on the combo boxes,
// which draw their own drop-down arrow and so briefly showed it in two places.
// WM_SETREDRAW is the only way to stop that: no painting at all until the batch
// is finished.
// Progress on the taskbar button, so a minimised window still says how far in
// it is. Same reasoning as the flash: a migration takes many minutes and the
// operator does something else meanwhile.
//
// ITaskbarList3 is a plain shell COM interface - no network, no elevation, no
// files. The method ORDER below is load-bearing: a COM vtable is positional, so
// the four ITaskbarList methods and the one ITaskbarList2 method have to be
// declared, in order, before the two that are actually wanted. Getting that
// wrong does not fail to compile; it calls the wrong function.
[ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITaskbarList3 {
    void HrInit();                                              // ITaskbarList
    void AddTab(IntPtr hwnd);
    void DeleteTab(IntPtr hwnd);
    void ActivateTab(IntPtr hwnd);
    void SetActiveAlt(IntPtr hwnd);
    void MarkFullscreenWindow(IntPtr hwnd, bool fFullscreen);   // ITaskbarList2
    void SetProgressValue(IntPtr hwnd, ulong completed, ulong total);
    void SetProgressState(IntPtr hwnd, int flags);              // ITaskbarList3
}
[ComImport, Guid("56fdf344-fd6d-11d0-958a-006097c9a090"), ClassInterface(ClassInterfaceType.None)]
public class TaskbarInstance { }

public class TaskbarProgress {
    // 0 none, 1 marquee, 2 normal, 4 error, 8 paused.
    static ITaskbarList3 _bar;
    static bool _tried;
    static ITaskbarList3 Bar() {
        if (!_tried) {
            _tried = true;
            // Windows 7 and up. On anything older the cast fails and every call
            // below turns into a no-op rather than an exception on a migration.
            try { _bar = (ITaskbarList3)(new TaskbarInstance()); _bar.HrInit(); }
            catch { _bar = null; }
        }
        return _bar;
    }
    public static void SetState(IntPtr h, int flags) {
        try { ITaskbarList3 b = Bar(); if (b != null && h != IntPtr.Zero) b.SetProgressState(h, flags); } catch { }
    }
    public static void SetValue(IntPtr h, int percent) {
        try {
            ITaskbarList3 b = Bar();
            if (b == null || h == IntPtr.Zero) return;
            if (percent < 0) percent = 0; if (percent > 100) percent = 100;
            b.SetProgressState(h, 2);
            b.SetProgressValue(h, (ulong)percent, 100UL);
        } catch { }
    }
}

// Flashes the taskbar button when a long job finishes and nobody is watching.
//
// A migration runs for many minutes and the operator goes and does something
// else; the tool finishing in the background is the whole reason they have to
// keep checking it. This is the same user32 call every chat client uses to say
// "there is something here for you": no network, no injection, no files, and it
// stops the moment the window is brought to the front.
public class FlashHelper {
    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO {
        public uint cbSize; public IntPtr hwnd; public uint dwFlags;
        public uint uCount; public uint dwTimeout;
    }
    [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    const uint FLASHW_ALL       = 3;   // caption and taskbar button
    const uint FLASHW_TIMERNOFG = 12;  // keep going until the window is focused

    public static void Flash(IntPtr h, uint count) {
        if (h == IntPtr.Zero) return;
        FLASHWINFO fi = new FLASHWINFO();
        fi.cbSize   = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        fi.hwnd     = h;
        fi.dwFlags  = FLASHW_ALL | FLASHW_TIMERNOFG;
        fi.uCount   = count;
        fi.dwTimeout = 0;
        FlashWindowEx(ref fi);
    }
}

public class RedrawHelper {
    [DllImport("user32.dll")] private static extern int SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
    [DllImport("user32.dll")] private static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprc, IntPtr hrgn, uint flags);
    const int  WM_SETREDRAW   = 0x000B;
    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE      = 0x0004;
    const uint RDW_ALLCHILDREN= 0x0080;
    const uint RDW_UPDATENOW  = 0x0100;

    public static void Suspend(IntPtr h) {
        if (h != IntPtr.Zero) SendMessage(h, WM_SETREDRAW, 0, 0);
    }
    // paintNow forces the repaint to happen synchronously, before this returns.
    // That costs a full paint of every child - measured at 39 ms for the setup
    // column - so during a DRAG it is left off and the invalidated region is
    // painted on the next WM_PAINT, which Windows coalesces for us.
    public static void Resume(IntPtr h, bool paintNow) {
        if (h == IntPtr.Zero) return;
        SendMessage(h, WM_SETREDRAW, 1, 0);
        // No RDW_ERASE: every control here is double-buffered, so it paints its
        // own background. An erase pass over 150 children is wasted work, and
        // erase-then-paint is itself a source of the flicker this is meant to
        // stop.
        uint flags = RDW_INVALIDATE | RDW_ALLCHILDREN;
        if (paintNow) flags |= RDW_UPDATENOW;
        RedrawWindow(h, IntPtr.Zero, IntPtr.Zero, flags);
    }
}

// A MenuStrip drawn with RenderMode "System" ignores BackColor and ForeColor
// entirely - Windows paints it from the system palette, which in a dark theme
// gives near-white dropdowns with pale text. The colours have to come from a
// ColorTable, and that needs a real subclass; there is no way to do it from
// PowerShell alone. Static fields, so Apply-Theme can recolour it in place.
public class UTWMenuColors : ProfessionalColorTable {
    public static Color Bg     = Color.FromArgb(50, 50, 54);
    public static Color Sel    = Color.FromArgb(0, 120, 212);
    public static Color Border = Color.FromArgb(80, 80, 84);
    public override Color MenuStripGradientBegin        { get { return Bg; } }
    public override Color MenuStripGradientEnd          { get { return Bg; } }
    public override Color ToolStripDropDownBackground   { get { return Bg; } }
    public override Color ImageMarginGradientBegin      { get { return Bg; } }
    public override Color ImageMarginGradientMiddle     { get { return Bg; } }
    public override Color ImageMarginGradientEnd        { get { return Bg; } }
    public override Color MenuItemSelected              { get { return Sel; } }
    public override Color MenuItemBorder                { get { return Sel; } }
    public override Color MenuBorder                    { get { return Border; } }
    public override Color MenuItemSelectedGradientBegin { get { return Sel; } }
    public override Color MenuItemSelectedGradientEnd   { get { return Sel; } }
    public override Color MenuItemPressedGradientBegin  { get { return Bg; } }
    public override Color MenuItemPressedGradientEnd    { get { return Bg; } }
    // The MIDDLE stop was missing, so an OPEN top-level item ("File" while its
    // dropdown is showing) was painted with the default light gradient - a pale
    // band across an otherwise dark menu bar.
    public override Color MenuItemPressedGradientMiddle { get { return Bg; } }
    public override Color SeparatorDark                 { get { return Border; } }
    public override Color SeparatorLight                { get { return Border; } }
    // Ticked items (the theme list, the panel list) drew the default pale blue
    // box around their check mark regardless of theme.
    public override Color CheckBackground               { get { return Sel; } }
    public override Color CheckSelectedBackground       { get { return Sel; } }
    public override Color CheckPressedBackground        { get { return Sel; } }
    public override Color ToolStripBorder               { get { return Bg; } }
    public override Color ToolStripGradientBegin        { get { return Bg; } }
    public override Color ToolStripGradientMiddle       { get { return Bg; } }
    public override Color ToolStripGradientEnd          { get { return Bg; } }
}
"@ -ErrorAction Stop
    $Script:NativeHelpers = $true
} catch {
    # One compile, so it is all or nothing: if the C# compiler is unavailable
    # every one of these degrades to its documented fallback rather than the
    # tool refusing to start.
    $Script:NativeHelpers = $false
}
$Script:DwmAvailable          = $Script:NativeHelpers
$Script:MenuRendererAvailable = $Script:NativeHelpers
$Script:RedrawAvailable       = $Script:NativeHelpers
# UTW_DPIMODE=system puts the old behaviour back. Per-monitor awareness is the
# right answer and it is the default, but it hands this tool a job Windows used
# to do badly on its behalf - if the rescaling ever misbehaves on a display
# nobody here has, that switch is faster than an edit.
$Script:PerMonitorWanted = ("$env:UTW_DPIMODE" -ne "system")
$Script:DpiAwareness = if ($Script:NativeHelpers) {
    try { [DpiHelper]::MakeBestAware($Script:PerMonitorWanted) } catch { "Unavailable" }
} else { "Unavailable" }

trap {
    [System.Windows.Forms.MessageBox]::Show("Fatal error: $($_.Exception.Message)`n`n$($_.ScriptStackTrace)", "User Transfer Wizard Error", "OK", "Error")
    exit 1
}

$Script:ScriptDir    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script:CrashLogPath = Join-Path $Script:ScriptDir "CrashLog.txt"

# The scripts can sit in their own subfolder (a Core\ layout) with xaml\, Docs\
# and the tuned XML as siblings of that folder, or everything can be in one
# folder. RepoRoot is the folder that holds it all; ScriptDir is where the .ps1
# files are. Get-UTWResource finds a shipped file wherever the layout put it.
$Script:RepoRoot = if ((Split-Path $Script:ScriptDir -Leaf) -match '^(Core|Scripts|src|bin)$') {
    Split-Path $Script:ScriptDir -Parent
} else { $Script:ScriptDir }

function Get-UTWResource {
    param([Parameter(Mandatory)][string]$Name)
    $bases = @($Script:ScriptDir, $Script:RepoRoot,
               (Join-Path $Script:RepoRoot 'Docs'),
               (Join-Path $Script:RepoRoot 'Modified USMT Config Files')) | Select-Object -Unique
    foreach ($b in $bases) {
        if (-not $b) { continue }
        $p = Join-Path $b $Name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
function Write-CrashLog {
    <#
        Appends one line to the crash log, retrying briefly if the file is busy.

        The old version was a single Add-Content in a swallow-everything catch,
        so any transient lock DROPPED the line silently - and the crash log is
        the only record this tool keeps of what went wrong. Anything reading the
        file takes a share lock: a tail in another window, a support person with
        it open in Notepad, or the startup test polling it. Two diagnostics in a
        row went missing that way while a test watched the file.

        Opened with FileShare.ReadWrite so a reader does not block US either,
        then three quick retries. Still never throws - a logging failure must
        not take a migration down - but it now has to fail four times over
        before a line is actually lost.
    #>
    param([string]$Msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $fs = New-Object System.IO.FileStream(
                $Script:CrashLogPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite)
            try {
                $sw = New-Object System.IO.StreamWriter($fs)
                try { $sw.WriteLine($line) } finally { $sw.Dispose() }
            } finally { $fs.Dispose() }
            return
        } catch {
            Start-Sleep -Milliseconds 25
        }
    }
}
Write-CrashLog "=== Script starting ==="
Write-CrashLog "Boot: assemblies + helpers compiled at $($Script:BootClock.ElapsedMilliseconds) ms"
$Script:MainForm = $null

#region ==================== DISPLAY SCALING ====================
# The GUI is hand-authored in fixed pixels at a nominal 700 x 1040. Two things
# break that on a 14" 1080p laptop:
#
#   1. 1040px + title bar is taller than the ~1032px work area of a 1080p
#      screen even at 100%. At 125%/150% it is 200-350px too tall.
#   2. Fonts are declared in points and grow with DPI; the control rectangles
#      around them do not. At 144 DPI a 9.5pt font is ~19px tall in a box drawn
#      for 13px, which clips labels and button captions.
#
# Everything below solves both with one factor: the layout is authored at 1.0,
# then the finished control tree is scaled and its fonts converted to pixel
# units so text and boxes stay in proportion at any DPI. Where the layout
# already fits, the factor is 1.0 and nothing changes.

$Script:UIScale = 1.0

# (The UTWMenuColors colour table is compiled with the other helpers at the
# top of this file - one C# compilation instead of three.)

# The factor the FINISHED layout was actually scaled by. Stays 1.0 until
# Set-FormScale has run on the main form, so anything that positions a control
# after that pass (Update-Fields rearranges two boxes on every operation
# change) can convert design pixels into real ones. See Set-DesignBounds.
$Script:LayoutScale = 1.0
# TOUCH TARGETS ARE A MULTIPLIER ON THE DISPLAY SCALE, not a separate layout.
#
# A finger is about 9mm across and a mouse pointer is one pixel. The gap has to
# be made up somewhere, and the honest way is to make everything bigger - which
# this layout already knows how to do, exactly once, through a factor that has
# been measured against a natively-built window. A second set of "touch sizes"
# for buttons and rows would be a second layout to keep in step with the first.
$Script:TouchBoost = 1.0

function Invoke-TaskbarFlash {
    <#
        Says "I have finished" to an operator who has gone somewhere else.

        Only when the window is NOT in front - flashing a window somebody is
        already looking at is noise, and the one thing worse than a tool you
        have to keep checking is a tool that interrupts you when you are not.
        Silent by design when the helper did not compile, and never during the
        self-test, which builds and closes windows in a loop.
    #>
    param([System.Windows.Forms.Form]$Form, [int]$Count = 5)
    if ($env:UTW_LAYOUT_SELFTEST) { return }
    if (-not $Script:NativeHelpers -or -not $Form -or -not $Form.IsHandleCreated) { return }
    if ($Script:WindowActive) { return }
    try { [FlashHelper]::Flash($Form.Handle, [uint32]$Count) } catch { }
}

function Get-TargetScreen {
    # The screen WinForms would centre on (matches Form.CenterToScreen).
    #
    # PINNED DURING THE SELF-TEST, because this reads the MOUSE POSITION - and
    # a test whose answer depends on where somebody left the pointer is not a
    # test. On a machine with two displays at different scales the layout came
    # out 5px wider whenever the cursor happened to be on the other monitor,
    # which read as a real regression and was not one.
    if ($env:UTW_LAYOUT_SELFTEST) { return [System.Windows.Forms.Screen]::PrimaryScreen }
    try {
        $s = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        if ($s) { return $s }
    } catch { }
    return [System.Windows.Forms.Screen]::PrimaryScreen
}

function Get-SystemDpi {
    $dpi = 96.0
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        if ($g.DpiY -gt 0) { $dpi = [double]$g.DpiY }
        $g.Dispose()
    } catch { }
    return $dpi
}

function Initialize-DisplayScale {
    # Factor = the display's DPI scale, nothing else. Fitting the result to the
    # work area used to happen here against a hard-coded 700x1040 guess, which
    # went wrong the moment the layout changed size. It now happens in
    # Get-FittedScale, against the real form, once the layout exists.
    param([double]$MinScale = 0.65, [double]$MaxScale = 3.00)
    try {
        $dpi   = Get-SystemDpi
        $scale = $dpi / 96.0

        # Escape hatch for odd displays: UTW_UISCALE=1.25 forces the factor.
        $ovrRaw = if ($env:UTW_UISCALE) { $env:UTW_UISCALE } else { $env:USMT_UISCALE }  # old name still honoured
        if ($ovrRaw) {
            $ovr = 0.0
            if ([double]::TryParse($ovrRaw, [ref]$ovr) -and $ovr -ge 0.5 -and $ovr -le 3.0) {
                $scale = $ovr
                Write-CrashLog "Display: UTW_UISCALE override = $ovr"
            }
        }

        if ($scale -gt $MaxScale) { $scale = $MaxScale }
        if ($scale -lt $MinScale) { $scale = $MinScale }
        # Leave already-working displays completely alone
        if ([Math]::Abs($scale - 1.0) -lt 0.04) { $scale = 1.0 }

        $Script:UIScale = [Math]::Round($scale, 3)
        Write-CrashLog "Display: awareness=$($Script:DpiAwareness) dpi=$dpi -> scale=$($Script:UIScale)"
    } catch {
        $Script:UIScale = 1.0
        Write-CrashLog "Display scale detection failed, using 1.0: $($_.Exception.Message)"
    }
    return $Script:UIScale
}

function Get-FittedScale {
    # Largest factor at which the form's CLIENT design still fits the work area.
    # Measuring the chrome (title bar + borders) separately matters: it is drawn
    # at the system DPI and does NOT scale with $Factor, so at 175%+ it eats
    # 60-70px that a naive height-based fit would happily hand to the layout.
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Form,
        [double]$Desired  = 1.0,
        [double]$MinScale = 0.55
    )
    try {
        $cw = $Form.ClientSize.Width
        $ch = $Form.ClientSize.Height
        if ($cw -le 0 -or $ch -le 0) { return $Desired }

        $wa      = (Get-TargetScreen).WorkingArea
        $chromeW = [Math]::Max(0, $Form.Width  - $cw)
        $chromeH = [Math]::Max(0, $Form.Height - $ch)
        # 16px so the window is never flush against the work area edges
        $availW  = $wa.Width  - $chromeW - 16
        $availH  = $wa.Height - $chromeH - 16

        $fit = [Math]::Min(($availW / [double]$cw), ($availH / [double]$ch))
        $f   = [Math]::Min($Desired, $fit)
        if ($f -lt $MinScale) { $f = $MinScale }
        $f = [Math]::Round($f, 3)
        Write-CrashLog "Fit: client=${cw}x${ch} chrome=${chromeW}x${chromeH} avail=${availW}x${availH} fit=$([Math]::Round($fit,3)) desired=$Desired -> $f"
        return $f
    } catch {
        Write-CrashLog "Get-FittedScale failed: $($_.Exception.Message)"
        return $Desired
    }
}

function Set-ScaledFonts {
    # Converts every font in a control tree to PIXEL units, which pins text
    # height to the same coordinate space the layout was authored in.
    param([Parameter(Mandatory)]$Container, [double]$Factor = 1.0, [hashtable]$Cache)
    if (-not $Cache) { $Cache = @{} }

    $convert = {
        param($ctrl)
        $src = $ctrl.Font
        if ($null -eq $src) { return }
        if ($src.Unit -eq [System.Drawing.GraphicsUnit]::Pixel) { return }   # already converted
        $key = "{0}|{1}|{2}" -f $src.FontFamily.Name, $src.SizeInPoints, [int]$src.Style
        if (-not $Cache.ContainsKey($key)) {
            $px = [float]([Math]::Round($src.SizeInPoints * (96.0 / 72.0) * $Factor, 2))
            if ($px -lt 6) { $px = 6 }
            $Cache[$key] = New-Object System.Drawing.Font($src.FontFamily, $px, $src.Style, [System.Drawing.GraphicsUnit]::Pixel)
        }
        $ctrl.Font = $Cache[$key]
    }

    & $convert $Container
    foreach ($child in $Container.Controls) {
        & $convert $child
        if ($child.Controls.Count -gt 0) { Set-ScaledFonts -Container $child -Factor $Factor -Cache $Cache }
    }
}

function Set-FormScale {
    # Call AFTER all controls and anchors are set, BEFORE the form is shown.
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Form, [double]$Factor = 1.0)
    if ($null -eq $Form) { return }

    # LOAD-BEARING: with the WinForms default of AutoScaleMode.Font, changing
    # Form.Font fires an internal PerformAutoScale() that would apply a second
    # scale on top of the explicit Scale() below. This layout is fixed-pixel by
    # design and never wanted autoscaling in the first place.
    try { $Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None } catch { }

    $Form.SuspendLayout()
    try {
        if ([Math]::Abs($Factor - 1.0) -ge 0.005) {
            # Scale() walks the whole child tree: Location, Size, Padding, Margin
            $Form.Scale((New-Object System.Drawing.SizeF([float]$Factor, [float]$Factor)))
        }
        # Fonts are converted regardless of Factor - a 9.5pt font is oversized
        # for its box at 144 DPI whether or not the geometry was scaled.
        Set-ScaledFonts -Container $Form -Factor $Factor
    } catch {
        Write-CrashLog "Set-FormScale failed: $($_.Exception.Message)"
    } finally {
        $Form.ResumeLayout($true)
    }
}

function Get-ScaleForDpi {
    # The same arithmetic Initialize-DisplayScale does at startup, so a window
    # rescaled onto a display lands on exactly the factor it would have been
    # built at had it started there. A second copy of these numbers would be a
    # place for the two paths to disagree, which is why it is a function.
    param([double]$Dpi, [double]$MinScale = 0.65, [double]$MaxScale = 3.00)
    if ($Dpi -le 0) { return 1.0 }
    $scale = $Dpi / 96.0
    $ovrRaw = if ($env:UTW_UISCALE) { $env:UTW_UISCALE } else { $env:USMT_UISCALE }
    if ($ovrRaw) {
        $ovr = 0.0
        if ([double]::TryParse($ovrRaw, [ref]$ovr) -and $ovr -ge 0.5 -and $ovr -le 3.0) { $scale = $ovr }
    }
    if ($scale -gt $MaxScale) { $scale = $MaxScale }
    if ($scale -lt $MinScale) { $scale = $MinScale }
    if ([Math]::Abs($scale - 1.0) -lt 0.04) { $scale = 1.0 }
    return [Math]::Round($scale, 3)
}

function Get-TargetUiScale {
    # What the window should be scaled to right now: the display's own factor,
    # times the touch boost if it is on. One function so the startup path, the
    # touch toggle and the display watchdog cannot arrive at three answers.
    param([double]$Dpi)
    $s = (Get-ScaleForDpi $Dpi) * $Script:TouchBoost
    if ($s -gt 3.0) { $s = 3.0 }
    return [Math]::Round($s, 3)
}

function Get-DisplayDpi {
    <#
        The DPI of the monitor this window is actually on, right now.

        Not Get-SystemDpi: that answers "what was the DPI when this process
        started", which is the number that goes stale the moment an RDP session
        reconnects from a different machine. This one asks the monitor.
    #>
    param($Form)
    if ($Script:NativeHelpers -and $Form -and $Form.IsHandleCreated) {
        try {
            $d = [DpiHelper]::MonitorDpi($Form.Handle)
            if ($d -gt 0) { return [double]$d }
        } catch { }
    }
    return (Get-SystemDpi)
}

function Set-RescaledFonts {
    <#
        Multiplies every font in a tree by a ratio.

        Set-ScaledFonts cannot do this. It converts point fonts to pixel fonts
        and deliberately skips anything already in pixels, because running it
        twice at startup would scale the layout twice. After the first pass
        every font in the form is in pixels, so calling it again does nothing at
        all - which is precisely what a display change needs it to do. This is
        the second-pass version: no unit conversion, just a resize.
    #>
    param([Parameter(Mandatory)]$Container, [double]$Ratio)
    if ([Math]::Abs($Ratio - 1.0) -lt 0.005) { return }
    $cache = @{}
    $apply = {
        param($ctrl)
        $src = $ctrl.Font
        if ($null -eq $src) { return }
        if ($src.Unit -ne [System.Drawing.GraphicsUnit]::Pixel) { return }
        $px = [float]([Math]::Round($src.Size * $Ratio, 2))
        if ($px -lt 6) { $px = 6 }
        $key = "{0}|{1}|{2}" -f $src.FontFamily.Name, $px, [int]$src.Style
        if (-not $cache.ContainsKey($key)) {
            $cache[$key] = New-Object System.Drawing.Font($src.FontFamily, $px, $src.Style, [System.Drawing.GraphicsUnit]::Pixel)
        }
        $ctrl.Font = $cache[$key]
    }
    $walk = {
        param($c)
        & $apply $c
        foreach ($k in @($c.Controls)) { & $walk $k }
    }
    try { & $walk $Container } catch { Write-CrashLog "Set-RescaledFonts failed: $($_.Exception.Message)" }
}

function Invoke-DisplayRescale {
    <#
        Re-lays out the running window for a display it was not built for.

        THE PROBLEM THIS SOLVES. The layout is authored in fixed pixels and
        scaled exactly once, at startup, for the display that was attached then.
        Reconnecting an RDP session from a different machine changes the DPI
        underneath a window that has already been built, and until now the only
        cure was to close UTW and start it again - which in the middle of a
        migration means losing the log.

        HOW. Everything in the layout is either a scaled coordinate or a design
        constant multiplied by $Script:LayoutScale. So the whole window can be
        moved to a new scale by multiplying the first group by the ratio and
        changing the second number, then running the ordinary layout pass. The
        stretch baselines are multiplied rather than re-recorded: Save-StretchBase
        reads BaseX and BaseW off the controls, which is only correct before
        anything has been docked and stretched, and re-recording here would bake
        today's stretched width in as tomorrow's design width.
    #>
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Form,
        [Parameter(Mandatory)][double]$NewScale
    )
    $old = $Script:LayoutScale
    if ($old -le 0) { return $false }
    $ratio = $NewScale / $old
    if ([Math]::Abs($ratio - 1.0) -lt 0.01) { return $false }

    $Form.SuspendLayout()
    if ($Script:RedrawAvailable) { try { [RedrawHelper]::Suspend($Form.Handle) } catch { } }
    try {
        # MinimumSize would otherwise clamp the form on the way down, and it is
        # scaled by Scale() as well, so it is cleared and recomputed.
        $Form.MinimumSize = [System.Drawing.Size]::Empty
        $Form.Scale((New-Object System.Drawing.SizeF([float]$ratio, [float]$ratio)))
        Set-RescaledFonts -Container $Form -Ratio $ratio

        foreach ($e in $Script:StretchMap) {
            try {
                $e.BaseX = [int]($e.BaseX * $ratio)
                $e.BaseW = [int]($e.BaseW * $ratio)
                $e.BaseC = [int]($e.BaseC * $ratio)
            } catch { }
        }
        if ($Script:DetailsBaseWidth) { $Script:DetailsBaseWidth = [int]($Script:DetailsBaseWidth * $ratio) }

        $Script:UIScale    = [Math]::Round($NewScale, 3)
        $Script:LayoutScale = $Script:UIScale

        # Everything derived from the scale at startup, derived again.
        $wa = (Get-TargetScreen).WorkingArea
        $Script:SetupColumnWidth   = [int](($Script:SetupDesignWidth + 17) * $Script:UIScale)
        $Script:OutputMinHeight    = [int](70  * $Script:UIScale)
        $Script:MinFormHeight      = [int](520 * $Script:UIScale)
        $Script:DefaultFormWidth   = [Math]::Min($Form.Width,  $wa.Width)
        $Script:ExpandedFormHeight = [Math]::Min($Form.Height, $wa.Height)

        # The window itself must still fit the screen it has moved to. Coming
        # off a 4K monitor onto a laptop this is the difference between a usable
        # window and one whose buttons are past the bottom edge.
        $Form.Size = New-Object System.Drawing.Size(
            [Math]::Min($Form.Width,  $wa.Width),
            [Math]::Min($Form.Height, $wa.Height))
        if ($Form.Left -lt $wa.Left -or $Form.Top -lt $wa.Top -or
            $Form.Right -gt $wa.Right -or $Form.Bottom -gt $wa.Bottom) {
            $Form.Location = New-Object System.Drawing.Point(
                [Math]::Max($wa.Left, [Math]::Min($Form.Left, $wa.Right  - $Form.Width)),
                [Math]::Max($wa.Top,  [Math]::Min($Form.Top,  $wa.Bottom - $Form.Height)))
        }

        # RE-MEASURED, NOT MULTIPLIED.
        #
        # Set-FieldButtonFit sizes a button to its text plus a fixed 20px pad.
        # Multiplying that result by the ratio scales the pad along with the
        # text, which is not what the same button would be if it had been built
        # at this scale - measured against a natively-built 1.5 window the
        # Browse button came out 13px too wide, and it was the only control in
        # the layout that did. Anything sized by measurement has to be measured
        # again, at the new font.
        Set-FieldButtonFit
        Update-Layout
        Set-SplitterLayout
        Update-Stretch
        Write-CrashLog "Display changed: rescaled $old -> $($Script:UIScale)"
        return $true
    } catch {
        Write-CrashLog "Invoke-DisplayRescale failed: $($_.Exception.Message)"
        return $false
    } finally {
        $Form.ResumeLayout($true)
        if ($Script:RedrawAvailable) { try { [RedrawHelper]::Resume($Form.Handle, $true) } catch { } }
    }
}

function Set-DesignBounds {
    <#
        Moves or resizes a control using DESIGN pixels - the same 1.0-scale
        coordinate system the whole layout above is authored in.

        LOAD-BEARING for anything that runs AFTER the layout pass. The layout is
        written at 1.0 and scaled exactly once by Set-FormScale; a raw
        New-Object Point(335, 88) assigned later lands at design coordinates
        inside an already-scaled form, i.e. at ~4/7 of where it belongs on a
        175% display. That is how the destination box came to be drawn on top of
        the username field, with its label over the box beside it.

        Width/Height are optional and independent: a single-line TextBox derives
        its own height from the font, so passing -Width alone keeps the height
        the scaling pass already settled on instead of fighting it.
    #>
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Control,
        [int]$X = -1, [int]$Y = -1, [int]$Width = -1, [int]$Height = -1
    )
    $f = $Script:LayoutScale
    if ($f -le 0) { $f = 1.0 }
    if ($X -ge 0 -and $Y -ge 0) {
        $Control.Location = New-Object System.Drawing.Point(
            [int][Math]::Round($X * $f), [int][Math]::Round($Y * $f))
    }
    if ($Width -ge 0) {
        $h = if ($Height -ge 0) { [int][Math]::Round($Height * $f) } else { $Control.Height }
        $Control.Size = New-Object System.Drawing.Size([int][Math]::Round($Width * $f), $h)
    }
}

function Set-DoubleBuffered {
    <#
        Turns on double buffering for a control and everything under it.

        This is the fix for choppy resizing. Dragging a divider re-lays out
        several hundred controls, and by default each one paints straight to the
        screen as it is moved - so the window is redrawn piece by piece and the
        eye sees it tear. Double buffering paints the whole thing off-screen and
        blits it once.

        DoubleBuffered is a PROTECTED property, so it cannot be set from
        PowerShell the ordinary way; reflection is the only route. Wrapped in
        try/catch throughout because a failure here is purely cosmetic and must
        never stop a window from opening.
    #>
    param([System.Windows.Forms.Control]$Control, [int]$Depth = 0)
    if (-not $Control -or $Depth -gt 12) { return }
    # The PropertyInfo is looked up ONCE and cached. This walks 200+ controls,
    # and a reflection lookup per control is most of what the walk costs.
    if (-not $Script:DoubleBufferProp) {
        try {
            $Script:DoubleBufferProp = [System.Windows.Forms.Control].GetProperty(
                "DoubleBuffered",
                [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        } catch { }
    }
    if ($Script:DoubleBufferProp) {
        try { $Script:DoubleBufferProp.SetValue($Control, $true, $null) } catch { }
    }
    foreach ($child in $Control.Controls) { Set-DoubleBuffered -Control $child -Depth ($Depth + 1) }
}

function Set-RealBounds {
    <#
        Set-DesignBounds' sibling, for placement that is PART design and part
        measured.

        Set-DesignBounds multiplies a design coordinate by the layout scale,
        which is right when a panel is always its design width. The panels are
        resizable now, so a row has to be laid out from design proportions PLUS
        however many extra pixels the panel has been given - and that extra is a
        measured number, already in real pixels, that must not be scaled again.
        Callers do the arithmetic in real pixels and hand the result here.
    #>
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Control,
        [int]$X = -1, [int]$Y = -1, [int]$Width = -1, [int]$Height = -1
    )
    if ($X -ge 0 -and $Y -ge 0) { $Control.Location = New-Object System.Drawing.Point($X, $Y) }
    if ($Width -ge 0) {
        $h = if ($Height -ge 0) { $Height } else { $Control.Height }
        $Control.Size = New-Object System.Drawing.Size([Math]::Max(8, $Width), $h)
    }
}

function Get-FormWorkArea {
    param([System.Windows.Forms.Form]$Form)
    try {
        if ($Form -and -not $Form.IsDisposed -and $Form.IsHandleCreated) {
            return [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
        }
    } catch { }
    return (Get-TargetScreen).WorkingArea
}

function Set-FormMinimumSize {
    # Minimum height = the collapsed layout, plus a readable slice of the output
    # box while it is expanded, so dragging the window smaller can never squeeze
    # the output panel down to nothing. Always clamped to the work area - the
    # earlier version locked the minimum above the screen height and made the
    # bottom of the window permanently unreachable.
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Form)
    try {
        $wa = Get-FormWorkArea $Form
        # There is no collapsed state any more - the splitter handles it - so
        # the minimum is simply enough of the window to stay usable.
        $h  = if ($Script:MinFormHeight) { $Script:MinFormHeight } else { 520 }
        $h  = [Math]::Max(200, [Math]::Min($h, $wa.Height))
        $w  = [Math]::Max(320, [Math]::Min($Script:DefaultFormWidth, $wa.Width))
        $Form.MinimumSize = New-Object System.Drawing.Size($w, $h)
    } catch {
        Write-CrashLog "Set-FormMinimumSize failed: $($_.Exception.Message)"
    }
}

function Set-FormWithinWorkArea {
    # Clamps a form to the usable desktop and places it fully on screen.
    # Replaces StartPosition=CenterScreen, which pushes the bottom of a nearly
    # full-height window under the taskbar.
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Form, [switch]$KeepPosition)
    try {
        $wa = Get-FormWorkArea $Form
        # MinimumSize vetoes a shrink, so stand it down for the duration.
        $min = $Form.MinimumSize
        $Form.MinimumSize = [System.Drawing.Size]::Empty
        if ($Form.Width  -gt $wa.Width)  { $Form.Width  = $wa.Width }
        if ($Form.Height -gt $wa.Height) { $Form.Height = $wa.Height }
        $Form.MinimumSize = New-Object System.Drawing.Size(
            [Math]::Min($min.Width,  $wa.Width),
            [Math]::Min($min.Height, $wa.Height))

        if ($KeepPosition) {
            # Nudge back on screen without teleporting a window the user placed.
            $x = [Math]::Min([Math]::Max($Form.Left, $wa.Left), ($wa.Right  - $Form.Width))
            $y = [Math]::Min([Math]::Max($Form.Top,  $wa.Top),  ($wa.Bottom - $Form.Height))
        } else {
            $Form.StartPosition = "Manual"
            $x = $wa.Left + [Math]::Max(0, [int](($wa.Width  - $Form.Width)  / 2))
            $y = $wa.Top  + [Math]::Max(0, [int](($wa.Height - $Form.Height) / 2))
        }
        $Form.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
    } catch {
        Write-CrashLog "Set-FormWithinWorkArea failed: $($_.Exception.Message)"
    }
}

Initialize-DisplayScale | Out-Null
#endregion

# Dot-source helper modules
foreach ($module in @("UTW-Themes.ps1", "UTW-Logic.ps1")) {
    $mp = Join-Path $Script:ScriptDir $module
    if (Test-Path $mp) { . $mp }
    else {
        [System.Windows.Forms.MessageBox]::Show("Required file not found:`n$mp`n`nAll .ps1 files must be in the same folder.", "Missing Module", "OK", "Error")
        exit 1
    }
}
# xaml\ may be a sibling of Core\ rather than inside it. UTW-Themes.ps1 guessed
# beside itself; correct it now that Get-UTWResource is available.
$xamlDir = Get-UTWResource 'xaml'
if ($xamlDir) { $Script:XamlRoot = $xamlDir }
Write-CrashLog "Boot: modules loaded at $($Script:BootClock.ElapsedMilliseconds) ms; xaml=$Script:XamlRoot"

#region ==================== UNICODE / DIALOG ====================
$Script:ArrowDown   = [string][char]0x25BC
$Script:ArrowUp     = [string][char]0x25B2
$Script:ArrowRight  = [string][char]0x25B6
$Script:CheckMark   = [string][char]0x2713
$Script:WarningSign = [string][char]0x26A0

# WHAT THE LOOKUP LIST CAN SHOW.
#
# One definition per column, each carrying its own header, width and the
# function that produces its cell. Everything that builds the list reads this,
# so turning a column off is a filter here rather than a renumbering everywhere
# else - which is the mistake that put the Clean Up dialog's blocked rows one
# column out when "First created" was added.
#
# "user" is not optional: a list of profiles with no profile name in it is not a
# list of anything.
$Script:BrowseColumnDefs = @(
    @{ Key = "user";     Text = "User";           Width = 140; Fixed = $true
       Value = { param($p) "$($p.Leaf)" } }
    @{ Key = "modified"; Text = "Last modified";  Width = 105
       Value = { param($p) Format-ProfileDate $p.LastUse } }
    @{ Key = "created";  Text = "First created";  Width = 95
       Value = { param($p) Format-ProfileDate $p.Created } }
    @{ Key = "signedin"; Text = "Signed in";      Width = 75
       Value = { param($p) if ($p.Orphan) { "no account" } elseif ($p.Loaded) { "yes" } else { "" } } }
    @{ Key = "account";  Text = "Account";        Width = 150
       Value = { param($p) "$($p.Account)" } }
    @{ Key = "folder";   Text = "Profile folder"; Width = 235
       Value = { param($p) "$($p.Path)" } }
)
# The set shown out of the box. "account" is off by default because it repeats
# the user name on the machines where the SID resolves, which is most of them.
$Script:BrowseColumns = @("user", "modified", "created", "signedin", "folder")

function Get-BrowseColumns {
    # The chosen columns, in definition order, with the fixed one guaranteed.
    # Definition order rather than chosen order so the list cannot come back
    # scrambled from a settings file somebody edited by hand.
    $want = @($Script:BrowseColumns)
    $out = @()
    foreach ($d in $Script:BrowseColumnDefs) {
        if ($d.Fixed -or ($want -contains $d.Key)) { $out += $d }
    }
    if (-not $out.Count) { $out = @($Script:BrowseColumnDefs[0]) }
    # NO LEADING COMMA HERE, and that is the opposite of Get-UsernameList.
    #
    # The comma exists to stop PowerShell unrolling a one-element result into a
    # scalar - which is exactly what Get-UsernameList needs, because its caller
    # takes [0] directly. This function's callers write @(Get-BrowseColumns),
    # and @() around an already-nested array yields ONE element containing the
    # whole thing: five columns collapsed into a single header reading
    # "User Last modified First created Signed in Profile folder".
    #
    # So the rule is about the CALLER, not the function. Here @() at the call
    # site does the protecting, and the comma would undo it.
    return @($out)
}
function Format-ProfileDate {
    <#
        The date itself, for the column.

        A column of "412 days ago" and "38 days ago" is arithmetic the reader has
        to do twice - once to work out when that was, and again to compare two
        rows. A date needs neither. yyyy-MM-dd rather than the local short date
        because it cannot be misread the other way round, it is the same width on
        every row, and it sorts correctly as text.

        "unknown" is a real answer and it is said plainly. NTUSER.DAT is readable
        only with administrative rights, so an ordinary run legitimately cannot
        date most profiles - and the old code filled that gap with the folder
        timestamp and then LastUseTime, which is exactly how profiles nobody had
        touched in months came to read "0 days ago". A blank where there is no
        evidence is worth more than a number that looks like one.
    #>
    param($When)
    if (-not $When) { return "unknown" }
    try { return ([datetime]$When).ToString("yyyy-MM-dd") } catch { return "unknown" }
}

function Format-ProfileAge {
    <#
        How long ago that was, in words, for the hover.

        The elapsed time is what actually answers "is this profile stale", so it
        is not thrown away - it moves to the tooltip, where it costs no column
        width. Years and months once it is past a month, because "412 days ago"
        is not a duration anybody reads at a glance.
    #>
    param([int]$Days)
    if ($Days -lt 0)  { return "unknown" }
    if ($Days -eq 0)  { return "today" }
    if ($Days -eq 1)  { return "yesterday" }
    if ($Days -lt 31) { return "$Days days ago" }

    $years  = [int][math]::Floor($Days / 365)
    $rest   = $Days - ($years * 365)
    $months = [int][math]::Floor($rest / 30)
    $rest   = $rest - ($months * 30)

    $parts = @()
    if ($years  -gt 0) { $parts += "$years year$(if ($years -ne 1) { 's' })" }
    if ($months -gt 0) { $parts += "$months month$(if ($months -ne 1) { 's' })" }
    # Days only when there are no years to dwarf them - "2 years, 1 month and 4
    # days" is precision nobody asked for.
    if ($rest -gt 0 -and $years -eq 0) { $parts += "$rest day$(if ($rest -ne 1) { 's' })" }
    if (-not $parts.Count) { $parts = @("$Days days") }
    return (($parts -join ", ") + " ago")
}

function Set-ProfileDateColumns {
    <#
        Widens the two date columns to fit, once the rows are in.

        A ListView column is whatever width it was given, and a header reading
        "Last modif..." is the sort of thing that only shows up on somebody
        else's display. -2 measures the header, -1 measures the widest row, and
        the column needs whichever is bigger. What that reclaims is handed to the
        folder column so the total still fills the list.
    #>
    param([System.Windows.Forms.ListView]$List, [int[]]$Columns, [int]$Absorb)
    $freed = 0
    foreach ($i in $Columns) {
        if ($i -ge $List.Columns.Count) { continue }
        $was = $List.Columns[$i].Width
        $List.Columns[$i].Width = -1; $byRows   = $List.Columns[$i].Width
        $List.Columns[$i].Width = -2; $byHeader = $List.Columns[$i].Width
        # A little air, or the last character sits against the divider.
        $want = ([math]::Max($byRows, $byHeader)) + 8
        $List.Columns[$i].Width = $want
        $freed += ($was - $want)
    }
    if ($Absorb -ge 0 -and $Absorb -lt $List.Columns.Count -and $freed -ne 0) {
        $List.Columns[$Absorb].Width = [math]::Max(80, $List.Columns[$Absorb].Width + $freed)
    }
}

function Show-ProgramCompareDialog {
    <#
        The curated list: what the new machine is missing, grouped so it reads
        as a to-do rather than a data dump.

        THREE SECTIONS, IN ORDER OF HOW MUCH THEY MEAN. Programs that are simply
        not there is the answer to the question. A different version is worth
        knowing and is usually fine. A folder on the root of C: is a hint that
        something else lives outside the installer's world - it is evidence, not
        a finding, and it is labelled that way.
    #>
    param($Result)
    $t = $Script:T
    $W = 900; $H = 600; $pad = 16
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Installed programs - $($Result.OldPC) compared with $($Result.NewPC)"
    $dlg.FormBorderStyle = "Sizable"; $dlg.MaximizeBox = $true; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"; $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.ClientSize = New-Object System.Drawing.Size($W, $H)

    $fTitle = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $fBody  = New-Object System.Drawing.Font("Segoe UI", 9)

    $miss = @($Result.Missing).Count
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = if ($miss -eq 0) { "$($Result.NewPC) has everything $($Result.OldPC) had" }
                else { "$miss program(s) on $($Result.OldPC) are not installed on $($Result.NewPC)" }
    $lbl.Font = $fTitle; $lbl.ForeColor = if ($miss -eq 0) { $t.Success } else { $t.Primary }
    $lbl.AutoSize = $false; $lbl.Location = New-Object System.Drawing.Point($pad, $pad)
    $lbl.Size = New-Object System.Drawing.Size(($W - 2*$pad), 24)
    $dlg.Controls.Add($lbl)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = "USMT moves files and settings, never applications - so this list is what somebody has to install by hand. $($Result.SameCount) program(s) match on both machines. Read from the uninstall registry, the same place Programs and Features reads."
    $sub.Font = $fBody; $sub.ForeColor = $t.TextDim
    $sub.AutoSize = $false; $sub.Location = New-Object System.Drawing.Point($pad, ($pad + 26))
    $sub.Size = New-Object System.Drawing.Size(($W - 2*$pad), 40)
    $dlg.Controls.Add($sub)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.MultiSelect = $true
    $lv.HideSelection = $false; $lv.HeaderStyle = "Nonclickable"; $lv.ShowItemToolTips = $true
    $lv.Font = $fBody; $lv.BackColor = $t.MedBg; $lv.ForeColor = $t.Text
    $lv.Location = New-Object System.Drawing.Point($pad, ($pad + 70))
    $lv.Size = New-Object System.Drawing.Size(($W - 2*$pad), ($H - $pad*3 - 70 - 34))
    $lv.Anchor = "Top,Left,Right,Bottom"
    [void]$lv.Columns.Add("Program or folder", 380)
    [void]$lv.Columns.Add("Version on $($Result.OldPC)", 150)
    [void]$lv.Columns.Add("Publisher", 220)
    [void]$lv.Columns.Add("Installed for", 90)

    $addGroup = {
        param([string]$Heading, $Rows, $Colour)
        if (-not @($Rows).Count) { return }
        $h = New-Object System.Windows.Forms.ListViewItem($Heading)
        $h.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $h.ForeColor = $t.Primary
        [void]$lv.Items.Add($h)
        foreach ($p in @($Rows)) {
            $it = New-Object System.Windows.Forms.ListViewItem("    $($p.Name)")
            [void]$it.SubItems.Add("$($p.Version)")
            [void]$it.SubItems.Add("$($p.Publisher)")
            [void]$it.SubItems.Add("$($p.Scope)")
            $it.ForeColor = $Colour
            [void]$lv.Items.Add($it)
        }
    }

    & $addGroup "NOT INSTALLED on $($Result.NewPC)  -  $miss" $Result.Missing $t.Warning

    $diffRows = @()
    foreach ($d in @($Result.Differs)) {
        $diffRows += @{ Name = "$($d.Name)   ($($Result.NewPC) has $($d.OtherVersion))"
                        Version = $d.Version; Publisher = $d.Publisher; Scope = $d.Scope }
    }
    & $addGroup "Installed, but a different version  -  $(@($diffRows).Count)" $diffRows $t.Text

    $folderRows = @()
    foreach ($f in @($Result.MissingFolders)) {
        $folderRows += @{ Name = $f.Path; Version = ""; Publisher = "folder on the root of C:"; Scope = "" }
    }
    # Deliberately last and dimmed. A folder is a clue that some software keeps
    # its data outside Program Files - worth a look, not a conclusion.
    & $addGroup "On the root of C: and not on $($Result.NewPC)  -  $(@($folderRows).Count)" $folderRows $t.TextDim

    if (-not $lv.Items.Count) {
        $it = New-Object System.Windows.Forms.ListViewItem("Nothing to install - the two machines match.")
        $it.ForeColor = $t.Success
        [void]$lv.Items.Add($it)
    }
    $dlg.Controls.Add($lv)

    $y = $H - $pad - 30
    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy list"; $btnCopy.Font = $fBody
    $btnCopy.Size = New-Object System.Drawing.Size(110, 30)
    $btnCopy.Location = New-Object System.Drawing.Point($pad, $y)
    $btnCopy.FlatStyle = "Flat"; $btnCopy.BackColor = $t.MedBg; $btnCopy.ForeColor = $t.Text
    $btnCopy.Anchor = "Bottom,Left"
    # The point of the list is usually to act on it somewhere else - a ticket, a
    # handover note, a message to whoever installs the software.
    $btnCopy.Add_Click({
        $lines = @("Programs on $($Result.OldPC) missing from $($Result.NewPC):")
        foreach ($p in @($Result.Missing)) { $lines += "  $($p.Name)  $($p.Version)" }
        if (@($Result.MissingFolders).Count) {
            $lines += ""; $lines += "Folders on the root of C: worth checking:"
            foreach ($f in @($Result.MissingFolders)) { $lines += "  $($f.Path)" }
        }
        try { [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n")) } catch { }
    }.GetNewClosure())
    $dlg.Controls.Add($btnCopy)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $fBody
    $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.Location = New-Object System.Drawing.Point(($W - $pad - 100), $y)
    $btnClose.FlatStyle = "Flat"; $btnClose.BackColor = $t.MedBg; $btnClose.ForeColor = $t.Text
    $btnClose.Anchor = "Bottom,Right"
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.Controls.Add($btnClose)

    Set-FormScale -Form $dlg -Factor $Script:UIScale
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
}
function Show-ProfileMatchDialog {
    <#
        "There is no alicew on the new PC - is this the same person?"

        Asked rather than guessed. The scoring puts the likely answer at the
        top, but choosing it automatically would mean copying one person's
        documents into another person's profile on nothing but a shared prefix,
        and that is not a mistake anybody would spot until much later.
    #>
    param([string]$SourceUser, [string]$SourcePC, [string]$DestPC, $Ranked)
    $t = $Script:T
    $W = 520; $H = 380; $pad = 16
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Which profile is the same person?"
    $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"; $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.ClientSize = New-Object System.Drawing.Size($W, $H)

    $fTitle = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $fBody  = New-Object System.Drawing.Font("Segoe UI", 9)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "'$SourceUser' on $SourcePC"
    $lbl.Font = $fTitle; $lbl.ForeColor = $t.Primary
    $lbl.AutoSize = $false; $lbl.Location = New-Object System.Drawing.Point($pad, $pad)
    $lbl.Size = New-Object System.Drawing.Size(($W - 2*$pad), 24)
    $dlg.Controls.Add($lbl)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = "There is no profile with that name on $DestPC. Pick the one that belongs to the same person - the closest matches are first. Nothing is copied until you confirm the file list on the next screen."
    $sub.Font = $fBody; $sub.ForeColor = $t.TextDim
    $sub.AutoSize = $false; $sub.Location = New-Object System.Drawing.Point($pad, ($pad + 26))
    $sub.Size = New-Object System.Drawing.Size(($W - 2*$pad), 52)
    $dlg.Controls.Add($sub)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
    $lv.HideSelection = $false; $lv.HeaderStyle = "Nonclickable"
    $lv.Font = $fBody; $lv.BackColor = $t.MedBg; $lv.ForeColor = $t.Text
    $lv.Location = New-Object System.Drawing.Point($pad, ($pad + 84))
    $lv.Size = New-Object System.Drawing.Size(($W - 2*$pad), 210)
    [void]$lv.Columns.Add("Profile on $DestPC", 300)
    [void]$lv.Columns.Add("How close", 160)
    foreach ($r in @($Ranked)) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
        # Words, not the raw score. "83" invites the reader to treat a guess as
        # a measurement.
        $how = if     ($r.Score -ge 100) { "the same name" }
               elseif ($r.Score -ge 70)  { "very similar" }
               elseif ($r.Score -ge 40)  { "somewhat similar" }
               else                      { "no resemblance" }
        [void]$it.SubItems.Add($how)
        if ($r.Score -lt 40) { $it.ForeColor = $t.TextDim }
        $it.Tag = $r.Name
        [void]$lv.Items.Add($it)
    }
    if ($lv.Items.Count) { $lv.Items[0].Selected = $true }
    $dlg.Controls.Add($lv)

    $state = @{ Result = $null }
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Compare these two"; $btnOk.Font = $fBody
    $btnOk.Size = New-Object System.Drawing.Size(150, 30)
    $btnOk.Location = New-Object System.Drawing.Point(($W - $pad - 150), ($H - $pad - 30))
    $btnOk.FlatStyle = "Flat"; $btnOk.BackColor = $t.MedBg; $btnOk.ForeColor = $t.Text
    $btnOk.Add_Click({
        if ($lv.SelectedItems.Count) { $state.Result = $lv.SelectedItems[0].Tag }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.Controls.Add($btnOk)

    $btnNo = New-Object System.Windows.Forms.Button
    $btnNo.Text = "Cancel"; $btnNo.Font = $fBody
    $btnNo.Size = New-Object System.Drawing.Size(100, 30)
    $btnNo.Location = New-Object System.Drawing.Point(($W - $pad - 260), ($H - $pad - 30))
    $btnNo.FlatStyle = "Flat"; $btnNo.BackColor = $t.MedBg; $btnNo.ForeColor = $t.Text
    $btnNo.Add_Click({ $state.Result = $null; $dlg.Close() }.GetNewClosure())
    $dlg.Controls.Add($btnNo)

    Set-FormScale -Form $dlg -Factor $Script:UIScale
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return $state.Result
}

function Show-CatchUpDialog {
    <#
        The review step. Every difference, ticked or not, with the newest first.

        NOTHING IS TICKED TO START WITH, the same rule the profile deletion
        dialog follows. This overwrites files in a working profile, and a dialog
        that arrives pre-armed with 400 ticks is one Enter away from doing
        something nobody read.
    #>
    param($Comparison, [string]$OldPC, [string]$NewPC)
    $t = $Script:T
    $W = 860; $H = 560; $pad = 16
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Compare & Sync - review"
    $dlg.FormBorderStyle = "Sizable"; $dlg.MaximizeBox = $true; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"; $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.ClientSize = New-Object System.Drawing.Size($W, $H)

    $fTitle = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $fBody  = New-Object System.Drawing.Font("Segoe UI", 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$(@($Comparison.Items).Count) file(s) on $OldPC that $NewPC has not got, or has an older copy of"
    $lbl.Font = $fTitle; $lbl.ForeColor = $t.Primary
    $lbl.AutoSize = $false; $lbl.Location = New-Object System.Drawing.Point($pad, $pad)
    $lbl.Size = New-Object System.Drawing.Size(($W - 2*$pad), 24)
    $dlg.Controls.Add($lbl)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = "From  $($Comparison.Source)`r`nTo      $($Comparison.Dest)`r`nTicked files are copied to the new PC, overwriting what is there. Nothing is ticked to start with. Files the new PC already has a NEWER copy of are not listed at all - those are changes made after the move and are left alone."
    $sub.Font = $fBody; $sub.ForeColor = $t.TextDim
    $sub.AutoSize = $false; $sub.Location = New-Object System.Drawing.Point($pad, ($pad + 26))
    $sub.Size = New-Object System.Drawing.Size(($W - 2*$pad), 62)
    $dlg.Controls.Add($sub)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.CheckBoxes = $true
    $lv.HideSelection = $false; $lv.HeaderStyle = "Nonclickable"
    $lv.Font = $fBody; $lv.BackColor = $t.MedBg; $lv.ForeColor = $t.Text
    $lv.Location = New-Object System.Drawing.Point($pad, ($pad + 92))
    $lv.Size = New-Object System.Drawing.Size(($W - 2*$pad), ($H - $pad*3 - 92 - 34))
    $lv.Anchor = "Top,Left,Right,Bottom"
    [void]$lv.Columns.Add("Change", 90)
    [void]$lv.Columns.Add("Size", 80)
    [void]$lv.Columns.Add("File", 620)
    foreach ($i in @($Comparison.Items)) {
        $what = if ($i.Class -eq "New File") { "not there" } else { "changed" }
        $it = New-Object System.Windows.Forms.ListViewItem($what)
        [void]$it.SubItems.Add((Format-Size ([double]$i.Bytes)))
        [void]$it.SubItems.Add($i.RelPath)
        # "changed" overwrites something; "not there" cannot. Only one of the
        # two can lose work, and it is the one worth colouring.
        if ($i.Class -ne "New File") { $it.ForeColor = $t.Warning }
        $it.Tag = $i
        [void]$lv.Items.Add($it)
    }
    $dlg.Controls.Add($lv)

    $y = $H - $pad - 30
    $state = @{ Result = $null }

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = "Tick all"; $btnAll.Font = $fBody
    $btnAll.Size = New-Object System.Drawing.Size(90, 30)
    $btnAll.Location = New-Object System.Drawing.Point($pad, $y)
    $btnAll.FlatStyle = "Flat"; $btnAll.BackColor = $t.MedBg; $btnAll.ForeColor = $t.Text
    $btnAll.Anchor = "Bottom,Left"
    $btnAll.Add_Click({ foreach ($i in $lv.Items) { $i.Checked = $true } }.GetNewClosure())
    $dlg.Controls.Add($btnAll)

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = "Tick none"; $btnNone.Font = $fBody
    $btnNone.Size = New-Object System.Drawing.Size(90, 30)
    $btnNone.Location = New-Object System.Drawing.Point(($pad + 96), $y)
    $btnNone.FlatStyle = "Flat"; $btnNone.BackColor = $t.MedBg; $btnNone.ForeColor = $t.Text
    $btnNone.Anchor = "Bottom,Left"
    $btnNone.Add_Click({ foreach ($i in $lv.Items) { $i.Checked = $false } }.GetNewClosure())
    $dlg.Controls.Add($btnNone)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy the ticked files"; $btnCopy.Font = $fBody
    $btnCopy.Size = New-Object System.Drawing.Size(170, 30)
    $btnCopy.Location = New-Object System.Drawing.Point(($W - $pad - 170), $y)
    $btnCopy.FlatStyle = "Flat"; $btnCopy.BackColor = $t.MedBg; $btnCopy.ForeColor = $t.Text
    $btnCopy.Anchor = "Bottom,Right"
    $btnCopy.Add_Click({
        $picked = @()
        foreach ($i in $lv.Items) { if ($i.Checked) { $picked += $i.Tag } }
        if (-not $picked.Count) {
            Show-ThemedMessage "Nothing is ticked, so there is nothing to copy." "Compare & Sync" "OK" "Information"
            return
        }
        $over = @($picked | Where-Object { $_.Class -ne "New File" }).Count
        $warn = if ($over -gt 0) { "`r`n`r`n$over of them will OVERWRITE a file that already exists on $NewPC." } else { "" }
        if ((Show-ThemedMessage "Copy $($picked.Count) file(s) to $NewPC?$warn" "Compare & Sync" "YesNo" "Warning") -ne "Yes") { return }
        $state.Result = $picked
        $dlg.Close()
    }.GetNewClosure())
    $dlg.Controls.Add($btnCopy)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"; $btnCancel.Font = $fBody
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(($W - $pad - 280), $y)
    $btnCancel.FlatStyle = "Flat"; $btnCancel.BackColor = $t.MedBg; $btnCancel.ForeColor = $t.Text
    $btnCancel.Anchor = "Bottom,Right"
    $btnCancel.Add_Click({ $state.Result = $null; $dlg.Close() }.GetNewClosure())
    $dlg.Controls.Add($btnCancel)

    Set-FormScale -Form $dlg -Factor $Script:UIScale
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return $state.Result
}
function Show-ThemedMessage {
    param([string]$Message, [string]$Title = "User Transfer Wizard", [string]$Buttons = "OK", [string]$Icon = "Information")
    $owner = $Script:MainForm
    if ($owner -and -not $owner.IsDisposed) { return [System.Windows.Forms.MessageBox]::Show($owner, $Message, $Title, $Buttons, $Icon) }
    else { return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon) }
}

function Show-ChoiceDialog {
    <#
        A themed "pick one" prompt.

        MessageBox can only offer Yes/No/Cancel, which pushes the meaning of
        every option into the message body and leaves the operator to work out
        that "Yes" means "exclude OneDrive". Here each option is a full-width
        button that says what it does, with a dim line underneath saying what it
        costs. Used for the decisions that are not yes/no: what to do about a
        OneDrive profile, and what to remove during a clean up.

        $Choices is an array of hashtables:
            @{ Key="Exclude"; Text="Exclude OneDrive folders"
               Hint="Fastest..."; Accent=$Script:AccentCyan; IsCancel=$false }

        Returns the Key of the option clicked. Escape, Alt+F4 and the close box
        all return the Key marked IsCancel (or "Cancel" if none is).
    #>
    param(
        [Parameter(Mandatory)][string]$Heading,
        [Parameter(Mandatory)][array]$Choices,
        [string]$Message = "",
        [string]$Title = "User Transfer Wizard",
        [string]$Glyph = ""
    )
    $t = $Script:T
    $W = 560; $pad = 20; $inner = $W - (2 * $pad)
    $wrap = [System.Windows.Forms.TextFormatFlags]::WordBreak

    $fHead = New-UTWFont "Heading" ([System.Drawing.FontStyle]::Bold)
    $fBody = New-UTWFont "Base"
    $fBtn  = New-UTWFont "Base" ([System.Drawing.FontStyle]::Bold)
    $fHint = New-UTWFont "Small"

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"
    $dlg.ShowInTaskbar = $false
    # Fixed-pixel like the main form: authored at 1.0, scaled once at the end.
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    try { $dlg.Icon = New-AppIcon } catch { }

    $y = $pad

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text = $(if ($Glyph) { "$Glyph  $Heading" } else { $Heading })
    $lblHead.Font = $fHead; $lblHead.ForeColor = $t.Primary
    $lblHead.AutoSize = $false
    $hs = [System.Windows.Forms.TextRenderer]::MeasureText($lblHead.Text, $fHead, (New-Object System.Drawing.Size($inner, 0)), $wrap)
    $lblHead.Location = New-Object System.Drawing.Point($pad, $y)
    $lblHead.Size = New-Object System.Drawing.Size($inner, ($hs.Height + 2))
    $dlg.Controls.Add($lblHead)
    $y += $hs.Height + 10

    if ($Message) {
        $lblBody = New-Object System.Windows.Forms.Label
        $lblBody.Text = $Message; $lblBody.Font = $fBody; $lblBody.ForeColor = $t.Text
        $lblBody.AutoSize = $false
        $bs = [System.Windows.Forms.TextRenderer]::MeasureText($Message, $fBody, (New-Object System.Drawing.Size($inner, 0)), $wrap)
        $lblBody.Location = New-Object System.Drawing.Point($pad, $y)
        $lblBody.Size = New-Object System.Drawing.Size($inner, ($bs.Height + 2))
        $dlg.Controls.Add($lblBody)
        $y += $bs.Height + 16
    }

    # Closing the window is a decline, never a silent yes.
    $cancelKey = "Cancel"
    foreach ($c in $Choices) { if ($c.IsCancel) { $cancelKey = $c.Key } }
    # A hashtable, not a variable: the click handlers have to write somewhere
    # this function can still read afterwards, and assigning to a plain local
    # from inside a handler updates a copy in the handler's own scope.
    $state = @{ Result = $cancelKey }

    $first = $null; $cancelBtn = $null
    foreach ($c in $Choices) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $c.Text; $btn.Font = $fBtn
        $btn.FlatStyle = "Flat"; $btn.FlatAppearance.BorderSize = 0
        $btn.TextAlign = "MiddleLeft"
        $btn.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
        if ($c.Accent) { $btn.BackColor = $c.Accent; $btn.ForeColor = (Get-ContrastingText $c.Accent) }
        else           { $btn.BackColor = $t.MedBg;  $btn.ForeColor = $t.Text }
        $btn.Location = New-Object System.Drawing.Point($pad, $y)
        $btn.Size = New-Object System.Drawing.Size($inner, 36)
        # The key is carried on the control so one handler serves every button;
        # a closure over $c would capture the loop variable's final value.
        $btn.Tag = $c.Key
        $btn.Add_Click({ $state.Result = $this.Tag; $dlg.Close() })
        $dlg.Controls.Add($btn)
        if (-not $first) { $first = $btn }
        if ($c.IsCancel) { $cancelBtn = $btn }
        $y += 36 + 4

        if ($c.Hint) {
            $lblHint = New-Object System.Windows.Forms.Label
            $lblHint.Text = $c.Hint; $lblHint.Font = $fHint; $lblHint.ForeColor = $t.TextDim
            $lblHint.AutoSize = $false
            $ihs = [System.Windows.Forms.TextRenderer]::MeasureText($c.Hint, $fHint, (New-Object System.Drawing.Size(($inner - 12), 0)), $wrap)
            $lblHint.Location = New-Object System.Drawing.Point(($pad + 12), $y)
            $lblHint.Size = New-Object System.Drawing.Size(($inner - 12), ($ihs.Height + 2))
            $dlg.Controls.Add($lblHint)
            $y += $ihs.Height + 2
        }
        $y += 10
    }

    $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y - 10 + $pad))
    if ($first)     { $dlg.AcceptButton = $first }
    if ($cancelBtn) { $dlg.CancelButton = $cancelBtn }
    Set-FormScale -Form $dlg -Factor $Script:UIScale
    Set-DoubleBuffered -Control $dlg

    $owner = $Script:MainForm
    if ($owner -and -not $owner.IsDisposed) { [void]$dlg.ShowDialog($owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
    return $state.Result
}
function Show-InputDialog {
    <#
        One themed line of text in, or $null if cancelled. WinForms has no
        InputBox and the VB one is unthemed and unscaled, which in a dark theme
        looks like a different application.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Detail = "",
        [string]$Value = "",
        # Adds a Browse button that fills the box from a folder picker. A path
        # is the one kind of setting nobody should have to type or paste, and
        # the log folder is the one people change most often.
        [switch]$BrowseFolder
    )
    $t = $Script:T
    $W = 520; $pad = 16
    $fBody = New-UTWFont "Base"

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"; $dlg.ShowInTaskbar = $false
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    try { $dlg.Icon = New-AppIcon } catch { }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt; $lbl.Font = New-UTWFont "Base" ([System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $t.Text; $lbl.AutoSize = $false
    $lbl.Location = New-Object System.Drawing.Point($pad, $pad)
    $lbl.Size = New-Object System.Drawing.Size(($W - 2*$pad), 20)
    $dlg.Controls.Add($lbl)

    $y = $pad + 24
    if ($Detail) {
        $sub = New-Object System.Windows.Forms.Label
        $sub.Text = $Detail; $sub.Font = New-UTWFont "Small"
        $sub.ForeColor = $t.TextDim; $sub.AutoSize = $false
        $sub.Location = New-Object System.Drawing.Point($pad, $y)
        $sub.Size = New-Object System.Drawing.Size(($W - 2*$pad), 18)
        $dlg.Controls.Add($sub)
        $y += 22
    }

    $boxW = if ($BrowseFolder) { $W - (2 * $pad) - 96 } else { $W - (2 * $pad) }
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Font = $fBody; $txt.Text = $Value
    $txt.Location = New-Object System.Drawing.Point($pad, $y)
    $txt.Size = New-Object System.Drawing.Size($boxW, 26)
    $txt.BackColor = $t.MedBg; $txt.ForeColor = $t.Text; $txt.BorderStyle = "FixedSingle"
    $dlg.Controls.Add($txt)
    if ($BrowseFolder) {
        $browse = New-Object System.Windows.Forms.Button
        $browse.Text = "Browse..."; $browse.Font = New-UTWFont 9
        # Matched to the box beside it, like every other field button in the
        # tool: a single-line TextBox takes its height from its font and refuses
        # the 26 it was constructed with, so a button built at a fixed 28 is
        # taller than the field and sits a pixel above it. Both numbers come off
        # the real control, and the width comes off the word.
        # Also the standard size - but this dialog has NOT been scaled yet (it is
        # built, then Set-FormScale runs over the whole tree), so the published
        # pixel size is divided back out and the scale pass puts it right.
        if ($Script:StdBtnW -gt 0 -and $Script:UIScale -gt 0) {
            $browse.Width  = [int]($Script:StdBtnW / $Script:UIScale)
            $browse.Height = [int]($Script:StdBtnH / $Script:UIScale)
        } else {
            $browse.Width  = [System.Windows.Forms.TextRenderer]::MeasureText($browse.Text, $browse.Font).Width + 20
            $browse.Height = $txt.Height
        }
        $browse.Location = New-Object System.Drawing.Point(($pad + $boxW + 8), $txt.Top)
        $browse.FlatStyle = "Flat"; $browse.BackColor = $t.MedBg; $browse.ForeColor = $t.Text
        $dlg.Controls.Add($browse)
        $browse.Add_Click({
            $fd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fd.Description = "Choose a folder"
            $fd.ShowNewFolderButton = $true
            $cur = $txt.Text.Trim()
            if ($cur -and (Test-Path $cur -ErrorAction SilentlyContinue)) { $fd.SelectedPath = $cur }
            if ($fd.ShowDialog($dlg) -eq "OK") { $txt.Text = $fd.SelectedPath }
            $txt.Focus(); $txt.SelectionStart = $txt.TextLength
        })
    }
    $y += 36

    $state = @{ Result = $null }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "OK"; $ok.Font = New-UTWFont "Base" ([System.Drawing.FontStyle]::Bold)
    $ok.Location = New-Object System.Drawing.Point(($W - $pad - 220), $y)
    $ok.Size = New-Object System.Drawing.Size(105, 30)
    $ok.FlatStyle = "Flat"; $ok.FlatAppearance.BorderSize = 0
    $ok.BackColor = $t.Primary; $ok.ForeColor = (Get-ContrastingText $t.Primary)
    $dlg.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"; $cancel.Font = $fBody
    $cancel.Location = New-Object System.Drawing.Point(($W - $pad - 105), $y)
    $cancel.Size = New-Object System.Drawing.Size(105, 30)
    $cancel.FlatStyle = "Flat"; $cancel.BackColor = $t.MedBg; $cancel.ForeColor = $t.Text
    $dlg.Controls.Add($cancel)

    $ok.Add_Click({ $state.Result = $txt.Text; $dlg.Close() })
    $cancel.Add_Click({ $state.Result = $null; $dlg.Close() })
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 30 + $pad))
    Set-FormScale -Form $dlg -Factor $Script:UIScale
    Set-DoubleBuffered -Control $dlg
    $dlg.Add_Shown({ $txt.SelectAll(); $txt.Focus() })

    $owner = $Script:MainForm
    if ($owner -and -not $owner.IsDisposed) { [void]$dlg.ShowDialog($owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
    return $state.Result
}

function New-ListDialog {
    <#
        The shell every list-picking dialog in this tool shares: title, a
        ListView with columns, a status line and a button row, themed, scaled -
        and RESIZABLE.

        Everything here DOCKS rather than sitting at a fixed coordinate. The
        earlier version placed each piece absolutely, which is why the dialogs
        had to be FixedDialog: resizing one would have left the list at its
        original size in a bigger window with the buttons stranded in the
        middle. Docked regions - header at the top, buttons at the bottom, list
        filling what is left - resize for free, so the dialogs can now be
        dragged bigger and maximised, which is what you want on a list of forty
        stores or a long AD search.

        Returns @{ Form; List; Status; Header; State } for the caller to fill
        in. The caller owns the columns, the rows and the buttons; this owns the
        chrome. $Header is an empty panel between the subtitle and the list, for
        a caller that needs its own row of controls up there (the AD search).
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Heading,
        [int]$Width = 700,
        [int]$ListHeight = 260,
        [switch]$CheckBoxes,
        [string]$Subtitle = "",
        [int]$HeaderExtra = 0
    )
    $t = $Script:T
    $pad = 16
    $fHead = New-UTWFont "Heading" ([System.Drawing.FontStyle]::Bold)
    $fBody = New-UTWFont 9

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MaximizeBox = $true; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"; $dlg.ShowInTaskbar = $false
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    $dlg.Padding = New-Object System.Windows.Forms.Padding($pad, $pad, $pad, $pad)
    try { $dlg.Icon = New-AppIcon } catch { }

    # ---- the list, added FIRST so the docked edges win ----
    # Docking is resolved from the highest z-order down, and Controls.Add
    # appends, so anything that must claim an edge has to be added AFTER the
    # control that fills the middle.
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
    $lv.HideSelection = $false; $lv.HeaderStyle = "Nonclickable"
    $lv.CheckBoxes = [bool]$CheckBoxes
    $lv.Font = $fBody; $lv.BackColor = $t.MedBg; $lv.ForeColor = $t.Text
    $lv.Dock = "Fill"
    $dlg.Controls.Add($lv)

    # ---- bottom: status on the left, buttons on the right ----
    $pnlBottom = New-Object System.Windows.Forms.Panel
    $pnlBottom.Dock = "Bottom"; $pnlBottom.Height = 46
    $pnlBottom.BackColor = $t.DarkBg
    $dlg.Controls.Add($pnlBottom)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = ""; $status.Font = $fBody; $status.ForeColor = $t.TextDim
    $status.AutoSize = $false; $status.TextAlign = "MiddleLeft"; $status.AutoEllipsis = $true
    $status.Dock = "Fill"
    $pnlBottom.Controls.Add($status)

    # The buttons FLOW from the right edge; none of them has a coordinate.
    #
    # They were positioned absolutely and anchored right, and that is the same
    # captured-margin trap that has bitten this layout twice already: the button
    # row is docked, so at the moment a button is added it is still at the
    # form's default 300px width, the margin comes out hundreds of pixels
    # negative, and the buttons end up off the right-hand side once the dialog
    # reaches its real size. A FlowLayoutPanel has no margins to capture.
    # Added AFTER the status label so it claims the right edge first.
    $btnRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnRow.Dock = "Right"
    $btnRow.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $btnRow.WrapContents = $false
    $btnRow.AutoSize = $true
    $btnRow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $btnRow.BackColor = $t.DarkBg
    $pnlBottom.Controls.Add($btnRow)

    # ---- top: heading, optional subtitle, optional caller area ----
    $pnlTop = New-Object System.Windows.Forms.Panel
    $pnlTop.Dock = "Top"; $pnlTop.BackColor = $t.DarkBg
    $pnlTop.Height = 30 + $(if ($Subtitle) { 36 } else { 0 }) + $HeaderExtra
    $dlg.Controls.Add($pnlTop)

    # Added bottom-up inside the header for the same docking reason.
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = "Fill"; $header.BackColor = $t.DarkBg
    # The themed artwork behind a dialog's header, on the same switch as
    # everything else. A dialog is painted when it opens and then sits still, so
    # like the splash there is no per-frame cost to weigh - and it is what makes
    # a dialog look like part of the tool rather than a plain box on top of it.
    $header.Add_Paint({
        param($hs, $he)
        try {
            if (-not ($Script:UseXamlArt -and $Script:OverlayEnabled)) { return }
            $art = Get-XamlMaster -ThemeName $Script:CurrentThemeName -Surface "window" `
                    -W $hs.ClientSize.Width -H $hs.ClientSize.Height
            if (-not $art) { return }
            $he.Graphics.DrawImageUnscaled($art, 0, 0)
            # A dialog header carries a title and a subtitle, so it gets the same
            # wash the panels do rather than the banner's full strength.
            $vb = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb(150, $Script:T.DarkBg))
            try { $he.Graphics.FillRectangle($vb, 0, 0, $hs.ClientSize.Width, $hs.ClientSize.Height) }
            finally { $vb.Dispose() }
        } catch { }
    })
    $pnlTop.Controls.Add($header)

    if ($Subtitle) {
        $sub = New-Object System.Windows.Forms.Label
        $sub.Text = $Subtitle; $sub.Font = $fBody; $sub.ForeColor = $t.TextDim
        $sub.AutoSize = $false; $sub.Dock = "Top"; $sub.Height = 34
        $pnlTop.Controls.Add($sub)
    }
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Heading; $lbl.Font = $fHead; $lbl.ForeColor = $t.Primary
    $lbl.AutoSize = $false; $lbl.Dock = "Top"; $lbl.Height = 28
    $pnlTop.Controls.Add($lbl)

    return @{
        Form = $dlg; List = $lv; Status = $status
        Header = $header; ButtonRow = $btnRow
        Pad = $pad; Width = $Width; ListHeight = $ListHeight
        HeaderExtra = $HeaderExtra
        HasSubtitle = [bool]$Subtitle
        State = @{ Result = $null }
    }
}

function Add-DialogButton {
    param(
        [Parameter(Mandatory)][hashtable]$Dialog,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Right,      # distance from the dialog's right edge
        [int]$ButtonWidth = 110,
        [System.Drawing.Color]$Accent,
        [switch]$Primary
    )
    $t = $Script:T
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Font = if ($Primary) { New-UTWFont "Base" ([System.Drawing.FontStyle]::Bold) }
              else          { New-UTWFont 9 }
    $b.Size = New-Object System.Drawing.Size($ButtonWidth, 30)
    $b.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 8)
    $b.FlatStyle = "Flat"
    if ($Accent) { $b.FlatAppearance.BorderSize = 0; $b.BackColor = $Accent; $b.ForeColor = (Get-ContrastingText $Accent) }
    else         { $b.BackColor = $t.MedBg; $b.ForeColor = $t.Text }
    # The row flows RIGHT TO LEFT, so child index 0 is the rightmost slot.
    # Putting each new button at 0 preserves the order callers already write:
    # the last one added (Cancel / Close) ends up on the right, exactly where
    # the old $Right offsets put it. $Right stays in the signature because every
    # caller passes it, but the flow decides the position now - there is no
    # coordinate here to be captured against a not-yet-sized panel.
    $Dialog.ButtonRow.Controls.Add($b)
    $Dialog.ButtonRow.Controls.SetChildIndex($b, 0)
    return $b
}

function Show-ListDialog {
    # Finishes the shell: sizes the form, scales it, scales the ListView columns
    # (Form.Scale does not), makes the last column follow the width, shows it,
    # and returns whatever was chosen.
    param([Parameter(Mandatory)][hashtable]$Dialog)
    $d = $Dialog
    $h = $d.Pad + 28 + $(if ($d.HasSubtitle) { 36 } else { 0 }) + $d.HeaderExtra + $d.ListHeight + 46 + $d.Pad
    $d.Form.ClientSize = New-Object System.Drawing.Size($d.Width, $h)
    Set-FormScale -Form $d.Form -Factor $Script:UIScale
    Set-DoubleBuffered -Control $d.Form
    if ([Math]::Abs($Script:UIScale - 1.0) -ge 0.005) {
        foreach ($col in $d.List.Columns) { $col.Width = [int]($col.Width * $Script:UIScale) }
    }
    # Cannot be dragged smaller than the layout it was authored at.
    $d.Form.MinimumSize = New-Object System.Drawing.Size($d.Form.Width, $d.Form.Height)

    # The last column takes up any slack, so widening the dialog widens the
    # column most likely to be truncated (a path, a description) instead of
    # leaving a grey band down the right of the list.
    if ($d.List.Columns.Count -gt 0) {
        $Script:ListDialogFit = {
            param($lvSender)
            try {
                $used = 0
                for ($i = 0; $i -lt ($lvSender.Columns.Count - 1); $i++) { $used += $lvSender.Columns[$i].Width }
                $last = $lvSender.Columns[$lvSender.Columns.Count - 1]
                $room = $lvSender.ClientSize.Width - $used - 4
                if ($room -gt 60) { $last.Width = $room }
            } catch { }
        }
        $d.List.Add_Resize({ & $Script:ListDialogFit $this })
    }

    $owner = $Script:MainForm
    if ($owner -and -not $owner.IsDisposed) { [void]$d.Form.ShowDialog($owner) } else { [void]$d.Form.ShowDialog() }
    $d.Form.Dispose()
    return $d.State.Result
}

function Show-ComputerSearch {
    <#
        Find a machine in Active Directory instead of remembering its name.
        Searches name AND description, because half the estate is only ever
        identified by the note somebody left in the description field.
    #>
    param([string]$Seed = "")
    $t = $Script:T
    $d = New-ListDialog -Title "Find a computer" -Width 700 -ListHeight 240 -HeaderExtra 38 `
            -Heading "Search Active Directory" `
            -Subtitle "Searches computer names and descriptions. Type part of a name, or a room, or a person."
    $lv = $d.List
    [void]$lv.Columns.Add("Name", 150)
    [void]$lv.Columns.Add("Description", 220)
    [void]$lv.Columns.Add("OU", 130)
    [void]$lv.Columns.Add("Operating system", 160)

    # The search row sits in the space the shell reserved for it (-HeaderExtra),
    # so it cannot land on the subtitle and the list, the buttons and the form
    # height are all measured with it already accounted for. The previous
    # version placed this at a hard-coded y=62 - straight through the subtitle,
    # which is what made the top of this dialog look chopped off - and then
    # shuffled the ListView down afterwards, behind the shell's back.
    # The search row goes in the panel the shell reserved for it, and DOCKS
    # inside it: the button on the right, the box filling the rest. So the box
    # grows when the dialog is widened, and there is no coordinate here that can
    # drift out of step with the shell above it.
    # ADDED AFTER THE DIALOG WAS SCALED, so these controls must be built in
    # SCALED units - New-ListDialog runs Set-FormScale before it returns, and
    # Scale() only walks the tree that exists when it is called.
    #
    # That is why this row never matched the rest of the window whatever was done
    # to its numbers: a design-size font and a design-size strip sitting among
    # controls that had all been multiplied by the UI scale. Taking the font from
    # the dialog puts it back on the same footing as everything around it, and
    # every measurement below then comes out in the same units.
    $hdr = $d.Header
    $btnGo = New-Object System.Windows.Forms.Button
    $btnGo.Text = "Search"; $btnGo.Font = $d.Form.Font
    $btnGo.Dock = "Right"
    # Sized to its own word rather than to a round number, so it matches the
    # other field buttons instead of being the one oversized control in the tool.
    # The same size as List users and the USMT Browse button. These are already
    # in scaled pixels, and so is this dialog by the time the row is added.
    $btnGo.Width = if ($Script:StdBtnW -gt 0) { $Script:StdBtnW }
                   else { [System.Windows.Forms.TextRenderer]::MeasureText($btnGo.Text, $btnGo.Font).Width + 18 }
    $btnGo.FlatStyle = "Flat"; $btnGo.BackColor = $t.MedBg; $btnGo.ForeColor = $t.Text

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Font = $d.Form.Font          # scaled, like the button above
    $txt.Dock = "Fill"
    $txt.BackColor = $t.MedBg; $txt.ForeColor = $t.Text; $txt.BorderStyle = "FixedSingle"
    $txt.Text = $Seed

    # A one-row strip so the box and the button share a line and the rest of the
    # reserved height stays as breathing space.
    $row = New-Object System.Windows.Forms.Panel
    $row.Dock = "Top"; $row.Height = 30; $row.BackColor = $t.DarkBg
    # THE GAP IS A CONTROL, not a Margin.
    #
    # Dock ignores Margin - it only means anything inside a flow or table layout -
    # so the note that used to be here was wrong and Search sat welded to the box
    # it belongs to. A docked spacer is the thing Dock does respect.
    #
    # Order matters: docking resolves from the last control added backwards, so
    # the button must go in AFTER the spacer to end up outside it.
    $gap = New-Object System.Windows.Forms.Panel
    # Close enough to read as one control pair, far enough not to touch. 10
    # scaled up to 15px and read as a gap rather than a join.
    $gap.Dock = "Right"; $gap.Width = [Math]::Max(6, [int](6 * $Script:UIScale)); $gap.BackColor = $t.DarkBg
    $row.Controls.Add($txt)
    $row.Controls.Add($gap)
    $row.Controls.Add($btnGo)
    $hdr.Controls.Add($row)
    # THE STRIP TAKES THE BOX'S HEIGHT - its actual laid-out height, not its
    # PreferredHeight, which is why the row is laid out first.
    #
    # A single-line TextBox clamps itself to what its font needs and ignores
    # being docked taller; the button docked beside it stretches to the whole
    # strip. So any strip taller than the box - from PreferredHeight, or from
    # taking the larger of the two - leaves a short box beside a tall button
    # hanging below it. Matching the box is safe because a field is always
    # taller than the words in it, and the button centres its text in whatever
    # height it gets. Same rule as the main window's field buttons.
    $row.PerformLayout()
    if ($txt.Height -gt 0) { $row.Height = $txt.Height }

    $btnUse    = Add-DialogButton -Dialog $d -Text "Use this PC" -Right 132 -ButtonWidth 118 -Accent $t.Primary -Primary
    $btnCancel = Add-DialogButton -Dialog $d -Text "Cancel" -Right 16 -ButtonWidth 108
    $btnUse.Enabled = $false

    # Distinct locals rather than reaching through $d inside the handlers. These
    # scriptblocks run when a button is pressed, long after this function's
    # frame stopped being the active one, and a one-letter name is exactly what
    # something else in the call chain is most likely to be using too.
    $frm    = $d.Form
    $status = $d.Status
    $state  = $d.State

    $doSearch = {
        $q = $txt.Text.Trim()
        if (-not $q) { $status.Text = "Type something to search for."; return }
        $status.Text = "Searching..."
        $lv.Items.Clear()
        [System.Windows.Forms.Application]::DoEvents()
        $r = Search-ADComputers -Query $q
        if (-not $r.Ok) { $status.Text = "Search failed: $($r.Error)"; return }
        foreach ($c in $r.Computers) {
            $it = New-Object System.Windows.Forms.ListViewItem($c.Name)
            [void]$it.SubItems.Add($c.Description)
            [void]$it.SubItems.Add($c.OU)
            [void]$it.SubItems.Add($c.OS)
            $it.Tag = $c
            [void]$lv.Items.Add($it)
        }
        $status.Text = if ($r.Computers.Count -eq 0) { "Nothing matched '$q'." }
                       else { "$($r.Computers.Count) computer$(if ($r.Computers.Count -ne 1) { 's' }) found." }
    }
    $take = {
        if ($lv.SelectedItems.Count -gt 0) { $state.Result = $lv.SelectedItems[0].Tag.Name; $frm.Close() }
    }
    $btnGo.Add_Click($doSearch)
    $txt.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $_.Handled = $true; $_.SuppressKeyPress = $true
            & $doSearch
        }
    })
    $lv.Add_SelectedIndexChanged({ $btnUse.Enabled = ($lv.SelectedItems.Count -gt 0) })
    $lv.Add_DoubleClick({ & $take })
    $btnUse.Add_Click({ & $take })
    $btnCancel.Add_Click({ $state.Result = $null; $frm.Close() })
    $frm.CancelButton = $btnCancel
    if ($Seed) { $frm.Add_Shown({ & $doSearch }) }
    return (Show-ListDialog -Dialog $d)
}

function Show-StoreBrowser {
    <#
        What is actually in a store folder: who, from which machine, captured
        when and by whom, and whether it has been restored yet.

        This does NOT replace Extract. Extract opens a .MIG and pulls the FILES
        out of it - a rescue tool for when a restore is not wanted or not
        possible. This reads the metadata beside each store and picks one to
        restore. Different jobs; the browser just makes Extract's input easier
        to find.
    #>
    param([Parameter(Mandatory)][string]$Root)

    $t = $Script:T
    $d = New-ListDialog -Title "Browse stores" -Width 860 -ListHeight 280 `
            -Heading "Migration stores in $Root" `
            -Subtitle "Pick one to restore. Captured before this version? Some columns will be blank - the details were not recorded then."
    $lv = $d.List
    [void]$lv.Columns.Add("User", 120)
    [void]$lv.Columns.Add("From", 110)
    [void]$lv.Columns.Add("Size", 80)
    [void]$lv.Columns.Add("Captured", 140)
    [void]$lv.Columns.Add("By", 100)
    [void]$lv.Columns.Add("Restored", 140)
    [void]$lv.Columns.Add("Onto", 110)

    $d.Status.Text = "Reading..."
    $r = Get-StoreContents -Root $Root -Recurse
    if (-not $r.Ok) {
        $d.Status.Text = "Could not read: $($r.Error)"
    } else {
        foreach ($s in $r.Stores) {
            $it = New-Object System.Windows.Forms.ListViewItem($s.Username)
            [void]$it.SubItems.Add($s.SourceComputer)
            [void]$it.SubItems.Add($s.Text)
            [void]$it.SubItems.Add($s.ExportedOn)
            [void]$it.SubItems.Add($s.ExportedBy)
            [void]$it.SubItems.Add($s.ImportedOn)
            [void]$it.SubItems.Add($s.DestinationComputer)
            # A store that has already been restored somewhere is dimmed - it is
            # usually not the one you want, and restoring it twice is a common
            # way to overwrite a profile somebody has since been using.
            if ($s.ImportedOn) { $it.ForeColor = $t.TextDim }
            $it.Tag = $s
            [void]$lv.Items.Add($it)
        }
        $d.Status.Text = "$($r.Stores.Count) store$(if ($r.Stores.Count -ne 1) { 's' })." +
                         $(if ($r.Ignored.Count -gt 0) { "  $($r.Ignored.Count) folder(s) here are not stores." } else { "" })
    }

    $btnUse    = Add-DialogButton -Dialog $d -Text "Use this store" -Right 132 -ButtonWidth 126 -Accent $t.Primary -Primary
    $btnCancel = Add-DialogButton -Dialog $d -Text "Cancel" -Right 16 -ButtonWidth 108
    $btnUse.Enabled = $false
    # Locals, not $d.*, for the same reason as the computer search above: these
    # run on a button press, long after this frame stopped being the active one.
    $frm = $d.Form; $state = $d.State
    $take = {
        if ($lv.SelectedItems.Count -gt 0) { $state.Result = $lv.SelectedItems[0].Tag; $frm.Close() }
    }
    $lv.Add_SelectedIndexChanged({ $btnUse.Enabled = ($lv.SelectedItems.Count -gt 0) })
    $lv.Add_DoubleClick({ & $take })
    $btnUse.Add_Click({ & $take })
    $btnCancel.Add_Click({ $state.Result = $null; $frm.Close() })
    $frm.CancelButton = $btnCancel
    return (Show-ListDialog -Dialog $d)
}

function Show-UserPicker {
    <#
        Pick the user to migrate from a list of the profiles that are actually
        on the machine, instead of typing a name and finding out an hour later
        that it was spelled wrong or never existed there.

        Single-select and read-only - it answers "which of these?", nothing
        more. Signed-in profiles are listed and selectable: capturing a live
        profile is the normal case, and hiding them would rule out most
        machines. Only system and built-in profiles are left out.

        Returns the chosen profile hashtable, or $null.
    #>
    param(
        [Parameter(Mandatory)][array]$Profiles,
        [string]$ComputerName = "",
        # Tickboxes and an array result, for capturing several profiles in one
        # run. Off for the Username field, which holds exactly one name.
        [switch]$Multi,
        [string[]]$Preselect = @()
    )
    $t = $Script:T
    $W = 640; $pad = 16

    $fHead = New-UTWFont "Heading" ([System.Drawing.FontStyle]::Bold)
    $fBody = New-UTWFont 9
    $fBtn  = New-UTWFont "Base" ([System.Drawing.FontStyle]::Bold)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Choose a user"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"; $dlg.ShowInTaskbar = $false
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    try { $dlg.Icon = New-AppIcon } catch { }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = if ($Multi) { "Tick the profiles to capture from $(if ($ComputerName) { $ComputerName } else { 'this PC' })" }
                else       { "Profiles on $(if ($ComputerName) { $ComputerName } else { 'this PC' })" }
    $lbl.Font = $fHead; $lbl.ForeColor = $t.Primary
    $lbl.AutoSize = $false
    $lbl.Location = New-Object System.Drawing.Point($pad, $pad)
    $lbl.Size = New-Object System.Drawing.Size(($W - 2*$pad), 24)
    $dlg.Controls.Add($lbl)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
    $lv.CheckBoxes = $Multi
    $lv.HideSelection = $false; $lv.HeaderStyle = "Nonclickable"
    $lv.Font = $fBody; $lv.BackColor = $t.MedBg; $lv.ForeColor = $t.Text
    $lv.Location = New-Object System.Drawing.Point($pad, ($pad + 30))
    $lv.Size = New-Object System.Drawing.Size(($W - 2*$pad), 250)
    [void]$lv.Columns.Add("User", 140)
    [void]$lv.Columns.Add("Last modified", 105)
    [void]$lv.Columns.Add("First created", 95)
    [void]$lv.Columns.Add("Signed in", 75)
    [void]$lv.Columns.Add("Profile folder", 175)
    $dlg.Controls.Add($lv)

    $lv.ShowItemToolTips = $true
    foreach ($p in $Profiles) {
        $it = New-Object System.Windows.Forms.ListViewItem($p.Leaf)
        [void]$it.SubItems.Add((Format-ProfileDate $p.LastUse))
        [void]$it.SubItems.Add((Format-ProfileDate $p.Created))
        $tip = "Last modified: $(Format-ProfileAge $p.AgeDays)  (registry hive, not a sign-in record)" +
               "`r`nFirst created: $(Format-ProfileAge $p.CreatedDays)"
        # Same as the lookup list: a profile with no account left says so here,
        # where somebody is choosing what to carry to the new machine.
        if ($p.Orphan) {
            [void]$it.SubItems.Add("no account")
            $it.ForeColor = $t.Warning
            $tip += "`r`n`r`nThe account for this profile could not be found - it looks deleted. Windows shows it as 'Account Unknown'."
        } else {
            [void]$it.SubItems.Add($(if ($p.Loaded) { "yes" } else { "" }))
        }
        $it.ToolTipText = $tip
        [void]$it.SubItems.Add($p.Path)
        $it.Tag = $p
        if ($Multi -and ($Preselect -contains $p.Leaf)) { $it.Checked = $true }
        [void]$lv.Items.Add($it)
    }
    Set-ProfileDateColumns -List $lv -Columns @(1, 2) -Absorb 4

    $y = $pad + 30 + 258
    $state = @{ Result = $null }

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "$($Profiles.Count) profile$(if ($Profiles.Count -ne 1) { 's' }). Signed-in profiles can still be captured."
    $lblHint.Font = $fBody; $lblHint.ForeColor = $t.TextDim
    $lblHint.AutoSize = $false; $lblHint.TextAlign = "MiddleLeft"
    $lblHint.Location = New-Object System.Drawing.Point($pad, $y)
    $lblHint.Size = New-Object System.Drawing.Size(360, 30)
    $dlg.Controls.Add($lblHint)

    $btnUse = New-Object System.Windows.Forms.Button
    $btnUse.Text = if ($Multi) { "Use ticked" } else { "Use this user" }
    $btnUse.Font = $fBtn
    $btnUse.Location = New-Object System.Drawing.Point(390, $y); $btnUse.Size = New-Object System.Drawing.Size(120, 30)
    $btnUse.FlatStyle = "Flat"; $btnUse.FlatAppearance.BorderSize = 0
    $btnUse.BackColor = $t.Primary; $btnUse.ForeColor = (Get-ContrastingText $t.Primary)
    $btnUse.Enabled = $false
    $dlg.Controls.Add($btnUse)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Cancel"; $btnCancel.Font = $fBody
    $btnCancel.Location = New-Object System.Drawing.Point(516, $y); $btnCancel.Size = New-Object System.Drawing.Size(108, 30)
    $btnCancel.FlatStyle = "Flat"; $btnCancel.BackColor = $t.MedBg; $btnCancel.ForeColor = $t.Text
    $dlg.Controls.Add($btnCancel)

    # Single-select answers with the highlighted row; multi-select answers with
    # the ticked ones, and ignores the highlight entirely - otherwise moving the
    # selection to read a path would silently change the answer.
    $refresh = {
        if ($Multi) {
            $n = @($lv.CheckedItems).Count
            $btnUse.Enabled = ($n -gt 0)
            $btnUse.Text = if ($n -gt 0) { "Use $n user$(if ($n -ne 1) { 's' })" } else { "Use ticked" }
            $lblHint.Text = "$n of $($Profiles.Count) ticked. Signed-in profiles can still be captured."
        } else {
            $btnUse.Enabled = ($lv.SelectedItems.Count -gt 0)
        }
    }
    $take = {
        if ($Multi) { $state.Result = @($lv.CheckedItems | ForEach-Object { $_.Tag }) }
        elseif ($lv.SelectedItems.Count -gt 0) { $state.Result = $lv.SelectedItems[0].Tag }
        if ($null -ne $state.Result) { $dlg.Close() }
    }
    $lv.Add_SelectedIndexChanged({ & $refresh })
    $lv.Add_ItemChecked({ & $refresh })
    # Double-click picks, but only where that is unambiguous. In multi-select it
    # would fire on the row under the pointer while other rows are ticked.
    if (-not $Multi) { $lv.Add_DoubleClick({ & $take }) }
    $btnUse.Add_Click({ & $take })
    $btnCancel.Add_Click({ $state.Result = $null; $dlg.Close() })
    & $refresh

    $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 30 + $pad))
    $dlg.AcceptButton = $btnUse
    $dlg.CancelButton = $btnCancel
    Set-FormScale -Form $dlg -Factor $Script:UIScale
    Set-DoubleBuffered -Control $dlg
    if ([Math]::Abs($Script:UIScale - 1.0) -ge 0.005) {
        foreach ($col in $lv.Columns) { $col.Width = [int]($col.Width * $Script:UIScale) }
    }

    $owner = $Script:MainForm
    if ($owner -and -not $owner.IsDisposed) { [void]$dlg.ShowDialog($owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
    # NO COMMA HERE, deliberately - see Show-ProfilePicker, which needs one.
    #
    # The difference is the caller, not the dialog: the only caller of this
    # function immediately does @($picked), so a one-item selection that unrolls
    # on the way out is put back together on arrival. Wrapping here as well
    # would hand it @(@(one)) and, worse, turn cancel from $null into a
    # one-element array holding $null. Leave it alone.
    return $state.Result
}

function Show-ProfilePicker {
    <#
        Ticklist of profiles to delete, one row each.

        Deleting a user profile is not a bulk decision - the machines that
        accumulate stale profiles are shared ones, and "all of them" is rarely
        what anybody means. So this is a per-account choice, and NOTHING is
        ticked when it opens: the operator has to say yes to each one, rather
        than say no to the ones they did not mean.

        The profiles that CANNOT go are shown too, greyed and untickable, with
        the reason. A profile silently missing from the list reads as a bug.

        Returns the array of chosen profile hashtables, or $null if cancelled.
    #>
    param(
        [Parameter(Mandatory)][array]$Removable,
        [array]$Blocked = @()
    )
    $t = $Script:T
    $W = 700; $pad = 16

    $fHead = New-UTWFont "Heading" ([System.Drawing.FontStyle]::Bold)
    $fBody = New-UTWFont 9
    $fBtn  = New-UTWFont "Base" ([System.Drawing.FontStyle]::Bold)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Clean Up - Choose Profiles"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"; $dlg.ShowInTaskbar = $false
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
    try { $dlg.Icon = New-AppIcon } catch { }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$($Script:WarningSign)  Tick the profiles to delete"
    $lbl.Font = $fHead; $lbl.ForeColor = $t.Primary
    $lbl.AutoSize = $false
    $lbl.Location = New-Object System.Drawing.Point($pad, $pad)
    $lbl.Size = New-Object System.Drawing.Size(($W - 2*$pad), 24)
    $dlg.Controls.Add($lbl)

    $sub = New-Object System.Windows.Forms.Label
    # THE DATES ARE NAMED FOR WHAT THEY ARE, and the dialog says so.
    #
    # This tool has no logon record to show. It has the profile folder's creation
    # time and the write time of the user's registry hive, and it now reports
    # those two under their own names instead of averaging them into a "last
    # used" figure that read 0 days for profiles nobody had opened in months.
    # This is the dialog that deletes documents and desktops, so it explains what
    # the numbers are - and says outright that a missing account stands on its
    # own, because that one does not depend on a timestamp at all.
    $sub.Text = "This removes the whole profile - documents, desktop and settings - and its registry entry. Nothing is ticked to start with. These dates are not sign-in records: 'last modified' is when the user's registry hive was last written, 'first created' is when the folder appeared. A profile marked 'no account left' is listed whatever its dates say, because the account behind it is gone."
    $sub.Font = $fBody; $sub.ForeColor = $t.TextDim
    $sub.AutoSize = $false
    $sub.Location = New-Object System.Drawing.Point($pad, ($pad + 26))
    $sub.Size = New-Object System.Drawing.Size(($W - 2*$pad), 52)
    $dlg.Controls.Add($sub)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
    $lv.GridLines = $false; $lv.HeaderStyle = "Nonclickable"
    $lv.Font = $fBody; $lv.BackColor = $t.MedBg; $lv.ForeColor = $t.Text
    $lv.Location = New-Object System.Drawing.Point($pad, ($pad + 82))
    $lv.Size = New-Object System.Drawing.Size(($W - 2*$pad), 242)
    [void]$lv.Columns.Add("Computer", 100)
    [void]$lv.Columns.Add("Account", 155)
    [void]$lv.Columns.Add("Last modified", 105)
    [void]$lv.Columns.Add("First created", 95)
    [void]$lv.Columns.Add("Profile folder", 195)
    $dlg.Controls.Add($lv)

    foreach ($p in $Removable) {
        $it = New-Object System.Windows.Forms.ListViewItem($p.PC)
        # "no account left" beside the name, because in this dialog it is the
        # deciding fact: the date is an estimate, but a missing account is not.
        [void]$it.SubItems.Add($(if ($p.Orphan) { "$($p.Leaf) - no account left" } else { $p.Leaf }))
        [void]$it.SubItems.Add((Format-ProfileDate $p.LastUse))
        [void]$it.SubItems.Add((Format-ProfileDate $p.Created))
        [void]$it.SubItems.Add($p.Path)
        $it.ToolTipText = "Last modified: $(Format-ProfileAge $p.AgeDays)  (registry hive, not a sign-in record)" +
                          "`r`nFirst created: $(Format-ProfileAge $p.CreatedDays)"
        $it.Tag = $p
        if ($p.Orphan) { $it.ForeColor = $t.Warning }
        [void]$lv.Items.Add($it)
    }
    $lv.ShowItemToolTips = $true
    foreach ($b in $Blocked) {
        $it = New-Object System.Windows.Forms.ListViewItem($b.PC)
        # The reason goes beside the name, not into a date column. It used to sit
        # in the third cell, which was the date column before there were two of
        # them - so adding "First created" silently shunted every blocked row's
        # path one column left and left the folder cell empty.
        [void]$it.SubItems.Add("$($b.Leaf) - cannot delete: $($b.Reason)")
        [void]$it.SubItems.Add("")
        [void]$it.SubItems.Add("")
        [void]$it.SubItems.Add($b.Path)
        $it.ToolTipText = "Cannot be deleted - $($b.Reason)."
        $it.ForeColor = $t.TextDim
        $it.Tag = $null          # marks it untickable
        [void]$lv.Items.Add($it)
    }
    # After every row is in, blocked ones included, or the widths are measured
    # against half the list.
    Set-ProfileDateColumns -List $lv -Columns @(2, 3) -Absorb 4
    # A blocked row cannot be ticked. Undoing the tick in ItemCheck rather than
    # after the fact stops the box ever appearing to accept it.
    $lv.Add_ItemCheck({
        param($eventSender, $e)
        if ($null -eq $eventSender.Items[$e.Index].Tag) { $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked }
    })

    $y = $pad + 64 + 268
    $state = @{ Result = $null }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = "0 selected"
    $lblCount.Font = $fBody; $lblCount.ForeColor = $t.TextDim
    $lblCount.AutoSize = $false; $lblCount.TextAlign = "MiddleLeft"
    $lblCount.Location = New-Object System.Drawing.Point($pad, $y)
    $lblCount.Size = New-Object System.Drawing.Size(150, 30)
    $dlg.Controls.Add($lblCount)

    $btnAll = New-Object System.Windows.Forms.Button; $btnAll.Text = "Select all"; $btnAll.Font = $fBody
    $btnAll.Location = New-Object System.Drawing.Point(170, $y); $btnAll.Size = New-Object System.Drawing.Size(90, 30)
    $btnAll.FlatStyle = "Flat"; $btnAll.BackColor = $t.MedBg; $btnAll.ForeColor = $t.Text
    $dlg.Controls.Add($btnAll)
    $btnNone = New-Object System.Windows.Forms.Button; $btnNone.Text = "Select none"; $btnNone.Font = $fBody
    $btnNone.Location = New-Object System.Drawing.Point(266, $y); $btnNone.Size = New-Object System.Drawing.Size(96, 30)
    $btnNone.FlatStyle = "Flat"; $btnNone.BackColor = $t.MedBg; $btnNone.ForeColor = $t.Text
    $dlg.Controls.Add($btnNone)

    $btnDel = New-Object System.Windows.Forms.Button; $btnDel.Text = "Delete ticked"; $btnDel.Font = $fBtn
    $btnDel.Location = New-Object System.Drawing.Point(430, $y); $btnDel.Size = New-Object System.Drawing.Size(130, 30)
    $btnDel.FlatStyle = "Flat"; $btnDel.FlatAppearance.BorderSize = 0
    $btnDel.BackColor = $t.Error; $btnDel.ForeColor = (Get-ContrastingText $t.Error)
    $btnDel.Enabled = $false
    $dlg.Controls.Add($btnDel)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Cancel"; $btnCancel.Font = $fBody
    $btnCancel.Location = New-Object System.Drawing.Point(566, $y); $btnCancel.Size = New-Object System.Drawing.Size(118, 30)
    $btnCancel.FlatStyle = "Flat"; $btnCancel.BackColor = $t.MedBg; $btnCancel.ForeColor = $t.Text
    $dlg.Controls.Add($btnCancel)

    # The count and the Delete button track the ticks, so the button cannot be
    # pressed with nothing chosen and the number is always in front of you.
    $refresh = {
        $n = @($lv.CheckedItems | Where-Object { $null -ne $_.Tag }).Count
        $lblCount.Text = "$n selected"
        $btnDel.Enabled = ($n -gt 0)
        $btnDel.Text = if ($n -gt 0) { "Delete $n profile$(if ($n -ne 1) { 's' })" } else { "Delete ticked" }
    }
    $lv.Add_ItemChecked({ & $refresh })
    $btnAll.Add_Click({
        foreach ($i in $lv.Items) { if ($null -ne $i.Tag) { $i.Checked = $true } }
        & $refresh
    })
    $btnNone.Add_Click({ foreach ($i in $lv.Items) { $i.Checked = $false }; & $refresh })
    $btnDel.Add_Click({
        $state.Result = @($lv.CheckedItems | Where-Object { $null -ne $_.Tag } | ForEach-Object { $_.Tag })
        $dlg.Close()
    })
    $btnCancel.Add_Click({ $state.Result = $null; $dlg.Close() })

    $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 30 + $pad))
    $dlg.CancelButton = $btnCancel
    Set-FormScale -Form $dlg -Factor $Script:UIScale
    Set-DoubleBuffered -Control $dlg
    # Form.Scale does not touch ListView column widths, so they stay at their
    # design pixels and the last column falls off a scaled dialog.
    if ([Math]::Abs($Script:UIScale - 1.0) -ge 0.005) {
        foreach ($col in $lv.Columns) { $col.Width = [int]($col.Width * $Script:UIScale) }
    }

    $owner = $Script:MainForm
    if ($owner -and -not $owner.IsDisposed) { [void]$dlg.ShowDialog($owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
    # THE COMMA IS LOAD-BEARING, and this is the third time in this codebase.
    #
    # Returning a one-element array unrolls it, so ticking exactly ONE profile
    # handed the caller a bare hashtable. Hashtable.Count is the number of KEYS,
    # so the confirmation read "About to permanently delete 17 user profiles"
    # above a list of one row, and the "$chosen.Count -eq 0" guards were dead
    # for the same reason. Neither caller wraps in @(), so the protection has to
    # live here - compare Get-BrowseColumns, whose callers DO wrap and which
    # must therefore NOT carry the comma. The rule is about the caller.
    # CANCEL MUST STAY $null, and the comma alone does not allow that.
    #
    # ",@($state.Result)" was added to stop a one-item selection unrolling into
    # a bare hashtable, and it did - but it also wrapped the CANCEL value:
    # @($null) is a one-element array holding $null, whose .Count is 1 and which
    # is not $null. Both callers test "$null -eq $chosen -or $chosen.Count -eq 0",
    # so cancelling produced "About to permanently delete 1 user profile" over a
    # blank row and then called Remove-RemoteUserProfile with a null SID. The
    # cure was worse than the disease it replaced.
    #
    # So the two cases are separated: nothing chosen returns $null untouched,
    # and a real selection is wrapped so one item stays a one-item array.
    if ($null -eq $state.Result) { return $null }
    return ,@($state.Result)
}
#endregion

#region ==================== SECOND WINDOW / HAND-OFF ====================
# A hand-off file is consumed exactly once, here, before anything reads it.
#
# Deleting it immediately matters: it is the ONLY thing marking this process as
# a secondary window, and leaving it behind would make a later ordinary launch
# inherit another window's settings. It is also why a secondary window does not
# write the settings file - two instances saving on close would race, and the
# one that happened to be closed last would silently win.
$Script:IsSecondary  = $false
$Script:HandoffData  = $null
if ($Handoff) {
    try {
        if (Test-Path -LiteralPath $Handoff) {
            $Script:HandoffData = Get-Content -LiteralPath $Handoff -Raw | ConvertFrom-Json
            $Script:IsSecondary = $true
            Write-CrashLog "Started as a secondary window from $Handoff"
        } else {
            Write-CrashLog "Hand-off file not found: $Handoff"
        }
    } catch {
        Write-CrashLog "Hand-off file unreadable: $($_.Exception.Message)"
    }
    try { Remove-Item -LiteralPath $Handoff -Force -ErrorAction SilentlyContinue } catch { }
}
#endregion

#region ==================== APP CONFIG (defaults  -  overridden by JSON) ====================
$Script:AppConfig = @{
    DefaultStorePath = "USMT Profiles"
    Domain           = "*"
    Verbosity        = 13
    LogFolder        = ""
    CompletionFlag   = "export_complete.json"
}
#endregion

#region ==================== ICON ====================
function New-AppIcon {
    # USMT.ico kept in the list so an existing deployment folder still resolves.
    $iconNames = @("UTW.ico", "icon.ico", "USMT.ico", "app.ico")
    foreach ($name in $iconNames) {
        $p = Join-Path $Script:ScriptDir $name
        if (Test-Path $p) { try { return New-Object System.Drawing.Icon($p) } catch { } }
    }
    $any = Get-ChildItem -Path $Script:ScriptDir -Filter "*.ico" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($any) { try { return New-Object System.Drawing.Icon($any.FullName) } catch { } }
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = "AntiAlias"
    $g.Clear([System.Drawing.Color]::FromArgb(0, 120, 212))
    $font = New-UTWFont 16 ([System.Drawing.FontStyle]::Bold)
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = "Center"; $sf.LineAlignment = "Center"
    $g.DrawString("U", $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 32, 32)), $sf)
    $g.Dispose(); $font.Dispose(); $sf.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon()); $bmp.Dispose()
    return $icon
}
#endregion

#region ==================== SPLASH ====================
function Show-SplashScreen {
    Write-CrashLog "Building splash..."
    $splash = New-Object System.Windows.Forms.Form
    $splash.Text = "User Transfer Wizard"; $splash.Size = New-Object System.Drawing.Size(460, 260)
    $splash.StartPosition = "CenterScreen"; $splash.FormBorderStyle = "None"
    $splash.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
    $splash.ShowInTaskbar = $true; $splash.TopMost = $true
    try { $splash.Icon = New-AppIcon } catch { }
    $splash.Add_Paint({ param($s, $e)
        # The themed artwork behind the splash, when it is available.
        #
        # This is the cheapest place in the tool to put a picture: the splash is
        # painted once and then sits still, so there is no per-frame cost to
        # weigh at all. It follows the same switch as everything else - no XAML
        # artwork, or the backdrop turned off, and it is the plain panel it has
        # always been.
        try {
            if ($Script:UseXamlArt -and $Script:CurrentThemeName) {
                $art = Get-XamlMaster -ThemeName $Script:CurrentThemeName -Surface "window" `
                        -W $s.ClientSize.Width -H $s.ClientSize.Height
                if ($art) {
                    $e.Graphics.DrawImageUnscaled($art, 0, 0)
                    # A wash, so the status text and the progress bar stay
                    # readable over whatever the theme happens to draw.
                    $vb = New-Object System.Drawing.SolidBrush(
                            [System.Drawing.Color]::FromArgb(150, 30, 30, 34))
                    try { $e.Graphics.FillRectangle($vb, 0, 0, $s.ClientSize.Width, $s.ClientSize.Height) }
                    finally { $vb.Dispose() }
                }
            }
        } catch { }
        $p = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 120, 212), 2)
        $e.Graphics.DrawRectangle($p, 1, 1, ($s.Width - 3), ($s.Height - 3)); $p.Dispose()
    })
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "User Transfer Wizard"
    $lbl.Font = New-UTWFont 16 ([System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212); $lbl.Location = New-Object System.Drawing.Point(30, 30); $lbl.AutoSize = $true
    $splash.Controls.Add($lbl)
    $sub = New-Object System.Windows.Forms.Label; $sub.Text = "Computer Refresh - User Profile Migration"
    $sub.Font = New-UTWFont 9; $sub.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $sub.Location = New-Object System.Drawing.Point(32, 62); $sub.AutoSize = $true; $splash.Controls.Add($sub)
    $lblStatus = New-Object System.Windows.Forms.Label; $lblStatus.Text = "Initializing..."
    $lblStatus.Font = New-UTWFont 9; $lblStatus.ForeColor = [System.Drawing.Color]::White
    $lblStatus.Location = New-Object System.Drawing.Point(30, 120); $lblStatus.Size = New-Object System.Drawing.Size(400, 20); $splash.Controls.Add($lblStatus)
    $pb = New-Object System.Windows.Forms.ProgressBar; $pb.Location = New-Object System.Drawing.Point(30, 148)
    $pb.Size = New-Object System.Drawing.Size(400, 20); $pb.Minimum = 0; $pb.Maximum = 100; $pb.Style = "Continuous"; $splash.Controls.Add($pb)
    $lblD = New-Object System.Windows.Forms.Label; $lblD.Font = New-UTWFont 8
    $lblD.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160); $lblD.Location = New-Object System.Drawing.Point(30, 175); $lblD.Size = New-Object System.Drawing.Size(400, 18); $splash.Controls.Add($lblD)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $lblA = New-Object System.Windows.Forms.Label; $lblA.Font = New-UTWFont 8
    $lblA.Location = New-Object System.Drawing.Point(30, 210); $lblA.Size = New-Object System.Drawing.Size(400, 18)
    if ($isAdmin) { $lblA.Text = "Running as Administrator"; $lblA.ForeColor = [System.Drawing.Color]::FromArgb(76, 175, 80) }
    else { $lblA.Text = "WARNING: Not running as Administrator"; $lblA.ForeColor = [System.Drawing.Color]::FromArgb(255, 193, 7) }
    $splash.Controls.Add($lblA)

    # Splash is authored at 1.0 like the main form, so it scales the same way
    Set-FormScale -Form $splash -Factor $Script:UIScale

    $splash.Show(); $splash.Refresh()
    return @{ Form = $splash; Status = $lblStatus; Detail = $lblD; ProgressBar = $pb }
}
function Update-Splash {
    param([hashtable]$Splash, [string]$Status, [string]$Detail = "", [int]$Progress = -1)
    if ($null -eq $Splash -or $null -eq $Splash.Form -or $Splash.Form.IsDisposed) { return }
    if ($Status) { $Splash.Status.Text = $Status }; if ($Detail) { $Splash.Detail.Text = $Detail }
    if ($Progress -ge 0) { $Splash.ProgressBar.Value = [Math]::Min($Progress, 100) }
    $Splash.Form.Refresh(); [System.Windows.Forms.Application]::DoEvents()
}
#endregion

#region ==================== MAIN GUI ====================
function Show-MigrationGUI {
    Write-CrashLog "Show-MigrationGUI starting..."
    try { $splash = Show-SplashScreen } catch { $splash = $null }

    # No Start-Sleep. There were 1400ms of them in this block plus 200ms at the
    # end - the splash was not waiting for anything, it was being held on screen
    # so the progress bar had time to look like it was doing something. The
    # steps below are real and take the time they take; the bar now reports
    # actual progress instead of pacing it.
    $Script:StartClock = [Diagnostics.Stopwatch]::StartNew()
    Update-Splash $splash "Checking environment..." "Computer: $env:COMPUTERNAME" 15
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Update-Splash $splash "Checking privileges..." $(if ($isAdmin) { "Running as Administrator" } else { "NOT running as Administrator" }) 30
    Update-Splash $splash "Loading configuration..." "Domain: $($Script:AppConfig.Domain)" 50
    Update-Splash $splash "Building interface..." "" 80

    $t = $Script:T
    $FontNormal  = New-UTWFont "Base"
    $FontTitle   = New-UTWFont "Title" ([System.Drawing.FontStyle]::Bold)
    $FontSection = New-UTWFont "Section" ([System.Drawing.FontStyle]::Bold)
    $FontSmall   = New-UTWFont "Small"
    $FontMono    = New-UTWFont 9 -Mono

    # ---- Accent Colours (operation-specific) ----
    # The accents live in the theme now (see Set-AccentColors in UTW-Themes),
    # so an operation's colour can suit the palette it is shown in. A theme
    # that says nothing about accents gets exactly the values that were
    # hard-coded here before.
    Set-AccentColors
    $Script:CurrentThemeName = $Script:DefaultTheme

    # ---- Anchor constants ----
    $anchLR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $anchAll = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $anchBot = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $anchTR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    # The setup column, in design pixels. Every group in it is 625 wide at x=20,
    # so 655 leaves the same 10px margin on the right that the left has, and the
    # splitter sits 17px further out to leave room for the scroll bar.
    $Script:SetupDesignWidth = 655

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = "User Transfer Wizard"
    # Nominal design size at 1.0 scale, expressed as CLIENT area so the title
    # bar and borders - which are drawn at the system DPI and never scale with
    # the layout - stay out of the layout arithmetic. The real on-screen size is
    # derived after the layout is built; see "LAYOUT FINALISATION" further down.
    $Form.ClientSize = New-Object System.Drawing.Size(665, 1040)
    # MinimumSize set after layout is calculated
    $Form.StartPosition = "CenterScreen"; $Form.BackColor = $t.DarkBg; $Form.ForeColor = $t.Text
    $Form.Font = $FontNormal; $Form.FormBorderStyle = "Sizable"; $Form.MaximizeBox = $true
    try { $Form.Icon = New-AppIcon } catch { }
    $Script:MainForm = $Form
    $Form.Add_HandleCreated({
        if ($Script:DwmAvailable) { try { [DwmHelper]::SetDarkTitleBar($Form.Handle, $Script:T.DarkTitle) } catch { } }
    })

    # ---- Menu bar ----
    # Everything that is not part of running a migration lives up here rather
    # than competing for space in the header: opening a second window, saving
    # the log, the settings, the docs. MenuStrip is docked, so it takes its own
    # row above the layout and needs no place in the fixed-pixel arithmetic -
    # $yPos still starts at 15 relative to the client area below it.
    $menu = New-Object System.Windows.Forms.MenuStrip
    $menu.BackColor = $t.GroupBg; $menu.ForeColor = $t.Text
    $menu.Tag = "menu"
    if ($Script:MenuRendererAvailable) {
        [UTWMenuColors]::Bg     = $t.GroupBg
        [UTWMenuColors]::Sel    = $t.Primary
        [UTWMenuColors]::Border = $t.MedBg
        $menu.RenderMode = "Professional"
        $menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer (New-Object UTWMenuColors)
    } else {
        # Without the renderer the system palette is the only option, and light
        # text on it would be unreadable - so the text goes dark instead.
        $menu.RenderMode = "System"
        $menu.ForeColor = [System.Drawing.Color]::Black
    }
    $Form.Controls.Add($menu)
    $Form.MainMenuStrip = $menu

    function New-MenuItem {
        param([string]$Text, [scriptblock]$OnClick = $null, [string]$Shortcut = "")
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
        $mi.BackColor = $Script:T.GroupBg; $mi.ForeColor = $Script:T.Text
        if ($OnClick) { $mi.Add_Click($OnClick) }
        if ($Shortcut) {
            try { $mi.ShortcutKeys = [System.Windows.Forms.Keys]$Shortcut; $mi.ShowShortcutKeys = $true } catch { }
        }
        return $mi
    }
    function New-MenuSeparator { return (New-Object System.Windows.Forms.ToolStripSeparator) }

    function Set-StripItemColors {
        <#
            A ToolStripMenuItem built with New-Object keeps the SYSTEM colours -
            black text - and the renderer paints the dropdown behind it in the
            theme's dark panel colour. Black on near-black is how the Theme
            submenu ended up unreadable. Every item that is not created through
            New-MenuItem has to be passed through here.
        #>
        param($Item)
        if (-not $Item) { return }
        try {
            $Item.BackColor = $Script:T.GroupBg
            $Item.ForeColor = $Script:T.Text
            if ($Item.HasDropDownItems) {
                $Item.DropDown.BackColor = $Script:T.GroupBg
                foreach ($sub in $Item.DropDownItems) { Set-StripItemColors $sub }
            }
        } catch { }
    }

    $miFile = New-MenuItem "&File"
    $miView = New-MenuItem "&View"
    $miHelp = New-MenuItem "&Help"
    [void]$menu.Items.Add($miFile); [void]$menu.Items.Add($miView); [void]$menu.Items.Add($miHelp)

    $yPos = 15

    # ---- Title + subtitle + Theme ----
    # Status lives at the foot of the window in its own bordered group, where it
    # has always been.
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "User Transfer Wizard"; $lblTitle.Font = $FontTitle; $lblTitle.ForeColor = $t.Primary
    $lblTitle.Location = New-Object System.Drawing.Point(15, $yPos); $lblTitle.AutoSize = $true; $lblTitle.Tag = "title"
    $Form.Controls.Add($lblTitle)
    # ---- Mode: Simple / Expert ----
    # Kept on the form AND mirrored in the View menu, deliberately.
    #
    # Two places to change one setting is only redundancy when both are equally
    # hard to find. This is the pattern every editor uses for a view mode: the
    # visible control is what a technician who has never opened the tool finds
    # without hunting, and the menu entry is what somebody who works in menus
    # reaches for - and it also shows the keyboard path. What was actually wrong
    # was that the pair looked like two stray radio buttons floating beside the
    # title; it now has a caption, sits in the space the theme picker vacated,
    # and reads as one labelled control.
    #
    # A dropdown was the alternative and is worse here: there are exactly two
    # states, and hiding one of them behind a click to save 70px is a bad trade
    # in the one place the tool explains its own complexity.
    # ONE toggle, not a pair of radio buttons.
    #
    # Two radios described a choice between two things when there is really one
    # thing that is on or off: Expert mode ADDS a panel, it does not swap the
    # window for a different one. A pressed-in toggle says that in a single
    # control, reads as a toolbar button rather than as a form field, and stops
    # the header looking like it is asking a question. View > Expert still
    # mirrors it for anyone who works in menus.
    #
    # The two radios survive as invisible state, because roughly a dozen places
    # read $rbExpert.Checked or set $rbSimple.Checked, and the CheckedChanged
    # handler that shows the panel hangs off them. Setting .Checked on a hidden
    # radio works normally - it is only PerformClick() that refuses on an
    # invisible control.
    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Text = "Mode:"; $lblMode.Font = $FontSmall; $lblMode.ForeColor = $t.TextDim
    $lblMode.AutoSize = $false; $lblMode.Size = New-Object System.Drawing.Size(44, 22)
    $lblMode.TextAlign = "MiddleRight"
    $lblMode.Location = New-Object System.Drawing.Point(454, ($yPos + 4)); $lblMode.Tag = "dim"
    $Form.Controls.Add($lblMode)

    $rbSimple = New-Object System.Windows.Forms.RadioButton
    $rbSimple.Checked = $true; $rbSimple.TabStop = $false; $rbSimple.Visible = $false
    $Form.Controls.Add($rbSimple)
    $rbExpert = New-Object System.Windows.Forms.RadioButton
    $rbExpert.TabStop = $false; $rbExpert.Visible = $false
    $Form.Controls.Add($rbExpert)

    $chkExpertMode = New-Object System.Windows.Forms.CheckBox
    $chkExpertMode.Appearance = [System.Windows.Forms.Appearance]::Button
    $chkExpertMode.Text = "Expert"; $chkExpertMode.Font = $FontSmall
    $chkExpertMode.TextAlign = "MiddleCenter"
    $chkExpertMode.AutoSize = $false; $chkExpertMode.Size = New-Object System.Drawing.Size(108, 24)
    $chkExpertMode.Location = New-Object System.Drawing.Point(502, ($yPos + 3))
    $chkExpertMode.FlatStyle = "Flat"; $chkExpertMode.BackColor = $t.MedBg; $chkExpertMode.ForeColor = $t.Text
    $chkExpertMode.Tag = "mode-toggle"
    $Form.Controls.Add($chkExpertMode)
    $Script:ModeToggleSyncing = $false
    $chkExpertMode.Add_CheckedChanged({
        if ($Script:ModeToggleSyncing) { return }
        # The radio owns the transition (including the "you have edits" prompt),
        # so this only asks for it. If that prompt is declined the radio stays
        # put, and Sync-ModeToggle puts the button back to match.
        if ($chkExpertMode.Checked) { $rbExpert.Checked = $true } else { $rbSimple.Checked = $true }
        Sync-ModeToggle
    })
    function Sync-ModeToggle {
        # The single source of truth is the radio pair; this makes the button
        # agree with it, whichever of the four ways the mode was changed.
        $Script:ModeToggleSyncing = $true
        try {
            $chkExpertMode.Checked = $rbExpert.Checked
            $chkExpertMode.Text = if ($rbExpert.Checked) { "Expert: on" } else { "Expert: off" }
            $chkExpertMode.BackColor = if ($rbExpert.Checked) { $Script:T.Primary } else { $Script:T.MedBg }
            $chkExpertMode.ForeColor = if ($rbExpert.Checked) { (Get-ContrastingText $Script:T.Primary) } else { $Script:T.Text }
        } catch { } finally { $Script:ModeToggleSyncing = $false }
    }

    $lblTheme = New-Object System.Windows.Forms.Label; $lblTheme.Text = "Theme:"; $lblTheme.Font = $FontSmall; $lblTheme.ForeColor = $t.TextDim
    $lblTheme.AutoSize = $false; $lblTheme.Size = New-Object System.Drawing.Size(46, 18)
    $lblTheme.TextAlign = "MiddleRight"
    $lblTheme.Location = New-Object System.Drawing.Point(476, ($yPos + 5)); $lblTheme.Tag = "dim"
    $lblTheme.Anchor = $anchTR
    $Form.Controls.Add($lblTheme)
    $cmbTheme = New-Object System.Windows.Forms.ComboBox; $cmbTheme.Font = $FontSmall
    $cmbTheme.Location = New-Object System.Drawing.Point(525, ($yPos + 2)); $cmbTheme.Size = New-Object System.Drawing.Size(120, 22)
    $cmbTheme.DropDownStyle = "DropDownList"; $cmbTheme.BackColor = $t.MedBg; $cmbTheme.ForeColor = $t.Text; $cmbTheme.FlatStyle = "Flat"
    $cmbTheme.Items.AddRange((Get-ThemeNames)); $cmbTheme.SelectedItem = $Script:DefaultTheme; $cmbTheme.TabStop = $false
    $cmbTheme.Anchor = $anchTR
    $Form.Controls.Add($cmbTheme)
    $lblSubtitle = New-Object System.Windows.Forms.Label
    $lblSubtitle.Text = "Computer Refresh - User Profile Migration for Desktop Services"
    $lblSubtitle.Font = $FontSmall; $lblSubtitle.ForeColor = $t.TextDim
    $lblSubtitle.Location = New-Object System.Drawing.Point(17, ($yPos + 28)); $lblSubtitle.AutoSize = $true; $lblSubtitle.Tag = "dim"
    $Form.Controls.Add($lblSubtitle)

    # Elevation banner. Sits on the subtitle row, right-aligned, so it lands in
    # the header without colliding with the title (which grows in some themes)
    # or the theme picker above it. Only ever shown when it is a problem.
    $Script:IsElevated = Test-IsElevated
    $lblAdminWarn = New-Object System.Windows.Forms.Label
    $lblAdminWarn.Text = "$($Script:WarningSign) Not running as administrator"
    $lblAdminWarn.Font = New-UTWFont "Small" ([System.Drawing.FontStyle]::Bold)
    $lblAdminWarn.ForeColor = $t.Warning; $lblAdminWarn.Tag = "status-warning"
    $lblAdminWarn.AutoSize = $false
    $lblAdminWarn.Size = New-Object System.Drawing.Size(255, 18)
    $lblAdminWarn.TextAlign = "MiddleRight"
    $lblAdminWarn.Location = New-Object System.Drawing.Point(355, ($yPos + 27))
    # Fixed position - the header no longer resizes with the window.
    $lblAdminWarn.Visible = (-not $Script:IsElevated)
    $Form.Controls.Add($lblAdminWarn)
    if (-not $Script:IsElevated) {
        # The OS title bar carries it too, for when the window is behind others.
        $Form.Text = "$($Form.Text)  -  NOT RUNNING AS ADMINISTRATOR"
        Write-CrashLog "Started WITHOUT administrator rights"
    }

    # Hairline rule in the accent colour: separates the title block from the
    # form without spending a whole row on whitespace.
    $pnlAccent = New-Object System.Windows.Forms.Panel
    # 15..610, the same content box every other panel uses. It was 15..650,
    # sized for a 665-wide header - but the header sits in a zone whose client
    # is nearer 625 design px, so the rule and everything right-aligned with it
    # hung ~25px past the edge and was clipped. That is the text cut off on the
    # right-hand side.
    $pnlAccent.Location = New-Object System.Drawing.Point(15, ($yPos + 47))
    $pnlAccent.Size = New-Object System.Drawing.Size(595, 2)
    $pnlAccent.BackColor = (Get-DividerColor); $pnlAccent.Tag = "accent-bar"; $pnlAccent.Anchor = $anchLR
    $Form.Controls.Add($pnlAccent)

    # ---- Update-RunButtonColor  -  sets colour + text based on current operation ----
    function Update-RunButtonColor {
        $opText = Get-OperationText
        if ($opText -match "Clean Up") {
            # Slate, not orange: the only action here that deletes rather than
            # migrates should not share a colour with Extract.
            $btnRun.BackColor = $Script:AccentSlate
            $btnRun.Text = "$($Script:ArrowRight) Run Clean Up"
        } elseif ($opText -match "Compare") {
            # "Compare" rather than "Run": pressing it writes nothing. It lists
            # the differences and waits, which is a promise worth making on the
            # button itself.
            $btnRun.BackColor = $Script:AccentCyan
            $btnRun.Text = "$($Script:ArrowRight) Compare"
        } elseif ($opText -match "Extract") {
            $btnRun.BackColor = $Script:AccentOrange
            $btnRun.Text = "$($Script:ArrowRight) Run Extract"
        } elseif ($opText -match "Computer Settings" -and $opText -match [regex]::Escape([char]0x21C4)) {
            $btnRun.BackColor = $Script:AccentPurple
            $btnRun.Text = "$($Script:ArrowRight) Run Settings Export + Import"
        } elseif ($opText -match "Computer Settings" -and $opText -match "Import") {
            $btnRun.BackColor = $Script:AccentGreen
            $btnRun.Text = "$($Script:ArrowRight) Run Settings Import"
        } elseif ($opText -match "Computer Settings") {
            $btnRun.BackColor = $Script:AccentCyan
            $btnRun.Text = "$($Script:ArrowRight) Run Settings Export"
        } elseif ($opText -match [regex]::Escape([char]0x21C4)) {
            $btnRun.BackColor = $Script:AccentPurple
            $btnRun.Text = "$($Script:ArrowRight) Run Export + Import"
        } elseif ($opText -match "Import") {
            $btnRun.BackColor = $Script:AccentGreen
            $btnRun.Text = "$($Script:ArrowRight) Run Import (LoadState)"
        } elseif ($opText -match "Export") {
            $btnRun.BackColor = $Script:T.Primary
            $btnRun.Text = "$($Script:ArrowRight) Run Export (ScanState)"
        } else {
            $btnRun.BackColor = $Script:T.Primary
            $btnRun.Text = "$($Script:ArrowRight) Run Migration"
        }
        $btnRun.ForeColor = (Get-ContrastingText $btnRun.BackColor)

        # THE OPERATION'S GLYPH, when XAML mode is on.
        #
        # The cell is chosen from the text just set, so there is one place that
        # decides what this button says and shows and the two cannot disagree.
        # With the artwork off, or if the sheet is missing, the icon is simply
        # not set and the text arrow it has always had stands alone - which is
        # why the arrow stays in the caption rather than being replaced.
        try {
            $ico = ""
            $bt  = $btnRun.Text
            if     ($bt -match "Clean Up")         { $ico = "cleanup" }
            elseif ($bt -match "Extract")          { $ico = "extract" }
            elseif ($bt -match "Export \+ Import") { $ico = "both" }
            elseif ($bt -match "Import")           { $ico = "import" }
            elseif ($bt -match "Export")           { $ico = "export" }
            # THE GLYPH IS OFF. Deliberately, for now.
            #
            # Get-XamlIcon and the five icon.*.xaml files are finished and
            # correct as far as anything here can prove: the layout measures
            # exactly (a 24x24 canvas into a 27x27 box, uniform), and yet every
            # glyph renders shifted into the bottom-right and clipped against
            # its own edge - all five with near-identical coverage, which five
            # different shapes should not produce. Something in the render is
            # wrong in a way that only shows on screen.
            #
            # This button starts migrations. A caption that reads correctly beats
            # a picture that might be broken, so it keeps the text arrow it has
            # always had until the glyph can be seen to be right. Set $ico to ""
            # above to re-enable nothing; delete this line to re-enable the icon.
            $img = $null
            # ONLY WHEN IT CHANGES. This runs on every field update, and both
            # Image and Padding invalidate the button's layout when written -
            # even when written the same value. Assigning them unconditionally
            # put measurable time onto resize frames for no visible difference.
            if (-not [Object]::ReferenceEquals($btnRun.Image, $img)) {
                $btnRun.Image = $img
                if ($img) {
                    $btnRun.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
                    $btnRun.TextAlign  = [System.Drawing.ContentAlignment]::MiddleCenter
                    $btnRun.Padding    = New-Object System.Windows.Forms.Padding([int](8 * $Script:UIScale), 0, 0, 0)
                } else {
                    $btnRun.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
                }
            }
        } catch { try { $btnRun.Image = $null } catch { } }
    }

    $cmbTheme.Add_SelectedIndexChanged({
        $themeName = $cmbTheme.SelectedItem.ToString()
        $Script:CurrentThemeName = $themeName
        Apply-Theme -Form $Form -ThemeName $themeName
        $cmbTheme.BackColor = $Script:T.MedBg; $cmbTheme.ForeColor = $Script:T.Text
        # Re-apply operation-specific Run button colour
        Update-RunButtonColor
        # Belt-and-suspenders: force Stop button white on error
        $btnStop.BackColor = $Script:T.Error; $btnStop.ForeColor = (Get-ContrastingText $Script:T.Error)
        # Preserve accent colours on Source PC labels
        $lblSourcePC.ForeColor     = $Script:AccentCyan
        # Re-apply utility button colours. These are fixed accents rather than
        # theme greys so each button in the Actions row is its own colour.
        $btnOpenLogs.BackColor = $Script:AccentTeal;  $btnOpenLogs.ForeColor = (Get-ContrastingText $Script:AccentTeal)
        # ComboBox colours
        $cmbScope.BackColor  = $Script:T.MedBg; $cmbScope.ForeColor  = $Script:T.Text
        $cmbAction.BackColor = $Script:T.MedBg; $cmbAction.ForeColor = $Script:T.Text
        # Clown Fiesta easter egg. The pink belongs to the subtitle - putting it
        # on the progress label turned the little clown car pink; it is gold,
        # like the rest of the theme's Primary.
        if ($themeName -eq "Clown Fiesta") {
            $lblTitle.Text = "$([char]0x2605) User Transfer Wizard $([char]0x2605)"
            $lblSubtitle.Text = "Clown Fiesta Edition - Honk Honk!"
            $Script:TitleBase = "User Transfer Wizard - Clown Fiesta $([char]0x2605)"
            $lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 110, 180) # pink
        } else {
            $lblTitle.Text = "User Transfer Wizard"
            $lblSubtitle.Text = "Computer Refresh - User Profile Migration for Desktop Services"
            $Script:TitleBase = "User Transfer Wizard"
            $lblSubtitle.ForeColor = $Script:T.TextDim
        }
        # Only the BASE changes here. Update-WindowTitle re-attaches the window
        # number, the route and the elevation warning - a theme change used to
        # rewrite Form.Text wholesale and silently drop all three.
        # try/catch because a theme can be applied before the layout has defined
        # that function; the title is corrected the moment it exists.
        try { Update-WindowTitle } catch { $Form.Text = $Script:TitleBase }
        # The subtitle owns its own colour in both branches; the banner must not
        # inherit the dim/pink treatment applied alongside it.
        if ($lblAdminWarn) { $lblAdminWarn.ForeColor = $Script:T.Warning }
        $lblProgress.ForeColor = $Script:T.Primary
        # The mode button paints itself from the theme, so it has to be redone
        # here or it keeps the previous theme's accent.
        try { Sync-ModeToggle } catch { }
        # The summary pane colours each line as it writes it, so the existing
        # text keeps the OLD theme's colours until it is written again.
        try { Update-Plan } catch { }
        # Same for every divider: Apply-Theme colours the SplitContainer, but
        # these four are the ones the window is judged on and re-setting them
        # from one function keeps them identical in every theme.
        try {
            $dv = Get-DividerColor
            $split.BackColor = $dv; $splitRight.BackColor = $dv
            $pnlAccent.BackColor = $dv; $pnlOptRule.BackColor = $dv
            $pnlDangerRule.BackColor = $Script:T.Error
        } catch { }
        # The cached backdrop was drawn in the OLD palette.
        try { Set-OverlayEnabled $Script:OverlayEnabled } catch { }
    })
    $yPos += 55

    # ---- USMT Location ----
    $grpTools = New-Object System.Windows.Forms.GroupBox; $grpTools.Text = "  USMT Location  "; $grpTools.Font = $FontSection; $grpTools.ForeColor = $t.Primary
    $grpTools.Location = New-Object System.Drawing.Point(20, $yPos); $grpTools.Size = New-Object System.Drawing.Size(625, 75); $grpTools.BackColor = $t.GroupBg
    # No Left+Right anchor: this group lives in the fixed-width setup column,
    # and an anchor captured before that column has a real size stretches it.
    $Form.Controls.Add($grpTools)
    $txtUSMTPath = New-Object System.Windows.Forms.TextBox; $txtUSMTPath.Font = $FontNormal; $txtUSMTPath.Location = New-Object System.Drawing.Point(15, 28)
    $txtUSMTPath.Size = New-Object System.Drawing.Size(500, 26); $txtUSMTPath.BackColor = $t.MedBg; $txtUSMTPath.ForeColor = $t.TextDim
    $txtUSMTPath.BorderStyle = "FixedSingle"; $txtUSMTPath.ReadOnly = $false; $txtUSMTPath.Text = "(type or browse to select USMT folder)"; $grpTools.Controls.Add($txtUSMTPath)
    $lblUSMTStatus = New-Object System.Windows.Forms.Label; $lblUSMTStatus.Text = "$($Script:WarningSign) Not set - browse to the folder containing scanstate.exe"
    $lblUSMTStatus.Font = $FontSmall; $lblUSMTStatus.ForeColor = $t.Warning; $lblUSMTStatus.Location = New-Object System.Drawing.Point(15, 55); $lblUSMTStatus.AutoSize = $true; $lblUSMTStatus.Tag = "status-warning"
    $grpTools.Controls.Add($lblUSMTStatus)
    $btnBrowseUSMT = New-Object System.Windows.Forms.Button; $btnBrowseUSMT.Text = "Browse..."; $btnBrowseUSMT.Font = $FontNormal
    $btnBrowseUSMT.Location = New-Object System.Drawing.Point(525, 26); $btnBrowseUSMT.Size = New-Object System.Drawing.Size(85, 28)
    $btnBrowseUSMT.FlatStyle = "Flat"; $btnBrowseUSMT.BackColor = $t.MedBg; $btnBrowseUSMT.ForeColor = $t.Text; $btnBrowseUSMT.Tag = "browse"
    # Sized and aligned by Set-FieldButtonFit AFTER the form has been scaled -
    # not here. A single-line TextBox refuses the height it is given and takes
    # one from its font, so at construction time the number next to it is a
    # design intention rather than a fact, and matching against it lands the
    # button off the row. See the note on that function.
    $btnBrowseUSMT.Anchor = $anchTR
    $grpTools.Controls.Add($btnBrowseUSMT)
    # Helper function to validate and apply USMT path
    function Validate-AndSetUSMTPath {
        param([string]$PathToValidate)
        $PathToValidate = $PathToValidate.Trim()
        if ([string]::IsNullOrWhiteSpace($PathToValidate) -or $PathToValidate -eq "(type or browse to select USMT folder)") {
            return $false
        }
        if (Test-USMTPath $PathToValidate) {
            $txtUSMTPath.Text = $PathToValidate
    # Show the START of the path. A TextBox leaves the caret at the end after an
    # assignment and scrolls to it, so a path longer than the box opened showing
    # its middle - the least useful part, since what identifies a folder is the
    # front of it.
    try { $txtUSMTPath.Select(0, 0); $txtUSMTPath.ScrollToCaret() } catch { }
            $txtUSMTPath.ForeColor = $Script:T.Text
            $vinfo = Get-UsmtFolderInfo -USMTPath $PathToValidate
            $lblUSMTStatus.Text = "$($Script:CheckMark) USMT files found - $($vinfo.Summary)"
            $lblUSMTStatus.ForeColor = if ($vinfo.Released) { $Script:T.Success } else { $Script:T.Warning }
            $lblUSMTStatus.Tag = if ($vinfo.Released) { "status-ok" } else { "status-warning" }
            Write-CrashLog "USMT folder set: $PathToValidate ($($vinfo.Summary))"
            Write-UsmtVersionStamp -USMTPath $PathToValidate -Build $vinfo.Build
            $logPath = Set-LogFolder $PathToValidate
            Set-LogPathDisplay $logPath
            try { 
                Save-SettingsCache @{ 
                    USMTPath = $PathToValidate
                    Theme = $cmbTheme.SelectedItem.ToString()
                    UiMode          = $(if ($rbExpert.Checked) { "Expert" } else { "Simple" })
                    ODDetect        = $chkODDetect.Checked
                    ODPattern       = $txtODPattern.Text.Trim()
                    ODMinMB         = $txtODMin.Text.Trim()
                    ArchIndex       = $cmbArch.SelectedIndex
                    LogOnExit       = $chkLogOnExit.Checked
                    RenameOn        = $chkRenameOnRestore.Checked
                    DeleteSource    = $chkDeleteSource.Checked
                    ScopeIndex      = $cmbScope.SelectedIndex
                    ActionIndex     = $cmbAction.SelectedIndex
                    ExcludeOneDrive = $chkExcludeOneDrive.Checked
                VerifyProfile   = $chkVerifyProfile.Checked
                CheckDisk       = $chkCheckDisk.Checked
                CheckInactive   = $chkCheckInactive.Checked
                    EstimateSize    = $chkEstimateSize.Checked
                    BrowseColumns   = (@($Script:BrowseColumns) -join ",")
                SyncAppData     = $Script:SyncIncludeAppData
                ConfigXmlMode   = $Script:ConfigXmlMode
                InactiveDays     = $Script:PreflightInactiveDays
                MinFreeGB     = $Script:PreflightMinFreeGB
                    TouchTargets    = ($Script:TouchBoost -gt 1.0)
                    StackedLayout   = ($split.Orientation -eq [System.Windows.Forms.Orientation]::Horizontal)
                    StoreMode       = Get-StoreMode
                    CentralPath     = $txtCentralPath.Text.Trim()
                    DestType = if ((Get-StoreMode) -eq "USB") { "USB" } else { "Network" }
                    LastUsername = $txtUsername.Text.Trim()
                    LastNewPC = $txtNewPC.Text.Trim()
                    LastSourcePC = $txtSourcePC.Text.Trim()
                    USBPath = $txtUSBPath.Text.Trim()
                    LastMigFile = $txtMigrationFile.Text
                    LastExtractPath = $txtExtractPath.Text 
                } 
            } catch { }
            return $true
        } else {
            $txtUSMTPath.Text = $PathToValidate
    # Show the START of the path. A TextBox leaves the caret at the end after an
    # assignment and scrolls to it, so a path longer than the box opened showing
    # its middle - the least useful part, since what identifies a folder is the
    # front of it.
    try { $txtUSMTPath.Select(0, 0); $txtUSMTPath.ScrollToCaret() } catch { }
            $txtUSMTPath.ForeColor = $Script:T.Warning
            $lblUSMTStatus.Text = "$($Script:WarningSign) Required files not found at this location"
            $lblUSMTStatus.ForeColor = $Script:T.Warning
            $lblUSMTStatus.Tag = "status-warning"
            Show-ThemedMessage "Required files not found:`n- scanstate.exe`n- loadstate.exe`n- migapp.xml`n- miguser.xml`n`nPath checked: $PathToValidate" "Invalid USMT Path" "OK" "Warning"
            return $false
        }
    }
    # Browse button using native Shell.BrowseForFolder for folder selection
    $btnBrowseUSMT.Add_Click({
        try {
            $shell = New-Object -ComObject Shell.Application
            $folder = $shell.BrowseForFolder(0, "Select the folder containing scanstate.exe and loadstate.exe:", 0, 0)
            if ($folder) {
                $selectedPath = $folder.Self.Path
                Validate-AndSetUSMTPath $selectedPath
            }
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        } catch {
            Show-ThemedMessage "Error opening folder browser: $($_.Exception.Message)" "Browse Error" "OK" "Warning"
        }
    })
    # Validate when user leaves the text box
    $txtUSMTPath.Add_Leave({
        $currentPath = $txtUSMTPath.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($currentPath) -and $currentPath -ne "(type or browse to select USMT folder)") {
            Validate-AndSetUSMTPath $currentPath
        }
    })
    # Validate when user presses Enter
    $txtUSMTPath.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $currentPath = $txtUSMTPath.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($currentPath) -and $currentPath -ne "(type or browse to select USMT folder)") {
                Validate-AndSetUSMTPath $currentPath
            }
            $_.Handled = $true
        }
    })
    $yPos += 84

    # ---- Operation ----
    $grpOperation = New-Object System.Windows.Forms.GroupBox; $grpOperation.Text = "  Operation  "; $grpOperation.Font = $FontSection; $grpOperation.ForeColor = $t.Primary
    $grpOperation.Location = New-Object System.Drawing.Point(20, $yPos); $grpOperation.Size = New-Object System.Drawing.Size(625, 100); $grpOperation.BackColor = $t.GroupBg
    # No Left+Right anchor: this group lives in the fixed-width setup column,
    # and an anchor captured before that column has a real size stretches it.
    $Form.Controls.Add($grpOperation)
    # The original twelve-item list was the cross product of "what to do" x "what
    # it applies to", written out longhand, with the OneDrive variants doubling
    # two of the rows. Those are now two dropdowns plus a checkbox in Options,
    # and Save Location - two radio buttons that had a whole group box to
    # themselves - joins them here as the third line of the same decision.
    #
    # Extract appears in ONE list only. It lives under Action because that is
    # what it is; "applies to" is meaningless for it, so that dropdown greys out
    # rather than offering a second, redundant way to reach the same mode.
    $lblAction = New-Object System.Windows.Forms.Label; $lblAction.Text = "Action:"
    $lblAction.Font = $FontNormal; $lblAction.ForeColor = $t.Text
    $lblAction.Location = New-Object System.Drawing.Point(15, 33)
    $lblAction.AutoSize = $false; $lblAction.Size = New-Object System.Drawing.Size(52, 20); $lblAction.TextAlign = "MiddleLeft"
    $grpOperation.Controls.Add($lblAction)
    $cmbAction = New-Object System.Windows.Forms.ComboBox; $cmbAction.Font = $FontNormal
    $cmbAction.Location = New-Object System.Drawing.Point(70, 28); $cmbAction.Size = New-Object System.Drawing.Size(230, 28)
    $cmbAction.DropDownStyle = "DropDownList"
    $cmbAction.BackColor = $t.MedBg; $cmbAction.ForeColor = $t.Text; $cmbAction.FlatStyle = "Flat"
    $cmbAction.Items.AddRange(@(
        "Export (capture a profile)",
        "Import (restore a profile)",
        "$([char]0x21C4) Export + Import",
        "Extract a .MIG file",
        "Clean up USMT files",
        # LAST, AND THAT IS NOT COSMETIC. The chosen action is remembered as an
        # INDEX, so inserting an entry renumbers everything after it - a saved
        # "Clean up USMT files" would have silently become this on the next
        # launch. New actions go on the end.
        "Compare & Sync"
    ))
    $cmbAction.SelectedIndex = 0
    $grpOperation.Controls.Add($cmbAction)

    # Export + Import needs both machines on the store at the same moment, which
    # a drive cannot give - it is reachable by one machine at a time and the step
    # that changes that is somebody carrying it. So the DESTINATION is what goes
    # unavailable, not the operation: picking Export + Import should never
    # silently change the operation out from under you.
    $Script:ActionComboIndex   = 2      # "⇄ Export + Import"
    $Script:SaveToDriveIndex   = 2      # "External / USB drive"
    $Script:SaveToDirectIndex  = 0      # "New PC (direct)"
    $Script:DriveOptionDisabled = $false
    $Script:FixingSaveTo       = $false

    $lblScope = New-Object System.Windows.Forms.Label; $lblScope.Text = "Applies to:"
    $lblScope.Font = $FontNormal; $lblScope.ForeColor = $t.Text
    $lblScope.Location = New-Object System.Drawing.Point(312, 33)
    $lblScope.AutoSize = $false; $lblScope.Size = New-Object System.Drawing.Size(74, 20); $lblScope.TextAlign = "MiddleLeft"
    $grpOperation.Controls.Add($lblScope)
    $cmbScope = New-Object System.Windows.Forms.ComboBox; $cmbScope.Font = $FontNormal
    $cmbScope.Location = New-Object System.Drawing.Point(388, 28); $cmbScope.Size = New-Object System.Drawing.Size(222, 28)
    $cmbScope.DropDownStyle = "DropDownList"
    $cmbScope.BackColor = $t.MedBg; $cmbScope.ForeColor = $t.Text; $cmbScope.FlatStyle = "Flat"
    $cmbScope.Items.AddRange(@("Single Profile", "All Profiles", "Computer Settings"))
    $cmbScope.SelectedIndex = 0
    $grpOperation.Controls.Add($cmbScope)

    $lblSaveTo = New-Object System.Windows.Forms.Label; $lblSaveTo.Text = "Save to:"
    $lblSaveTo.Font = $FontNormal; $lblSaveTo.ForeColor = $t.Text
    $lblSaveTo.Location = New-Object System.Drawing.Point(15, 68)
    $lblSaveTo.AutoSize = $false; $lblSaveTo.Size = New-Object System.Drawing.Size(52, 20); $lblSaveTo.TextAlign = "MiddleLeft"
    $grpOperation.Controls.Add($lblSaveTo)
    # Three destinations no longer fit as radio buttons on one row, and a third
    # dropdown matches the two above it.
    $cmbSaveTo = New-Object System.Windows.Forms.ComboBox; $cmbSaveTo.Font = $FontNormal
    $cmbSaveTo.Location = New-Object System.Drawing.Point(70, 64); $cmbSaveTo.Size = New-Object System.Drawing.Size(230, 28)
    $cmbSaveTo.DropDownStyle = "DropDownList"
    $cmbSaveTo.BackColor = $t.MedBg; $cmbSaveTo.ForeColor = $t.Text; $cmbSaveTo.FlatStyle = "Flat"
    $cmbSaveTo.Items.AddRange(@(
        "New PC (direct)",
        "Network share (UNC)",
        "External / USB drive"
    ))
    $cmbSaveTo.SelectedIndex = 0
    $grpOperation.Controls.Add($cmbSaveTo)

    # A ComboBox cannot grey a single item on its own - the list has to be drawn
    # by hand. The background is painted explicitly too, because taking over
    # DrawItem also takes over the theme colours.
    $cmbSaveTo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $cmbSaveTo.Add_DrawItem({
        param($drawSender, $e)
        if ($e.Index -lt 0) { return }
        $txt   = $drawSender.Items[$e.Index].ToString()
        $isOff = $Script:DriveOptionDisabled -and ($e.Index -eq $Script:SaveToDriveIndex)
        $sel   = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
        $bg = if ($sel -and -not $isOff) { $Script:T.Primary } else { $Script:T.MedBg }
        $fg = if ($isOff)   { $Script:T.TextDim }
              elseif ($sel) { (Get-ContrastingText $Script:T.Primary) }
              else          { $Script:T.Text }
        $brush = New-Object System.Drawing.SolidBrush($bg)
        try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 2), $e.Bounds.Y, ($e.Bounds.Width - 2), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $drawSender.Font, $r, $fg,
            ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
    })

    # Says what the chosen route actually costs, so the trade-off is visible at
    # the point of choosing rather than buried in a tooltip.
    $lblSaveToHint = New-Object System.Windows.Forms.Label
    $lblSaveToHint.Font = $FontSmall; $lblSaveToHint.ForeColor = $Script:AccentPurple; $lblSaveToHint.Tag = "accent-purple"
    $lblSaveToHint.Location = New-Object System.Drawing.Point(310, 70); $lblSaveToHint.AutoSize = $false
    $lblSaveToHint.Size = New-Object System.Drawing.Size(300, 18); $lblSaveToHint.TextAlign = "MiddleLeft"
    $grpOperation.Controls.Add($lblSaveToHint)

    function Get-StoreMode {
        <#
            Direct  - scanstate streams straight into a temporary share on the
                      destination. Nothing lands on the source disk.
            Central - both ends read/write one UNC store on the file server.
            USB     - local or removable drive.
        #>
        switch ($cmbSaveTo.SelectedIndex) {
            1       { return "Central" }
            2       { return "USB" }
            default { return "Direct" }
        }
    }

    function Get-OperationText {
        <#
            Rebuilds the single operation string every downstream branch already
            keys off, from the action/scope pair the user now picks. The strings
            are byte-identical to the old dropdown entries on purpose: the UI
            changed shape, the semantics did not.
        #>
        $scope  = if ($cmbScope.SelectedItem)  { $cmbScope.SelectedItem.ToString() }  else { "Single Profile" }
        $action = if ($cmbAction.SelectedItem) { $cmbAction.SelectedItem.ToString() } else { "Export (ScanState)" }
        # Housekeeping, not a migration: it ignores scope and destination alike.
        if ($action -match "Clean Up")  { return "Clean up USMT files" }
        # Not a migration either: it compares a profile that has ALREADY been
        # moved against the machine it was moved to, and copies only the
        # difference. Scope and Save To mean nothing to it.
        if ($action -match "Compare") { return "Compare & Sync" }
        if ($action -match "Extract") { return "Extract Migration File (UsmtUtils)" }

        $isCombo  = $action -match [regex]::Escape([char]0x21C4)
        $isImport = (-not $isCombo) -and ($action -match "Import")

        if ($scope -match "Computer Settings") {
            if ($isCombo)       { return "$([char]0x21C4) Export + Import Computer Settings (Remote)" }
            elseif ($isImport)  { return "Import Computer Settings (No Profiles)" }
            else                { return "Export Computer Settings (No Profiles)" }
        }
        $scopeWord = if ($scope -match "All Profiles") { "All Profiles" } else { "Single Profile" }
        if ($isCombo)      { return "$([char]0x21C4) Export + Import $scopeWord (Remote)" }
        elseif ($isImport) { return "Import $scopeWord (LoadState)" }
        else               { return "Export $scopeWord (ScanState)" }
    }
    $yPos += 109

    # ---- Collapsible Details Toggle ----
    # ---- Migration Details (extra row for Source PC) ----
    # Sized to the content (rows end at y=136) rather than the old 225. The dead
    # space at the bottom cost ~47px of design height, and design height is the
    # scarce resource once everything is multiplied by 1.75 or more.
    $grpDetails = New-Object System.Windows.Forms.GroupBox; $grpDetails.Text = "  Migration Details  "; $grpDetails.Font = $FontSection; $grpDetails.ForeColor = $t.Primary
    $grpDetails.Location = New-Object System.Drawing.Point(20, $yPos); $grpDetails.Size = New-Object System.Drawing.Size(625, 170); $grpDetails.BackColor = $t.GroupBg
    # No Left+Right anchor: this group lives in the fixed-width setup column,
    # and an anchor captured before that column has a real size stretches it.
    $Form.Controls.Add($grpDetails)

    # Row 1 Left  -  Domain \ Username
    # "Username(s)": the field takes a comma-separated list, which is how one
    # run captures several profiles. A new scope entry was the alternative, but
    # it would have shifted every saved ScopeIndex by one.
    $lblUsername = New-Object System.Windows.Forms.Label; $lblUsername.Text = "Domain \ Username(s):"; $lblUsername.Font = $FontNormal; $lblUsername.ForeColor = $t.Text
    $lblUsername.Location = New-Object System.Drawing.Point(15, 32); $lblUsername.AutoSize = $true; $grpDetails.Controls.Add($lblUsername)
    $txtDomain = New-Object System.Windows.Forms.TextBox; $txtDomain.Font = $FontNormal; $txtDomain.Location = New-Object System.Drawing.Point(15, 54)
    $txtDomain.Size = New-Object System.Drawing.Size(80, 26); $txtDomain.BackColor = $t.MedBg; $txtDomain.ForeColor = $t.Text; $txtDomain.BorderStyle = "FixedSingle"
    $txtDomain.Text = $Script:AppConfig.Domain
    $grpDetails.Controls.Add($txtDomain)
    $lblDomainSlash = New-Object System.Windows.Forms.Label; $lblDomainSlash.Text = "\"; $lblDomainSlash.Font = New-UTWFont "Heading" ([System.Drawing.FontStyle]::Bold) -Mono
    $lblDomainSlash.ForeColor = $t.TextDim; $lblDomainSlash.Location = New-Object System.Drawing.Point(97, 56); $lblDomainSlash.AutoSize = $true; $lblDomainSlash.Tag = "dim"
    $grpDetails.Controls.Add($lblDomainSlash)
    # 128 rather than 183 so the picker button fits the row with a readable
    # LABEL on it. A username that needs more than 128px to read is not a
    # username, and the field is a tooltip away from showing the whole list.
    $txtUsername = New-Object System.Windows.Forms.TextBox; $txtUsername.Font = $FontNormal; $txtUsername.Location = New-Object System.Drawing.Point(112, 54)
    $txtUsername.Size = New-Object System.Drawing.Size(128, 26); $txtUsername.BackColor = $t.MedBg; $txtUsername.ForeColor = $t.Text; $txtUsername.BorderStyle = "FixedSingle"
    $grpDetails.Controls.Add($txtUsername)
    # Typing a username is the single easiest thing to get wrong in this tool -
    # a typo is not discovered until USMT has spent an hour finding nothing.
    # This lists what is actually on the machine and fills the field from it.
    #
    # Labelled "Choose", not "...". Three dots tell a new technician nothing
    # about what is behind them; every button in this window now says what it
    # does before it is pressed.
    $btnPickUser = New-Object System.Windows.Forms.Button; $btnPickUser.Text = "Choose..."; $btnPickUser.Font = $FontSmall
    $btnPickUser.Location = New-Object System.Drawing.Point(244, 53); $btnPickUser.Size = New-Object System.Drawing.Size(72, 28)
    $btnPickUser.FlatStyle = "Flat"; $btnPickUser.BackColor = $t.MedBg; $btnPickUser.ForeColor = $t.Text; $btnPickUser.Tag = "browse"
    $grpDetails.Controls.Add($btnPickUser)

    # Row 1 Right  -  New PC (Export dest) / Old PC (Import source)  -  toggled by updateFields
    $lblNewPC = New-Object System.Windows.Forms.Label; $lblNewPC.Text = "Restore to (new PC):"; $lblNewPC.Font = $FontNormal; $lblNewPC.ForeColor = $t.Text
    $lblNewPC.Location = New-Object System.Drawing.Point(320, 32); $lblNewPC.AutoSize = $true; $grpDetails.Controls.Add($lblNewPC)
    $txtNewPC = New-Object System.Windows.Forms.TextBox; $txtNewPC.Font = $FontNormal; $txtNewPC.Location = New-Object System.Drawing.Point(320, 54)
    $txtNewPC.Size = New-Object System.Drawing.Size(280, 26); $txtNewPC.BackColor = $t.MedBg; $txtNewPC.ForeColor = $t.Text; $txtNewPC.BorderStyle = "FixedSingle"; $grpDetails.Controls.Add($txtNewPC)

    # Row 2 Left  -  Source PC for remote export (blank = local, filled = remote via schtasks)
    $lblSourcePC = New-Object System.Windows.Forms.Label
    $lblSourcePC.Text = "Capture from:"; $lblSourcePC.Font = $FontSmall; $lblSourcePC.ForeColor = $Script:AccentCyan
    $lblSourcePC.Location = New-Object System.Drawing.Point(15, 88); $lblSourcePC.AutoSize = $true; $lblSourcePC.Visible = $false; $lblSourcePC.Tag = "accent-cyan"; $grpDetails.Controls.Add($lblSourcePC)
    $txtSourcePC = New-Object System.Windows.Forms.TextBox; $txtSourcePC.Font = $FontNormal; $txtSourcePC.Location = New-Object System.Drawing.Point(15, 108)
    $txtSourcePC.Size = New-Object System.Drawing.Size(280, 26); $txtSourcePC.BackColor = $t.MedBg; $txtSourcePC.ForeColor = $t.Text; $txtSourcePC.BorderStyle = "FixedSingle"; $txtSourcePC.Visible = $false
    $grpDetails.Controls.Add($txtSourcePC)

    # Row 2 Right  -  drive path. Moved off the left slot: enabling remote
    # captures to a drive means "Capture from" and "Drive path" are now shown
    # together, and they used to be drawn on top of each other. It shares the
    # right slot with the central store box, which it is mutually exclusive with.
    $lblUSBPath = New-Object System.Windows.Forms.Label; $lblUSBPath.Text = "Drive path:"; $lblUSBPath.Font = $FontNormal; $lblUSBPath.ForeColor = $t.Text
    $lblUSBPath.Location = New-Object System.Drawing.Point(320, 88); $lblUSBPath.AutoSize = $true; $lblUSBPath.Visible = $false; $grpDetails.Controls.Add($lblUSBPath)
    $txtUSBPath = New-Object System.Windows.Forms.TextBox; $txtUSBPath.Font = $FontNormal; $txtUSBPath.Location = New-Object System.Drawing.Point(320, 110)
    $txtUSBPath.Size = New-Object System.Drawing.Size(187, 26); $txtUSBPath.BackColor = $t.MedBg; $txtUSBPath.ForeColor = $t.Text; $txtUSBPath.BorderStyle = "FixedSingle"; $txtUSBPath.Text = "D:\"; $txtUSBPath.Visible = $false; $grpDetails.Controls.Add($txtUSBPath)
    $btnBrowseUSB = New-Object System.Windows.Forms.Button; $btnBrowseUSB.Text = "Browse..."; $btnBrowseUSB.Font = $FontSmall
    $btnBrowseUSB.Location = New-Object System.Drawing.Point(515, 108); $btnBrowseUSB.Size = New-Object System.Drawing.Size(85, 28)
    $btnBrowseUSB.FlatStyle = "Flat"; $btnBrowseUSB.BackColor = $t.MedBg; $btnBrowseUSB.ForeColor = $t.Text; $btnBrowseUSB.Visible = $false; $btnBrowseUSB.Tag = "browse"; $grpDetails.Controls.Add($btnBrowseUSB)
    $btnBrowseUSB.Add_Click({ $fd = New-Object System.Windows.Forms.FolderBrowserDialog; if ($fd.ShowDialog($Form) -eq "OK") { $txtUSBPath.Text = $fd.SelectedPath } })
    $txtUSBPath.Add_TextChanged({
        if ($Script:OptionTip) { $Script:OptionTip.SetToolTip($txtUSBPath, $txtUSBPath.Text) }
    })
    # Enter tidies a typed or pasted path. It cannot be checked for existence -
    # the drive usually belongs to the machine being captured, not this one.
    $txtUSBPath.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $_.Handled = $true; $_.SuppressKeyPress = $true
            $t = $txtUSBPath.Text.Trim().Trim('"')
            if ($t -match '^[A-Za-z]$')  { $t = "$t`:\" }
            if ($t -match '^[A-Za-z]:$') { $t = "$t\" }
            $txtUSBPath.Text = $t
        }
    })

    # Half of the source/destination pair when they share row 2. The row runs
    # 15..600, so two equal boxes and the arrow gap between them come to
    # 265 + 55 + 265 = 585. Update-Fields applies it to both boxes.
    $Script:PairBoxWidth = 265

    # Find-in-AD buttons for the two machine fields.
    #
    # The word "Find", not a magnifying-glass glyph. U+1F50D is outside the
    # Basic Multilingual Plane, so [char] cannot hold it at all - it is a
    # surrogate pair and the cast throws, which took the whole window down
    # before it finished building. Every other glyph in this tool is under
    # U+FFFF; see the guard test that now enforces that. A word also reads
    # better at this size than any icon would.
    #
    # 56, not 42: at 42 the word was being clipped to "Fin" once the button had
    # its border and padding, and clipped worse at 175% where the font rounds up
    # faster than the box does.
    $Script:FindBtnWidth = 56
    $btnFindSrc = New-Object System.Windows.Forms.Button; $btnFindSrc.Text = "Find"; $btnFindSrc.Font = $FontSmall
    $btnFindSrc.Size = New-Object System.Drawing.Size($Script:FindBtnWidth, 26)
    $btnFindSrc.FlatStyle = "Flat"; $btnFindSrc.BackColor = $t.MedBg; $btnFindSrc.ForeColor = $t.Text; $btnFindSrc.Tag = "browse"
    $btnFindSrc.Visible = $false
    $grpDetails.Controls.Add($btnFindSrc)
    $btnFindDst = New-Object System.Windows.Forms.Button; $btnFindDst.Text = "Find"; $btnFindDst.Font = $FontSmall
    $btnFindDst.Size = New-Object System.Drawing.Size($Script:FindBtnWidth, 26)
    $btnFindDst.FlatStyle = "Flat"; $btnFindDst.BackColor = $t.MedBg; $btnFindDst.ForeColor = $t.Text; $btnFindDst.Tag = "browse"
    $btnFindDst.Visible = $false
    $grpDetails.Controls.Add($btnFindDst)

    # Sits between the two machine boxes when they share row 2, so the direction
    # of the migration is shown rather than described. It spans the whole gap
    # with its glyph centred, which lands the arrow on the row's midpoint.
    $lblRouteArrow = New-Object System.Windows.Forms.Label
    $lblRouteArrow.Text = [string][char]0x2192
    $lblRouteArrow.Font = New-UTWFont "Title" ([System.Drawing.FontStyle]::Bold)
    $lblRouteArrow.ForeColor = $Script:AccentCyan; $lblRouteArrow.Tag = "accent-cyan"
    $lblRouteArrow.AutoSize = $false
    $lblRouteArrow.Size = New-Object System.Drawing.Size(55, 26)
    $lblRouteArrow.TextAlign = "MiddleCenter"
    $lblRouteArrow.Location = New-Object System.Drawing.Point(280, 108)
    $lblRouteArrow.Visible = $false
    $grpDetails.Controls.Add($lblRouteArrow)

    # Row 2 Left  -  the store to restore (Import only). An import no longer
    # guesses the store from a naming convention; it is pointed at one.
    $lblImportStore = New-Object System.Windows.Forms.Label; $lblImportStore.Text = "Migration file to restore (.mig):"; $lblImportStore.Font = $FontNormal; $lblImportStore.ForeColor = $t.Text
    $lblImportStore.Location = New-Object System.Drawing.Point(15, 88); $lblImportStore.AutoSize = $true; $lblImportStore.Visible = $false; $grpDetails.Controls.Add($lblImportStore)
    $txtImportStore = New-Object System.Windows.Forms.TextBox; $txtImportStore.Font = $FontNormal; $txtImportStore.Location = New-Object System.Drawing.Point(15, 110)
    # 365 rather than 490: the row carries two buttons, both labelled with what
    # they do. "Pick store" lists every store in a folder with who and when, so
    # you can recognise the right one; "Folder..." points straight at a store
    # whose path you already know.
    $txtImportStore.Size = New-Object System.Drawing.Size(365, 26); $txtImportStore.BackColor = $t.MedBg; $txtImportStore.ForeColor = $t.Text; $txtImportStore.BorderStyle = "FixedSingle"
    $txtImportStore.Visible = $false; $grpDetails.Controls.Add($txtImportStore)
    $btnBrowseStoreList = New-Object System.Windows.Forms.Button; $btnBrowseStoreList.Text = "Pick store..."; $btnBrowseStoreList.Font = $FontSmall
    $btnBrowseStoreList.Location = New-Object System.Drawing.Point(388, 108); $btnBrowseStoreList.Size = New-Object System.Drawing.Size(100, 28)
    $btnBrowseStoreList.FlatStyle = "Flat"; $btnBrowseStoreList.BackColor = $t.MedBg; $btnBrowseStoreList.ForeColor = $t.Text
    $btnBrowseStoreList.Visible = $false; $btnBrowseStoreList.Tag = "browse"; $grpDetails.Controls.Add($btnBrowseStoreList)
    $btnBrowseImportStore = New-Object System.Windows.Forms.Button; $btnBrowseImportStore.Text = "Folder..."; $btnBrowseImportStore.Font = $FontSmall
    $btnBrowseImportStore.Location = New-Object System.Drawing.Point(496, 108); $btnBrowseImportStore.Size = New-Object System.Drawing.Size(104, 28)
    $btnBrowseImportStore.FlatStyle = "Flat"; $btnBrowseImportStore.BackColor = $t.MedBg; $btnBrowseImportStore.ForeColor = $t.Text; $btnBrowseImportStore.Visible = $false; $btnBrowseImportStore.Tag = "browse"; $grpDetails.Controls.Add($btnBrowseImportStore)
    $btnBrowseImportStore.Add_Click({
        $fd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fd.Description = "Pick the store folder (the one holding USMT\USMT.MIG)"
        if ($fd.ShowDialog($Form) -eq "OK") {
            # Accept the store root, the USMT subfolder, or anything that
            # resolves to one - people reasonably click any of the three.
            $r = Resolve-StoreRoot $fd.SelectedPath
            $txtImportStore.Text = if ($r) { $r } else { $fd.SelectedPath }
        }
    })
    $txtImportStore.Add_TextChanged({
        if ($Script:OptionTip) { $Script:OptionTip.SetToolTip($txtImportStore, $txtImportStore.Text) }
    })
    # Typed or pasted paths are first-class - Enter normalises whatever form was
    # given (store root, USMT folder, or the .mig itself) to the store root.
    $txtImportStore.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $_.Handled = $true; $_.SuppressKeyPress = $true
            $t = $txtImportStore.Text.Trim().Trim('"')
            if ($t) {
                $r = Resolve-StoreRoot $t
                if ($r) { $txtImportStore.Text = $r }
                else    { Show-ThemedMessage "That is not a USMT store:`n$t`n`nPoint at the folder holding USMT\USMT.MIG." "Migration File" "OK" "Warning" }
            }
        }
    })

    # Row 2 Right  -  central store root (Central mode). Sits opposite Source PC
    # because that is the only slot free in every mode that needs both.
    $lblCentralPath = New-Object System.Windows.Forms.Label; $lblCentralPath.Text = "Server Share (\\server\share\...):"; $lblCentralPath.Font = $FontNormal; $lblCentralPath.ForeColor = $t.Text
    $lblCentralPath.Location = New-Object System.Drawing.Point(320, 88); $lblCentralPath.AutoSize = $true; $lblCentralPath.Visible = $false; $grpDetails.Controls.Add($lblCentralPath)
    $txtCentralPath = New-Object System.Windows.Forms.TextBox; $txtCentralPath.Font = $FontNormal; $txtCentralPath.Location = New-Object System.Drawing.Point(320, 110)
    $txtCentralPath.Size = New-Object System.Drawing.Size(187, 26); $txtCentralPath.BackColor = $t.MedBg; $txtCentralPath.ForeColor = $t.Text; $txtCentralPath.BorderStyle = "FixedSingle"
    $txtCentralPath.Visible = $false; $grpDetails.Controls.Add($txtCentralPath)
    $btnBrowseCentral = New-Object System.Windows.Forms.Button; $btnBrowseCentral.Text = "Browse..."; $btnBrowseCentral.Font = $FontSmall
    $btnBrowseCentral.Location = New-Object System.Drawing.Point(515, 108); $btnBrowseCentral.Size = New-Object System.Drawing.Size(85, 28)
    $btnBrowseCentral.FlatStyle = "Flat"; $btnBrowseCentral.BackColor = $t.MedBg; $btnBrowseCentral.ForeColor = $t.Text; $btnBrowseCentral.Visible = $false; $btnBrowseCentral.Tag = "browse"; $grpDetails.Controls.Add($btnBrowseCentral)
    $btnBrowseCentral.Add_Click({ $fd = New-Object System.Windows.Forms.FolderBrowserDialog; if ($fd.ShowDialog($Form) -eq "OK") { $txtCentralPath.Text = $fd.SelectedPath } })
    # The box is too narrow for a real UNC path, so hovering shows all of it.
    $txtCentralPath.Add_TextChanged({
        if ($Script:OptionTip) { $Script:OptionTip.SetToolTip($txtCentralPath, $txtCentralPath.Text) }
    })

    # Extract-only fields
    $lblMigrationFile = New-Object System.Windows.Forms.Label; $lblMigrationFile.Text = "Migration File (.MIG):"; $lblMigrationFile.Font = $FontNormal; $lblMigrationFile.ForeColor = $t.Text
    $lblMigrationFile.Location = New-Object System.Drawing.Point(15, 32); $lblMigrationFile.AutoSize = $true; $lblMigrationFile.Visible = $false; $grpDetails.Controls.Add($lblMigrationFile)
    $txtMigrationFile = New-Object System.Windows.Forms.TextBox; $txtMigrationFile.Font = $FontNormal; $txtMigrationFile.Location = New-Object System.Drawing.Point(15, 54)
    $txtMigrationFile.Size = New-Object System.Drawing.Size(490, 26); $txtMigrationFile.BackColor = $t.MedBg; $txtMigrationFile.ForeColor = $t.Text; $txtMigrationFile.BorderStyle = "FixedSingle"; $txtMigrationFile.Visible = $false; $txtMigrationFile.ReadOnly = $true; $grpDetails.Controls.Add($txtMigrationFile)
    $btnBrowseMig = New-Object System.Windows.Forms.Button; $btnBrowseMig.Text = "Browse..."; $btnBrowseMig.Font = $FontNormal
    $btnBrowseMig.Location = New-Object System.Drawing.Point(515, 52); $btnBrowseMig.Size = New-Object System.Drawing.Size(85, 28)
    $btnBrowseMig.FlatStyle = "Flat"; $btnBrowseMig.BackColor = $t.MedBg; $btnBrowseMig.ForeColor = $t.Text; $btnBrowseMig.Visible = $false; $btnBrowseMig.Tag = "browse"; $grpDetails.Controls.Add($btnBrowseMig)
    $btnBrowseMig.Add_Click({ $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = "Migration Files (*.mig)|*.mig|All Files (*.*)|*.*"; if ($ofd.ShowDialog($Form) -eq "OK") { $txtMigrationFile.Text = $ofd.FileName } })
    $lblExtractPath = New-Object System.Windows.Forms.Label; $lblExtractPath.Text = "Extract Destination:"; $lblExtractPath.Font = $FontNormal; $lblExtractPath.ForeColor = $t.Text
    $lblExtractPath.Location = New-Object System.Drawing.Point(15, 88); $lblExtractPath.AutoSize = $true; $lblExtractPath.Visible = $false; $grpDetails.Controls.Add($lblExtractPath)
    $txtExtractPath = New-Object System.Windows.Forms.TextBox; $txtExtractPath.Font = $FontNormal; $txtExtractPath.Location = New-Object System.Drawing.Point(15, 110)
    $txtExtractPath.Size = New-Object System.Drawing.Size(490, 26); $txtExtractPath.BackColor = $t.MedBg; $txtExtractPath.ForeColor = $t.Text; $txtExtractPath.BorderStyle = "FixedSingle"; $txtExtractPath.Visible = $false; $grpDetails.Controls.Add($txtExtractPath)
    $btnBrowseExtract = New-Object System.Windows.Forms.Button; $btnBrowseExtract.Text = "Browse..."; $btnBrowseExtract.Font = $FontNormal
    $btnBrowseExtract.Location = New-Object System.Drawing.Point(515, 108); $btnBrowseExtract.Size = New-Object System.Drawing.Size(85, 28)
    $btnBrowseExtract.FlatStyle = "Flat"; $btnBrowseExtract.BackColor = $t.MedBg; $btnBrowseExtract.ForeColor = $t.Text; $btnBrowseExtract.Visible = $false; $btnBrowseExtract.Tag = "browse"; $grpDetails.Controls.Add($btnBrowseExtract)
    $btnBrowseExtract.Add_Click({ $fd = New-Object System.Windows.Forms.FolderBrowserDialog; if ($fd.ShowDialog($Form) -eq "OK") { $txtExtractPath.Text = $fd.SelectedPath } })

    $lblCurrentPC = New-Object System.Windows.Forms.Label; $lblCurrentPC.Text = "This Computer: $env:COMPUTERNAME"
    $lblCurrentPC.Font = $FontSmall; $lblCurrentPC.ForeColor = $t.TextDim; $lblCurrentPC.Location = New-Object System.Drawing.Point(15, 144); $lblCurrentPC.AutoSize = $true; $lblCurrentPC.Tag = "dim"
    $grpDetails.Controls.Add($lblCurrentPC)

    # All-profiles info label (shown in place of username when All Profiles is selected)
    $lblAllProfilesHint = New-Object System.Windows.Forms.Label
    # Short enough to clear the destination box at x=320 - the longer wording
    # ran to x~352 and struck it whenever the scope was All Profiles.
    $lblAllProfilesHint.Text = "(no username needed)"
    $lblAllProfilesHint.Font = $FontSmall; $lblAllProfilesHint.ForeColor = $Script:AccentCyan
    $lblAllProfilesHint.Location = New-Object System.Drawing.Point(112, 58); $lblAllProfilesHint.AutoSize = $true
    $lblAllProfilesHint.Visible = $false; $lblAllProfilesHint.Tag = "accent-cyan"
    $grpDetails.Controls.Add($lblAllProfilesHint)

    # Settings-only info label (shown when Computer Settings mode is selected)
    $lblSettingsHint = New-Object System.Windows.Forms.Label
    # Kept short: at its old length this ran to x~345 and struck the
    # destination label in the opposite corner whenever the scope was settings.
    $lblSettingsHint.Text = "System settings only (no user profiles)"
    $lblSettingsHint.Font = $FontSmall; $lblSettingsHint.ForeColor = $Script:AccentCyan
    $lblSettingsHint.Location = New-Object System.Drawing.Point(15, 38); $lblSettingsHint.AutoSize = $true
    $lblSettingsHint.Visible = $false; $lblSettingsHint.Tag = "accent-cyan"
    $grpDetails.Controls.Add($lblSettingsHint)

    $yPos += 178


    # ---- Options ----
    $grpOptions = New-Object System.Windows.Forms.GroupBox; $grpOptions.Text = "  Options  "; $grpOptions.Font = $FontSection; $grpOptions.ForeColor = $t.Primary
    # 156, not 134: a fifth row was added to the left column for the stale
    # profile cleanup. Everything below moves down with $yPos, which is why the
    # advance at the end of this group changed to match.
    $grpOptions.Location = New-Object System.Drawing.Point(20, $yPos); $grpOptions.Size = New-Object System.Drawing.Size(625, 156); $grpOptions.BackColor = $t.GroupBg
    # No Left+Right anchor: this group lives in the fixed-width setup column,
    # and an anchor captured before that column has a real size stretches it.
    $Form.Controls.Add($grpOptions)
    # Two columns: what the migration does on the left, what it verifies before
    # starting on the right. The checks are all phrased positively - "Skip
    # profile check" used to be the odd one out, a negative toggle sitting
    # beside positives, which made the row hard to read at a glance.
    # The two headers now say what the column IS, not what it is about.
    # "Migration" and "Pre-checks" were category names; a technician reading the
    # panel for the first time has to work out from the entries underneath which
    # ones change the run and which ones only look before it.
    $lblOptStore = New-Object System.Windows.Forms.Label; $lblOptStore.Text = "What the run does"
    $lblOptStore.Font = New-UTWFont "Small" ([System.Drawing.FontStyle]::Bold)
    $lblOptStore.ForeColor = $t.TextDim; $lblOptStore.Tag = "dim"
    $lblOptStore.Location = New-Object System.Drawing.Point(15, 20); $lblOptStore.AutoSize = $true
    $grpOptions.Controls.Add($lblOptStore)
    $lblOptChecks = New-Object System.Windows.Forms.Label; $lblOptChecks.Text = "Checked before it starts"
    $lblOptChecks.Font = New-UTWFont "Small" ([System.Drawing.FontStyle]::Bold)
    $lblOptChecks.ForeColor = $t.TextDim; $lblOptChecks.Tag = "dim"
    $lblOptChecks.Location = New-Object System.Drawing.Point(325, 20); $lblOptChecks.AutoSize = $true
    $grpOptions.Controls.Add($lblOptChecks)
    # A hairline between the columns. Two lists of ticks side by side read as one
    # jumbled block without it; one pixel of separation is enough to stop that.
    $pnlOptRule = New-Object System.Windows.Forms.Panel
    $pnlOptRule.Location = New-Object System.Drawing.Point(308, 22)
    $pnlOptRule.Size = New-Object System.Drawing.Size(1, 122)
    $pnlOptRule.BackColor = (Get-DividerColor); $pnlOptRule.Tag = "rule"
    $grpOptions.Controls.Add($pnlOptRule)

    $chkOverwrite = New-Object System.Windows.Forms.CheckBox; $chkOverwrite.Text = "Overwrite an existing store"; $chkOverwrite.Font = $FontNormal; $chkOverwrite.ForeColor = $t.Text
    $chkOverwrite.Location = New-Object System.Drawing.Point(15, 38); $chkOverwrite.AutoSize = $true; $grpOptions.Controls.Add($chkOverwrite)
    $chkCleanup = New-Object System.Windows.Forms.CheckBox; $chkCleanup.Text = "Delete store after successful import"; $chkCleanup.Font = $FontNormal; $chkCleanup.ForeColor = $t.Text
    $chkCleanup.Location = New-Object System.Drawing.Point(15, 60); $chkCleanup.AutoSize = $true; $grpOptions.Controls.Add($chkCleanup)
    # Was two extra entries in the operation list. It only ever affected a
    # single-profile ScanState, so it is an option on the export, not a
    # separate operation - greyed out whenever it would do nothing.
    $chkExcludeOneDrive = New-Object System.Windows.Forms.CheckBox; $chkExcludeOneDrive.Text = "Exclude OneDrive folders"
    $chkExcludeOneDrive.Font = $FontNormal; $chkExcludeOneDrive.ForeColor = $t.Text
    $chkCleanStores = New-Object System.Windows.Forms.CheckBox; $chkCleanStores.Text = "Also remove old migration stores"
    $chkCleanStores.Font = $FontNormal; $chkCleanStores.ForeColor = $t.Text
    $chkCleanStores.Location = New-Object System.Drawing.Point(15, 104); $chkCleanStores.AutoSize = $true
    $grpOptions.Controls.Add($chkCleanStores)
    $chkExcludeOneDrive.Location = New-Object System.Drawing.Point(15, 82); $chkExcludeOneDrive.AutoSize = $true
    $grpOptions.Controls.Add($chkExcludeOneDrive)

    $chkVerifyProfile = New-Object System.Windows.Forms.CheckBox; $chkVerifyProfile.Text = "Profile exists on source"
    $chkVerifyProfile.Font = $FontNormal; $chkVerifyProfile.ForeColor = $t.Text
    $chkVerifyProfile.Location = New-Object System.Drawing.Point(325, 38); $chkVerifyProfile.AutoSize = $true
    $chkVerifyProfile.Checked = $true
    $grpOptions.Controls.Add($chkVerifyProfile)
    $chkCheckDisk = New-Object System.Windows.Forms.CheckBox; $chkCheckDisk.Text = "Free disk space"
    $chkCheckDisk.Font = $FontNormal; $chkCheckDisk.ForeColor = $t.Text
    $chkCheckDisk.Location = New-Object System.Drawing.Point(325, 60); $chkCheckDisk.AutoSize = $true
    $chkCheckDisk.Checked = $true
    $grpOptions.Controls.Add($chkCheckDisk)
    $chkCheckInactive = New-Object System.Windows.Forms.CheckBox; $chkCheckInactive.Text = "Inactive / stale profiles"
    $chkCheckInactive.Font = $FontNormal; $chkCheckInactive.ForeColor = $t.Text
    $chkCheckInactive.Location = New-Object System.Drawing.Point(325, 82); $chkCheckInactive.AutoSize = $true
    $chkCheckInactive.Checked = $true
    $grpOptions.Controls.Add($chkCheckInactive)
    # Off by default: it costs a full no-write scan pass up front, which is the
    # right trade only when the store size is actually in doubt.
    $chkEstimateSize = New-Object System.Windows.Forms.CheckBox; $chkEstimateSize.Text = "Measure profile size"
    $chkEstimateSize.Font = $FontNormal; $chkEstimateSize.ForeColor = $t.Text
    $chkEstimateSize.Location = New-Object System.Drawing.Point(325, 104); $chkEstimateSize.AutoSize = $true
    $grpOptions.Controls.Add($chkEstimateSize)

    # Fifth row of the Migration column. Clean-up only, like "delete old stores"
    # above it, and off by default - it removes accounts, not tooling.
    $chkCleanProfiles = New-Object System.Windows.Forms.CheckBox
    $chkCleanProfiles.Text = "Delete stale user profiles"
    $chkCleanProfiles.Font = $FontNormal; $chkCleanProfiles.ForeColor = $t.Text
    $chkCleanProfiles.Location = New-Object System.Drawing.Point(15, 126); $chkCleanProfiles.AutoSize = $true
    $grpOptions.Controls.Add($chkCleanProfiles)

    $Script:OptionTip = New-Object System.Windows.Forms.ToolTip

    function Format-Tip {
        <#
            Word-wraps tooltip text. WinForms renders a tooltip as one enormous
            single line otherwise, which on the longer explanations here runs
            most of the way across a 4K screen and is unreadable.
        #>
        param([string]$Text, [int]$Width = 58)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
        # Memoized. Update-Fields re-applies all thirty tooltips every time it
        # runs, and it runs on every operation change and at several points
        # during startup - so the same dozen paragraphs were being re-wrapped
        # word by word, hundreds of times, for a result that cannot change.
        if (-not $Script:TipCache) { $Script:TipCache = @{} }
        $ck = "$Width|$Text"
        if ($Script:TipCache.ContainsKey($ck)) { return $Script:TipCache[$ck] }
        $out = @()
        # Honour paragraph breaks the caller put in, wrap within each.
        foreach ($para in ($Text -split "`n")) {
            $line = ""
            foreach ($w in ($para -split '\s+' | Where-Object { $_ })) {
                if ($line -and (($line.Length + 1 + $w.Length) -gt $Width)) { $out += $line; $line = $w }
                else { $line = if ($line) { "$line $w" } else { $w } }
            }
            $out += $line
        }
        $wrapped = ($out -join "`r`n")
        $Script:TipCache[$ck] = $wrapped
        return $wrapped
    }

    function Set-Tip {
        param($Control, [string]$Text)
        if ($Control -and $Script:OptionTip) { $Script:OptionTip.SetToolTip($Control, (Format-Tip $Text)) }
    }
    $Script:OptionTip.InitialDelay = 400; $Script:OptionTip.AutoPopDelay = 15000
    $yPos += 164

    # ---- Expert panel  -  the actual command line, editable ----
    # Sits between Options and Actions because that is the reading order of the
    # thing it describes: choose what to do, see what that produces, run it.
    # Hidden entirely in Simple mode, and it costs no layout height there.
    $grpExpert = New-Object System.Windows.Forms.GroupBox
    $grpExpert.Text = "  Expert  "; $grpExpert.Font = $FontSection; $grpExpert.ForeColor = $t.Primary
    $grpExpert.Location = New-Object System.Drawing.Point(20, $yPos)
    $grpExpert.Size = New-Object System.Drawing.Size(625, 384); $grpExpert.BackColor = $t.GroupBg
    # No Left+Right anchor: this group lives in the fixed-width setup column,
    # and an anchor captured before that column has a real size stretches it.
    $grpExpert.Visible = $false
    $Form.Controls.Add($grpExpert)

    $lblExpertHint = New-Object System.Windows.Forms.Label
    $lblExpertHint.Text = "Exactly what will run. Edit it and the Options above follow; tick an option and this follows. Anything UTW does not model is kept as you typed it."
    $lblExpertHint.Font = $FontSmall; $lblExpertHint.ForeColor = $t.TextDim; $lblExpertHint.Tag = "dim"
    $lblExpertHint.AutoSize = $false
    $lblExpertHint.Location = New-Object System.Drawing.Point(15, 20)
    $lblExpertHint.Size = New-Object System.Drawing.Size(595, 30)
    $grpExpert.Controls.Add($lblExpertHint)

    $txtCommand = New-Object System.Windows.Forms.TextBox
    # NOT word-wrapped. Wrapping was tried and it is worse: a command line is a
    # sequence of discrete switches, and reflowing it into a justified paragraph
    # breaks /ue: and /ui: arguments across lines mid-path, so the thing you are
    # scanning for stops being findable. Each switch keeps its position on one
    # long line, and the panel is resizable now - drag the divider right and the
    # whole command is on screen without scrolling anywhere.
    $txtCommand.Multiline = $true; $txtCommand.ScrollBars = "Both"; $txtCommand.WordWrap = $false
    $txtCommand.Font = $FontMono
    $txtCommand.Location = New-Object System.Drawing.Point(15, 52)
    $txtCommand.Size = New-Object System.Drawing.Size(595, 132)
    $txtCommand.BackColor = $t.DarkBg; $txtCommand.ForeColor = $t.Text; $txtCommand.BorderStyle = "FixedSingle"
    # Not an ordinary input: it is painted on the FORM colour so it reads as a
    # console. Apply-Theme needs the tag to keep it that way.
    $txtCommand.Tag = "command"
    $txtCommand.AcceptsTab = $false
    $grpExpert.Controls.Add($txtCommand)

    $lblExpertState = New-Object System.Windows.Forms.Label
    $lblExpertState.Text = "generated"
    $lblExpertState.Font = $FontSmall; $lblExpertState.ForeColor = $t.TextDim; $lblExpertState.Tag = "dim"
    $lblExpertState.AutoSize = $false; $lblExpertState.TextAlign = "MiddleLeft"
    # Row: state text on the left, the three command buttons right-aligned to
    # the panel edge so they read as one group rather than a scattered row.
    $lblExpertState.Location = New-Object System.Drawing.Point(15, 192)
    $lblExpertState.Size = New-Object System.Drawing.Size(337, 26)
    $grpExpert.Controls.Add($lblExpertState)

    $btnCmdRevert = New-Object System.Windows.Forms.Button; $btnCmdRevert.Text = "Regenerate"; $btnCmdRevert.Font = $FontSmall
    $btnCmdRevert.Location = New-Object System.Drawing.Point(358, 190); $btnCmdRevert.Size = New-Object System.Drawing.Size(96, 28)
    $btnCmdRevert.FlatStyle = "Flat"; $btnCmdRevert.BackColor = $t.MedBg; $btnCmdRevert.ForeColor = $t.Text; $btnCmdRevert.Tag = "browse"
    $grpExpert.Controls.Add($btnCmdRevert)

    $btnCmdCopy = New-Object System.Windows.Forms.Button; $btnCmdCopy.Text = "Copy"; $btnCmdCopy.Font = $FontSmall
    $btnCmdCopy.Location = New-Object System.Drawing.Point(460, 190); $btnCmdCopy.Size = New-Object System.Drawing.Size(72, 28)
    $btnCmdCopy.FlatStyle = "Flat"; $btnCmdCopy.BackColor = $t.MedBg; $btnCmdCopy.ForeColor = $t.Text; $btnCmdCopy.Tag = "browse"
    $grpExpert.Controls.Add($btnCmdCopy)

    $btnCmdPaste = New-Object System.Windows.Forms.Button; $btnCmdPaste.Text = "Paste"; $btnCmdPaste.Font = $FontSmall
    $btnCmdPaste.Location = New-Object System.Drawing.Point(538, 190); $btnCmdPaste.Size = New-Object System.Drawing.Size(72, 28)
    $btnCmdPaste.FlatStyle = "Flat"; $btnCmdPaste.BackColor = $t.MedBg; $btnCmdPaste.ForeColor = $t.Text; $btnCmdPaste.Tag = "browse"
    $grpExpert.Controls.Add($btnCmdPaste)

    # ---- USMT build ----
    # Everything in this fleet is 64-bit, so this stays on Auto and only ever matters
    # for a stray 32-bit machine. Auto asks the target what it is; the explicit
    # settings are for when it cannot be asked.
    #
    # ABOVE the danger section, not below it. Choosing a build and saving a log
    # are ordinary settings, and burying them under a red warning block made
    # them look like part of it.
    $lblArch = New-Object System.Windows.Forms.Label; $lblArch.Text = "USMT build:"
    $lblArch.Font = $FontSmall; $lblArch.ForeColor = $t.Text
    $lblArch.AutoSize = $false; $lblArch.Size = New-Object System.Drawing.Size(74, 20); $lblArch.TextAlign = "MiddleRight"
    $lblArch.Location = New-Object System.Drawing.Point(15, 230)
    $grpExpert.Controls.Add($lblArch)
    $cmbArch = New-Object System.Windows.Forms.ComboBox; $cmbArch.Font = $FontNormal
    $cmbArch.Location = New-Object System.Drawing.Point(95, 228); $cmbArch.Size = New-Object System.Drawing.Size(150, 24)
    $cmbArch.DropDownStyle = "DropDownList"; $cmbArch.BackColor = $t.MedBg; $cmbArch.ForeColor = $t.Text; $cmbArch.FlatStyle = "Flat"
    $cmbArch.Items.AddRange(@("Auto (ask the PC)", "64-bit (amd64)", "32-bit (x86)"))
    $cmbArch.SelectedIndex = 0
    $grpExpert.Controls.Add($cmbArch)
    $lblArchHint = New-Object System.Windows.Forms.Label
    $lblArchHint.Text = "32-bit needs a USMT\x86 folder beside the 64-bit one."
    $lblArchHint.Font = $FontSmall; $lblArchHint.ForeColor = $t.TextDim; $lblArchHint.Tag = "dim"
    $lblArchHint.AutoSize = $false
    $lblArchHint.Location = New-Object System.Drawing.Point(255, 231)
    $lblArchHint.Size = New-Object System.Drawing.Size(345, 18)
    $grpExpert.Controls.Add($lblArchHint)

    $chkLogOnExit = New-Object System.Windows.Forms.CheckBox
    $chkLogOnExit.Text = "Save this window's log automatically on exit"
    $chkLogOnExit.Font = $FontNormal; $chkLogOnExit.ForeColor = $t.Text
    $chkLogOnExit.Location = New-Object System.Drawing.Point(15, 258); $chkLogOnExit.AutoSize = $true
    $grpExpert.Controls.Add($chkLogOnExit)

    # ---- Destructive / advanced options ----
    # LAST in the panel, and fenced off. Both of these change what happens to
    # somebody's data in ways that cannot be undone, so they live behind Expert
    # mode, are off by default, sit below everything harmless, and are drawn in
    # the error colour with a warning sign on every line. They are not
    # conveniences and the panel should not let them look like any.
    $pnlDangerRule = New-Object System.Windows.Forms.Panel
    $pnlDangerRule.Location = New-Object System.Drawing.Point(15, 292)
    $pnlDangerRule.Size = New-Object System.Drawing.Size(595, 2)
    $pnlDangerRule.BackColor = $t.Error; $pnlDangerRule.Tag = "danger-rule"
    $grpExpert.Controls.Add($pnlDangerRule)

    $lblDangerSection = New-Object System.Windows.Forms.Label
    $lblDangerSection.Text = "$($Script:WarningSign)  ADVANCED - these change or destroy data"
    $lblDangerSection.Font = New-UTWFont 9 ([System.Drawing.FontStyle]::Bold)
    $lblDangerSection.ForeColor = $t.Error; $lblDangerSection.Tag = "danger-head"
    $lblDangerSection.Location = New-Object System.Drawing.Point(15, 300); $lblDangerSection.AutoSize = $true
    $grpExpert.Controls.Add($lblDangerSection)

    $chkRenameOnRestore = New-Object System.Windows.Forms.CheckBox
    $chkRenameOnRestore.Text = "$($Script:WarningSign) Restore under a different account"
    $chkRenameOnRestore.Font = $FontNormal; $chkRenameOnRestore.ForeColor = $t.Error; $chkRenameOnRestore.Tag = "danger"
    $chkRenameOnRestore.Location = New-Object System.Drawing.Point(15, 324); $chkRenameOnRestore.AutoSize = $true
    $grpExpert.Controls.Add($chkRenameOnRestore)
    $lblRenameTo = New-Object System.Windows.Forms.Label; $lblRenameTo.Text = "as:"
    $lblRenameTo.Font = $FontSmall; $lblRenameTo.ForeColor = $t.Text
    $lblRenameTo.AutoSize = $false; $lblRenameTo.Size = New-Object System.Drawing.Size(24, 20); $lblRenameTo.TextAlign = "MiddleRight"
    $lblRenameTo.Location = New-Object System.Drawing.Point(266, 326)
    $grpExpert.Controls.Add($lblRenameTo)
    $txtRenameTo = New-Object System.Windows.Forms.TextBox; $txtRenameTo.Font = $FontNormal
    $txtRenameTo.Location = New-Object System.Drawing.Point(294, 324); $txtRenameTo.Size = New-Object System.Drawing.Size(150, 24)
    $txtRenameTo.BackColor = $t.MedBg; $txtRenameTo.ForeColor = $t.Text; $txtRenameTo.BorderStyle = "FixedSingle"
    $txtRenameTo.Enabled = $false
    $grpExpert.Controls.Add($txtRenameTo)

    $chkDeleteSource = New-Object System.Windows.Forms.CheckBox
    $chkDeleteSource.Text = "$($Script:WarningSign) Delete the profile from the old PC after a successful capture"
    $chkDeleteSource.Font = $FontNormal; $chkDeleteSource.ForeColor = $t.Error; $chkDeleteSource.Tag = "danger"
    $chkDeleteSource.Location = New-Object System.Drawing.Point(15, 352); $chkDeleteSource.AutoSize = $true
    $grpExpert.Controls.Add($chkDeleteSource)

    # ---- Settings that used to be duplicated here ----
    # OneDrive detection and the log folder were BOTH on this panel and in
    # File > Settings, which is one place too many for a value you set once for
    # the site and then never touch. Settings is the one that survives - it is
    # where every other site-wide default already lives, and it is reachable
    # without turning Expert mode on.
    #
    # The controls themselves stay alive in an off-screen holder: they are the
    # storage the settings editor, the saved-settings file, the New Window
    # hand-off and Get-ODPattern / Get-ODMinBytes all read and write. Deleting
    # them would mean rewriting six unrelated code paths to remove one panel.
    $pnlStash = New-Object System.Windows.Forms.Panel
    $pnlStash.Size = New-Object System.Drawing.Size(0, 0)
    $pnlStash.Location = New-Object System.Drawing.Point(0, 0)
    $pnlStash.Visible = $false
    $grpExpert.Controls.Add($pnlStash)

    $chkODDetect = New-Object System.Windows.Forms.CheckBox
    $chkODDetect.Text = "Check before capture"; $chkODDetect.Font = $FontNormal; $chkODDetect.ForeColor = $t.Text
    $chkODDetect.AutoSize = $true; $chkODDetect.Checked = $true
    $pnlStash.Controls.Add($chkODDetect)

    $txtODPattern = New-Object System.Windows.Forms.TextBox; $txtODPattern.Font = $FontNormal
    $txtODPattern.Size = New-Object System.Drawing.Size(180, 24)
    $txtODPattern.BackColor = $t.MedBg; $txtODPattern.ForeColor = $t.Text; $txtODPattern.BorderStyle = "FixedSingle"
    $txtODPattern.Text = $Script:OneDriveFolderPattern
    $pnlStash.Controls.Add($txtODPattern)

    $txtODMin = New-Object System.Windows.Forms.TextBox; $txtODMin.Font = $FontNormal
    $txtODMin.Size = New-Object System.Drawing.Size(60, 24)
    $txtODMin.BackColor = $t.MedBg; $txtODMin.ForeColor = $t.Text; $txtODMin.BorderStyle = "FixedSingle"
    $txtODMin.Text = [string][int]($Script:OneDriveMinLocalBytes / 1MB)
    $pnlStash.Controls.Add($txtODMin)

    # $yPos is deliberately NOT advanced. The panel is laid out on top of where
    # the Actions group starts, so Simple mode costs no height at all; showing
    # it pushes everything below down by exactly its height. Reserving the space
    # up front would leave a 200px hole in the window for every operator who
    # never turns Expert mode on.

    # ---- Action Buttons ----
    $grpActions = New-Object System.Windows.Forms.GroupBox; $grpActions.Text = "  Actions  "; $grpActions.Font = $FontSection; $grpActions.ForeColor = $t.Primary
    $grpActions.Location = New-Object System.Drawing.Point(20, $yPos); $grpActions.Size = New-Object System.Drawing.Size(625, 68); $grpActions.BackColor = $t.GroupBg
    # No Left+Right anchor: this group lives in the fixed-width setup column,
    # and an anchor captured before that column has a real size stretches it.
    $Form.Controls.Add($grpActions)
    # THREE buttons, not five. This box is called Actions, and "clear the log"
    # and "open another window" are not actions on a migration - they were
    # sitting beside Run at the same weight, which is exactly the redundancy
    # that made the row hard to read. Both moved to the menus, where the rest of
    # the window-level commands already are (File > New window, Ctrl+N; and the
    # output pane's own right-click menu clears it, with a confirmation).
    #
    # What is left is the decision: run it, stop it, or go and read the logs.
    # Run gets the widest slot by a distance because it is the one being aimed
    # at, and a big obvious primary button is what an entry-level technician
    # needs to find without reading the whole panel first.
    $btnRun = New-Object System.Windows.Forms.Button; $btnRun.Text = "$($Script:ArrowRight) Run Migration"; $btnRun.Font = New-UTWFont "Heading" ([System.Drawing.FontStyle]::Bold)
    $btnRun.Location = New-Object System.Drawing.Point(15, 22); $btnRun.Size = New-Object System.Drawing.Size(315, 36)
    $btnRun.BackColor = $t.Primary; $btnRun.ForeColor = (Get-ContrastingText $t.Primary); $btnRun.FlatStyle = "Flat"
    $btnRun.FlatAppearance.BorderSize = 0; $btnRun.Tag = "run-btn"; $grpActions.Controls.Add($btnRun)
    $btnStop = New-Object System.Windows.Forms.Button; $btnStop.Text = "Stop"; $btnStop.Font = $FontNormal
    $btnStop.Location = New-Object System.Drawing.Point(338, 22); $btnStop.Size = New-Object System.Drawing.Size(126, 36)
    $btnStop.BackColor = $t.Error; $btnStop.ForeColor = (Get-ContrastingText $t.Error); $btnStop.FlatStyle = "Flat"
    $btnStop.FlatAppearance.BorderSize = 0; $btnStop.Enabled = $false; $btnStop.Tag = "stop-btn"; $grpActions.Controls.Add($btnStop)
    $btnOpenLogs = New-Object System.Windows.Forms.Button; $btnOpenLogs.Text = "Open logs"; $btnOpenLogs.Font = $FontNormal
    $btnOpenLogs.Location = New-Object System.Drawing.Point(472, 22); $btnOpenLogs.Size = New-Object System.Drawing.Size(138, 36)
    $btnOpenLogs.BackColor = $Script:AccentTeal; $btnOpenLogs.ForeColor = (Get-ContrastingText $Script:AccentTeal); $btnOpenLogs.FlatStyle = "Flat"; $btnOpenLogs.Tag = "btn-logs"
    $btnOpenLogs.FlatAppearance.BorderSize = 0; $grpActions.Controls.Add($btnOpenLogs)

    $btnOpenLogs.Add_Click({ if ($Script:AppConfig.LogFolder -and (Test-Path $Script:AppConfig.LogFolder)) { Start-Process explorer.exe $Script:AppConfig.LogFolder } })

    # ---- Commands that no longer have a button ----
    # These are FUNCTIONS, not hidden buttons driven by PerformClick().
    #
    # Button.PerformClick() checks CanSelect first, and CanSelect is false for
    # any control that is not visible - so firing a hidden button from a menu
    # item does exactly nothing, silently. That is why "Clear the output log"
    # appeared to do nothing at all. A function has no such trap and every
    # caller reaches the same code.
    function Clear-OutputLog {
        <#
            Empties the output pane. Not undoable, and until it has been saved
            the pane is the only record of what this window has done - so it
            asks, once, and offers to save first.
        #>
        if ($txtOutput.TextLength -eq 0) {
            $lblStatus.Text = "The output log is already empty."
            $lblStatus.ForeColor = $Script:T.TextDim
            return
        }
        $pick = Show-ChoiceDialog -Title "Clear the output log" -Glyph $Script:WarningSign `
            -Heading "Clear everything in the output pane?" `
            -Message ("This wipes the whole pane - every line, back to when this window opened, not just the last run.`n`n" +
                      "It is not the USMT log and not the UTW crash log; clearing it does not touch either of those. It cannot be undone.") `
            -Choices @(
                @{ Key = "Save"; Text = "Save it to a file first, then clear"; Accent = $Script:T.Primary
                   Hint = "Writes the whole pane to a .log file, then empties it." }
                @{ Key = "Clear"; Text = "Clear it without saving"; Accent = $Script:AccentStone }
                @{ Key = "No"; Text = "Keep it"; IsCancel = $true }
            )
        if ($pick -eq "Save") { if (-not (Save-OutputLog)) { return } }
        elseif ($pick -ne "Clear") { return }
        # Clear() rather than Text="" - on a RichTextBox the latter leaves the
        # selection formatting behind, so the next line written can inherit the
        # colour of whatever used to be at that position.
        $txtOutput.Clear()
        $txtOutput.SelectionColor = $Script:T.OutputFg
        # "Everything" means the run's leftovers too, not just the text.
        $progressBar.Value = 0; $progressBar.Style = "Continuous"
        $lblProgress.Text = ""
        if (-not $Script:OperationRunning) {
            $lblStatus.Text = "Ready"; $lblStatus.ForeColor = $Script:T.TextDim
        }
    }

    # A second migration runs in a second PROCESS, not a second tab. One window
    # is one operation: a tab would share this window's single UI thread, so a
    # capture in one tab would freeze the other, and one unhandled error would
    # take both migrations down. Separate processes share nothing but the
    # settings file, and a crash in one cannot reach the other.
    function Invoke-NewWindow { & $Script:NewWindowAction }

    $yPos += 76

    # ---- Summary ----
    # This panel exists to fill the space under Actions in Simple mode, and it
    # earns the space rather than just occupying it: it says, in plain English,
    # what pressing Run is about to do. An entry-level technician gets a
    # sentence they can check against the ticket before committing; a senior one
    # gets the resolved store path without opening Expert mode.
    #
    # It is the only FILL panel in the left column, so it absorbs whatever
    # height is left over - which is exactly the gap that was empty before.
    $grpPlan = New-Object System.Windows.Forms.GroupBox
    $grpPlan.Text = "  Summary  "; $grpPlan.Font = $FontSection; $grpPlan.ForeColor = $t.Primary
    $grpPlan.Location = New-Object System.Drawing.Point(20, $yPos)
    $grpPlan.Size = New-Object System.Drawing.Size(625, 150); $grpPlan.BackColor = $t.GroupBg
    $Form.Controls.Add($grpPlan)
    $txtPlan = New-Object System.Windows.Forms.RichTextBox
    $txtPlan.Dock = "Fill"
    $txtPlan.Font = $FontNormal
    $txtPlan.BackColor = $t.GroupBg; $txtPlan.ForeColor = $t.Text
    $txtPlan.ReadOnly = $true; $txtPlan.BorderStyle = "None"
    $txtPlan.ScrollBars = "Vertical"; $txtPlan.WordWrap = $true
    $txtPlan.TabStop = $false
    $txtPlan.Tag = "plan"
    $grpPlan.Controls.Add($txtPlan)
    $grpPlan.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 10)

    function Update-Plan {
        <#
            Rewrites the summary from the fields as they stand. Called at the end
            of Update-Fields, so it can never disagree with the form.

            Everything here is READ from the same getters the run itself uses -
            Get-OperationText, Get-ActiveText, Get-UsernameList - rather than
            re-derived, so a summary that says "capture from PC-TEST01" is the
            machine the command will actually name.
        #>
        if (-not $Script:PlanReady) { return }
        # A coalesced repaint can land after the window has gone - closing during
        # a resize is enough to do it - and writing to a disposed RichTextBox
        # throws where there is nothing left to show. Nothing to draw, so stop.
        if ($txtPlan.IsDisposed -or $txtPlan.Disposing) { return }
        $t2 = $Script:T
        $txtPlan.SuspendLayout()
        try {
            $txtPlan.Clear()
            $add = {
                param([string]$Label, [string]$Value, $Colour = $null)
                $txtPlan.SelectionColor = $t2.TextDim
                $txtPlan.AppendText(("{0,-12}" -f $Label))
                $txtPlan.SelectionColor = $(if ($Colour) { $Colour } else { $t2.Text })
                $txtPlan.AppendText("$Value`n")
            }
            $op = Get-OperationText
            $txtPlan.SelectionColor = $Script:T.Primary
            $txtPlan.AppendText("$op`n`n")

            if ($op -match "Clean Up") {
                $pcs = Get-ActiveText "SourcePC" $txtSourcePC
                & $add "On" $(if ($pcs) { $pcs } else { "this PC ($env:COMPUTERNAME)" })
                $bits = @("staged USMT files")
                if ($chkCleanStores.Checked)   { $bits += "old migration stores" }
                if ($chkCleanProfiles.Checked) { $bits += "stale user profiles" }
                & $add "Removes" ($bits -join ", ") $(if ($bits.Count -gt 1) { $t2.Warning } else { $t2.Text })
                & $add "" "You are asked before anything is deleted." $t2.TextDim
                return
            }
            if ($op -match "Compare") {
                $cs = Get-ActiveText "SourcePC" $txtSourcePC
                $cd = Get-ActiveText "NewPC"    $txtNewPC
                & $add "Old PC" $(if ($cs) { $cs } else { "(the machine they kept using)" })
                & $add "New PC" $(if ($cd) { $cd } else { "(the machine they moved to)" })
                & $add "Profile" $(if ($txtUsername.Text.Trim()) { $txtUsername.Text.Trim() } else { "(name it, or use Lookup)" })
                & $add "" "Nothing is written until you pick what to copy." $t2.TextDim
                return
            }
            if ($op -match "Extract") {
                & $add "From" $(if ($txtMigrationFile.Text) { $txtMigrationFile.Text } else { "(pick a .MIG file)" })
                & $add "Into" $(if ($txtExtractPath.Text) { $txtExtractPath.Text } else { "(pick a folder)" })
                return
            }

            $src = Get-ActiveText "SourcePC" $txtSourcePC
            $dst = Get-ActiveText "NewPC"    $txtNewPC
            if ($Script:FieldApplies -and $Script:FieldApplies.SourcePC) {
                & $add "From" $(if ($src) { $src } else { "this PC ($env:COMPUTERNAME)" })
            }
            if ($Script:FieldApplies -and $Script:FieldApplies.NewPC) {
                & $add "To" $(if ($dst) { $dst } else { "this PC ($env:COMPUTERNAME)" })
            }
            if ($Script:FieldApplies -and $Script:FieldApplies.Username) {
                $users = @(Get-UsernameList)
                & $add "User" $(
                    if ($users.Count -eq 0) { "(none chosen yet)" }
                    elseif ($users.Count -eq 1) { "$($txtDomain.Text.Trim())\$($users[0])" }
                    else { "$($users.Count) profiles: $($users -join ', ')" }
                ) $(if ($users.Count -eq 0) { $t2.Warning } else { $t2.Text })
            } elseif ($op -match "All Profiles") {
                & $add "User" "every migratable profile on the machine"
            } elseif ($op -match "Computer Settings") {
                & $add "User" "none - system settings only"
            }
            if ($Script:FieldApplies -and $Script:FieldApplies.ImportStore) {
                & $add "Store" $(if ($txtImportStore.Text) { $txtImportStore.Text } else { "(pick a store)" })
            } else {
                & $add "Store" (Get-PlanStorePath)
            }
            $opts = @()
            if ($chkExcludeOneDrive.Checked -and $chkExcludeOneDrive.Enabled) { $opts += "exclude OneDrive" }
            if ($chkOverwrite.Checked -and $chkOverwrite.Enabled)             { $opts += "overwrite the store" }
            if ($chkCleanup.Checked -and $chkCleanup.Enabled)                 { $opts += "delete the store afterwards" }
            if ($chkCleanProfiles.Checked -and $chkCleanProfiles.Enabled)     { $opts += "offer to remove stale profiles" }
            if ($opts.Count) { & $add "Options" ($opts -join ", ") }
            # The two that destroy data are called out on their own line, in the
            # error colour, however they were set.
            $danger = @()
            if ($chkRenameOnRestore.Checked) { $danger += "restore onto a different account" }
            if ($chkDeleteSource.Checked)    { $danger += "delete the source profile after capture" }
            if ($danger.Count) { & $add "Warning" (($danger -join "; ")) $t2.Error }
            if ($Script:CmdEdited) { & $add "Command" "edited by hand - the Expert panel is what runs" $t2.Warning }
        } catch {
            Write-CrashLog "Plan summary failed: $($_.Exception.Message)"
        } finally { $txtPlan.ResumeLayout() }
    }

    function Get-PlanStorePath {
        # Where the store WILL land, resolved the same way the run resolves it.
        try {
            switch (Get-StoreMode) {
                "Central" { if ($txtCentralPath.Text.Trim()) { return $txtCentralPath.Text.Trim() } else { return "(set the server share)" } }
                "USB"     { if ($txtUSBPath.Text.Trim())     { return $txtUSBPath.Text.Trim() }     else { return "(set the drive path)" } }
                default   {
                    $pc = Get-ActiveText "NewPC" $txtNewPC
                    if (-not $pc) { return "(name the new PC)" }
                    return "\\$pc\C`$\$($Script:AppConfig.DefaultStorePath)"
                }
            }
        } catch { return "" }
    }

    $yPos += 158

    # The two collapse buttons that used to live here are gone. The splitter
    # between the setup column and the log does the same job continuously, and
    # having three different ways to resize the same two areas was exactly the
    # kind of redundancy that made the window hard to read.

    # "Output log", not "Log". There are three logs in play - USMT's own
    # scanstate/loadstate logs, UTW's crash log, and this running commentary -
    # and calling this one just "Log" was the reason people went looking for
    # USMT errors in the wrong place. The Status bar names the other two.
    $grpOutput = New-Object System.Windows.Forms.GroupBox; $grpOutput.Text = "  Output log  "; $grpOutput.Font = $FontSection; $grpOutput.ForeColor = $t.Primary
    $grpOutput.Location = New-Object System.Drawing.Point(20, $yPos); $grpOutput.Size = New-Object System.Drawing.Size(625, 200); $grpOutput.BackColor = $t.GroupBg
    # NOTE: anchor set AFTER Form.Height is finalised (avoids negative-margin bugs)
    $Form.Controls.Add($grpOutput)
    $txtOutput = New-Object System.Windows.Forms.RichTextBox; $txtOutput.Font = $FontMono; $txtOutput.Location = New-Object System.Drawing.Point(10, 14)
    $txtOutput.Size = New-Object System.Drawing.Size(602, 175); $txtOutput.BackColor = $t.DarkBg; $txtOutput.ForeColor = $t.Text; $txtOutput.ReadOnly = $true; $txtOutput.ScrollBars = "Vertical"
    # WRAPPED. A narrow log used to crop each line at the right edge and make
    # you scroll sideways to read the end of it - and the ends are where the
    # paths and the error text are. These are sentences, not command lines, so
    # they wrap like sentences. (The Expert command box is the opposite case and
    # deliberately does not wrap; see the note there.)
    $txtOutput.BorderStyle = "None"; $txtOutput.WordWrap = $true; $txtOutput.DetectUrls = $false
    # Any URL the tool prints - currently Microsoft's USMT return-code page,
    # printed beside a failing exit code - becomes clickable. The alternative
    # was a "look this up" button that is dead weight on every other run.
    $txtOutput.DetectUrls = $true
    $txtOutput.Add_LinkClicked({
        param($eventSender, $e)
        try { Start-Process $e.LinkText }
        catch { Write-CrashLog "Could not open $($e.LinkText): $($_.Exception.Message)" }
    })
    $grpOutput.Controls.Add($txtOutput)

    # Right-click menu on the pane itself. Copying a couple of lines to paste
    # into a ticket is the single most common thing anyone does with this box,
    # and there was no way to do it except select-and-Ctrl+C with no menu to
    # tell you that worked. Clear lives here too, beside the Save that makes
    # clearing safe, rather than as a button next to Run.
    $ctxOutput = New-Object System.Windows.Forms.ContextMenuStrip
    $ctxOutput.BackColor = $t.GroupBg; $ctxOutput.ForeColor = $t.Text
    if ($Script:MenuRendererAvailable) {
        $ctxOutput.RenderMode = "Professional"
        $ctxOutput.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer (New-Object UTWMenuColors)
    }
    $miOutCopy = New-Object System.Windows.Forms.ToolStripMenuItem("&Copy")
    $miOutCopy.Add_Click({ if ($txtOutput.SelectionLength -gt 0) { $txtOutput.Copy() } })
    $miOutAll  = New-Object System.Windows.Forms.ToolStripMenuItem("Select &all")
    $miOutAll.Add_Click({ $txtOutput.SelectAll(); $txtOutput.Focus() })
    $miOutSave = New-Object System.Windows.Forms.ToolStripMenuItem("&Save output log...")
    $miOutSave.Add_Click({ [void](Save-OutputLog) })
    $miOutClear = New-Object System.Windows.Forms.ToolStripMenuItem("Cl&ear output log...")
    $miOutClear.Add_Click({ Clear-OutputLog })
    foreach ($mi in @($miOutCopy, $miOutAll)) { $mi.BackColor = $t.GroupBg; $mi.ForeColor = $t.Text; [void]$ctxOutput.Items.Add($mi) }
    [void]$ctxOutput.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($mi in @($miOutSave, $miOutClear)) { $mi.BackColor = $t.GroupBg; $mi.ForeColor = $t.Text; [void]$ctxOutput.Items.Add($mi) }
    # Copy only offers itself when there is a selection to copy.
    $ctxOutput.Add_Opening({ $miOutCopy.Enabled = ($txtOutput.SelectionLength -gt 0) })
    $txtOutput.ContextMenuStrip = $ctxOutput
    $Script:ThemedStrips = @($ctxOutput)

    $yPos += 208

    # grpOutput height + gap at 1.0 scale. Re-derived from the real control
    # height in LAYOUT FINALISATION once scaling has been applied.


    # ---- Expert panel show / hide ----
    # Same technique as the Setup collapse below: read the LIVE (already scaled)
    # geometry and shift the controls beneath, so it behaves identically at 1.0
    # and at 1.75. The window grows to make room where the screen allows, and
    # what the screen will not give is taken from the output box instead - which
    # is the elastic element in this layout and the only one that can spare it.
    function Show-BrowseUsers {
        <#
            Fills the right-hand list with the profiles on the machine being
            captured. The same data the picker dialog uses, kept on screen
            instead of behind a button - which is the point of having the space.
        #>
        $pc = Get-ActiveText "SourcePC" $txtSourcePC
        if (-not $pc) { $pc = $env:COMPUTERNAME }
        if (-not (Test-ValidComputerName $pc)) { $lblBrowseHint.Text = "'$pc' is not a valid computer name."; return }
        $lblBrowseHint.Text = "Listing profiles on $pc..."
        [System.Windows.Forms.Application]::DoEvents()
        # THE SAME THRESHOLD THE CLEAN UP USES.
        #
        # This list used to ask without one, so Stale came back false for
        # everything and the panel could only ever flag orphans - the idle-days
        # setting had no effect on the one screen where somebody browses a
        # machine looking for exactly that.
        $r = Get-RemoteUserProfiles -ComputerName $pc -InactiveDays $Script:PreflightInactiveDays
        $lvBrowse.BeginUpdate()
        try {
            $lvBrowse.Items.Clear(); $lvBrowse.Columns.Clear()
            # NOT "Last used". These are the two things the tool can prove: when
            # the profile folder appeared, and when the user's registry hive was
            # last written. Neither is a logon record, and the column that used
            # to claim one was wrong on every machine it mattered on.
            # BUILT FROM THE DEFINITIONS, so a column can be turned off without
            # anything else in this function knowing. Each definition carries its
            # own value function, which is what makes that safe: the old code
            # added five headers and then five subitems in the same order by
            # hand, and hiding one meant renumbering every SubItems.Add below it.
            # That is exactly how the Clean Up dialog's blocked rows ended up one
            # column out when "First created" was added.
            $cols = @(Get-BrowseColumns)
            foreach ($c in $cols) { [void]$lvBrowse.Columns.Add($c.Text, $c.Width) }
            if (-not $r.Ok) {
                # Not $h - that name already means the hand-off payload a few
                # hundred lines away, and one letter with two meanings confuses
                # both the reader and the key-coverage check.
                $why = Get-RemoteErrorHelp $r.Error
                $lblBrowseHint.Text = "$pc - $($why.What)"
                if ($why.Try) { Append-Output "$pc - $($why.What). $($why.Try)" $Script:T.Warning }
                return
            }
            $Script:BrowseMode = "Users"
            $orphans = 0; $stales = 0
            foreach ($p in @($r.Profiles | Where-Object { $_.Migratable })) {
                # Cells in the order the columns were built, from the same list.
                $cells = @()
                foreach ($c in $cols) { $cells += "$(& $c.Value $p)" }
                $it = New-Object System.Windows.Forms.ListViewItem($cells[0])
                for ($ci = 1; $ci -lt $cells.Count; $ci++) { [void]$it.SubItems.Add($cells[$ci]) }
                # The elapsed time is on the hover, not in the column. A row
                # tooltip rather than a per-cell one because that is all a
                # ListView offers in Details view - so it carries both dates.
                $tip = "Last modified: $(Format-ProfileAge $p.AgeDays)  (registry hive, not a sign-in record)" +
                       "`r`nFirst created: $(Format-ProfileAge $p.CreatedDays)"
                # THE ORPHAN FLAG EARNS THE "Signed in" COLUMN.
                #
                # A profile whose SID no longer resolves is what sysdm.cpl calls
                # "Account Unknown" - the person left and the account is gone,
                # leaving the folder behind. That is worth more than any date
                # here: it does not depend on a timestamp anything can move, and
                # it is the surest sign a profile is safe to stop carrying
                # forward. It goes in this column because "signed in" is empty
                # for exactly the profiles this applies to.
                # Colour and tooltip only - the cells themselves came from the
                # definitions above, including the "no account" text.
                if ($p.Orphan) {
                    $orphans++
                    $it.ForeColor = $t.Warning
                    $tip += "`r`n`r`nThe account for this profile could not be found - it looks deleted. Windows shows it as 'Account Unknown'."
                } elseif ($p.Stale) {
                    # Idle for longer than the setting. Marked, but not in the
                    # same colour as an orphan - one is a missing account and
                    # the other is a date, and they are not equally certain.
                    $stales++
                    $it.ForeColor = $t.TextDim
                    $tip += "`r`n`r`nIdle longer than the $($Script:PreflightInactiveDays)-day setting. That is a hive write time, not a sign-in record, so treat it as a hint rather than proof."
                }
                $it.ToolTipText = $tip
                $it.Tag = $p
                [void]$lvBrowse.Items.Add($it)
            }
            $lvBrowse.ShowItemToolTips = $true
            # Which columns are the date ones is now a lookup, not a constant -
            # @(1,2) was only correct while every column was always shown.
            $dateIdx = @(); $folderIdx = -1
            for ($ci = 0; $ci -lt $cols.Count; $ci++) {
                if ($cols[$ci].Key -in @("modified","created")) { $dateIdx += $ci }
                if ($cols[$ci].Key -eq "folder") { $folderIdx = $ci }
            }
            if ($dateIdx.Count) { Set-ProfileDateColumns -List $lvBrowse -Columns $dateIdx -Absorb $folderIdx }
            $note = ""
            if ($orphans -gt 0) { $note += " $orphans with no account left." }
            if ($stales -gt 0)  { $note += " $stales idle over $($Script:PreflightInactiveDays) days." }
            $lblBrowseHint.Text = "$($lvBrowse.Items.Count) profile(s) on $pc.$note Pick one, then use the buttons below."
        } finally { $lvBrowse.EndUpdate(); Update-BrowseActions }
    }

    function Show-BrowseStores {
        <#
            The same list, showing stores instead. Looks where the current
            operation would look, so it needs no folder picker for the ordinary
            case: the network share if one is set, otherwise this PC's own
            store folder.
        #>
        $root = if ($txtImportStore.Text.Trim() -and (Test-Path $txtImportStore.Text.Trim() -ErrorAction SilentlyContinue)) {
                    Split-Path $txtImportStore.Text.Trim() -Parent
                } elseif ($txtCentralPath.Text.Trim()) { $txtCentralPath.Text.Trim() }
                elseif ($txtNewPC.Text.Trim())         { "\\$($txtNewPC.Text.Trim())\C`$\$($Script:AppConfig.DefaultStorePath)" }
                else { "C:\$($Script:AppConfig.DefaultStorePath)" }
        $lblBrowseHint.Text = "Reading $root..."
        [System.Windows.Forms.Application]::DoEvents()
        $r = Get-StoreContents -Root $root -Recurse
        $lvBrowse.BeginUpdate()
        try {
            $lvBrowse.Items.Clear(); $lvBrowse.Columns.Clear()
            [void]$lvBrowse.Columns.Add("User", 130)
            [void]$lvBrowse.Columns.Add("From", 110)
            [void]$lvBrowse.Columns.Add("Size", 80)
            [void]$lvBrowse.Columns.Add("Captured", 140)
            [void]$lvBrowse.Columns.Add("Restored", 140)
            if (-not $r.Ok) { $lblBrowseHint.Text = "$root - $($r.Error)"; return }
            $Script:BrowseMode = "Stores"
            foreach ($s in $r.Stores) {
                $it = New-Object System.Windows.Forms.ListViewItem($s.Username)
                [void]$it.SubItems.Add($s.SourceComputer)
                [void]$it.SubItems.Add($s.Text)
                [void]$it.SubItems.Add($s.ExportedOn)
                [void]$it.SubItems.Add($s.ImportedOn)
                if ($s.ImportedOn) { $it.ForeColor = $Script:T.TextDim }
                $it.Tag = $s
                [void]$lvBrowse.Items.Add($it)
            }
            $lblBrowseHint.Text = "$($lvBrowse.Items.Count) store(s) in $root."
        } finally { $lvBrowse.EndUpdate(); Update-BrowseActions }
    }

    function Set-SplitterLayout {
        <#
            Applies the divider position and the two panel minimums, in the only
            order SplitContainer accepts.

            Every one of these three properties is validated against the others
            AND against the control's current width, and the exception is fatal
            if it escapes. So: minimums are dropped to zero first, the distance
            is set to something that provably fits, and only then are the
            minimums restored - each step guarded, because a splitter that ends
            up in an odd position is a cosmetic problem and an unhandled
            exception here is not.
        #>
        <#
            STACKED MODE: the same two zones, one above the other.

            A SplitContainer turned Horizontal puts Panel1 on top of Panel2
            instead of beside it, and both zones are already single-column
            tables that fill whatever they are given - so the whole "narrow
            screen" layout is this property plus a sensible divider. Nothing is
            re-authored and there is no second layout to keep in step.

            It exists for the phone. The window is about 1180px wide by design
            and a phone in portrait is not, so side by side means panning
            sideways to reach half the tool. Stacked, it scrolls the way every
            other thing on a phone scrolls.

            The width minimums do not apply here - both zones now have the whole
            width - and a HEIGHT floor takes their place, small enough that
            either half can be collapsed to a header and its own scroll bar.
        #>
        if ($split.Orientation -eq [System.Windows.Forms.Orientation]::Horizontal) {
            $h = $split.Height
            if ($h -le 0) { return }
            $minS = [int](120 * $Script:UIScale)
            if ($h -lt (($minS * 2) + $split.SplitterWidth + 8)) { $minS = 0 }
            try { $split.Panel1MinSize = 0; $split.Panel2MinSize = 0 } catch { }
            try {
                # Slightly more than half to the setup half: it is the one with
                # the fields somebody is filling in, and the log below it is
                # useful at any height.
                $wantH = [int]($h * 0.55)
                $wantH = [Math]::Max($minS, [Math]::Min($wantH, ($h - $split.SplitterWidth - 1)))
                $split.SplitterDistance = [Math]::Max(1, $wantH)
            } catch { Write-CrashLog "Stacked splitter distance: $($_.Exception.Message)" }
            try { $split.Panel1MinSize = $minS; $split.Panel2MinSize = $minS } catch { }
            Set-RightSplitter -Reset
            return
        }

        $w = $split.Width
        if ($w -le 0) { return }
        # The setup column cannot be dragged narrower than its own contents.
        # The panels stretch upwards from their design width but nothing can
        # make a labelled row narrower than the label plus the box - so below
        # this the only outcomes are a horizontal scroll bar or controls
        # overhanging the edge, and neither is worth offering. 625 design px of
        # content plus room for the vertical scroll bar.
        $min1 = [int](($Script:PanelDesignWidth + 17) * $Script:UIScale)
        # The right column has a floor of its own for the same reason the left
        # does. At 220 it could be dragged far narrower than the panels standing
        # in it - they carry a minimum width, so they simply overhung the zone
        # and their right-hand border was cut off. This is the width at which the
        # log and the lookup list still show a whole panel.
        $min2 = [int]($Script:RightZoneMinWidth * $Script:UIScale)
        # Nothing can be honoured on a window too narrow for both minimums.
        if ($w -lt ($min1 + $min2 + $split.SplitterWidth + 8)) { $min1 = 0; $min2 = 0 }

        try { $split.Panel1MinSize = 0; $split.Panel2MinSize = 0 } catch { }
        try {
            $want = [Math]::Min($Script:SetupColumnWidth, ($w - $min2 - $split.SplitterWidth - 4))
            $want = [Math]::Max($want, $min1)
            $want = [Math]::Max(1, [Math]::Min($want, ($w - $split.SplitterWidth - 1)))
            $split.SplitterDistance = $want
        } catch { Write-CrashLog "Splitter distance: $($_.Exception.Message)" }
        try { $split.Panel1MinSize = $min1; $split.Panel2MinSize = $min2 } catch { }
        Set-RightSplitter -Reset
    }

    function Set-RightSplitter {
        <#
            The right column's own divider: list on top, log below.

            -Reset puts it back to a third/two-thirds. Without it the position
            is only CLAMPED to still fit - because this runs on every resize,
            and resetting there would drag the divider back every time the
            window was touched, undoing wherever the operator had put it.
        #>
        param([switch]$Reset)
        try {
            $h = $splitRight.Height
            if ($h -le 0) { return }
            $rmin = [int](90 * $Script:UIScale)
            $roomy = $h -gt (($rmin * 2) + $splitRight.SplitterWidth + 8)
            $splitRight.Panel1MinSize = 0; $splitRight.Panel2MinSize = 0
            # A third to the list, two thirds to the log: the log is what gets
            # read during a run, the list is what gets read before one.
            $want = if ($Reset) { [int]($h / 3) } else { $splitRight.SplitterDistance }
            $lo = if ($roomy) { $rmin } else { 1 }
            $hi = $h - $splitRight.SplitterWidth - $lo
            if ($hi -gt $lo) {
                $want = [Math]::Max($lo, [Math]::Min($want, $hi))
                $splitRight.SplitterDistance = $want
            }
            if ($roomy) { $splitRight.Panel1MinSize = $rmin; $splitRight.Panel2MinSize = $rmin }
        } catch { Write-CrashLog "Right splitter: $($_.Exception.Message)" }
    }

    function Update-SplitterFit {
        # Called on every resize. Clamps both dividers so they stay legal at the
        # new size, but moves neither on purpose - a resize must not undo a drag.
        try {
            $w = $split.Width
            if ($w -gt 0) {
                $lo = $split.Panel1MinSize
                $hi = $w - $split.Panel2MinSize - $split.SplitterWidth
                if ($hi -gt $lo -and $split.SplitterDistance -gt $hi) { $split.SplitterDistance = $hi }
            }
        } catch { }
        Set-RightSplitter
    }

    $Script:ExpertVisible = $false
    function Set-ExpertPanel {
        <#
            Show or hide the Expert panel.

            Nothing else has to move. The Expert box is a registered panel like
            any other, so this sets one flag and rebuilds its zone - whatever
            follows it slides up or down on its own. The old version had to
            measure the panel and shift the Actions group by exactly that many
            pixels, which was one arithmetic slip away from a gap or an overlap
            every time the panel's height changed.
        #>
        param([bool]$Show)
        if ($Script:ExpertVisible -eq $Show) { return }
        $Script:ExpertVisible = $Show
        try {
            $p = $Script:Panels | Where-Object { $_.Key -eq "Expert" } | Select-Object -First 1
            if ($p) { $p.Shown = $Show; Update-Layout }
        } catch {
            Write-CrashLog "Expert panel toggle failed: $($_.Exception.Message)"
        }
    }


    # ---- Status ----
    # Back at the foot of the window in its own bordered group, with the progress
    # bar folded in beside it rather than floating loose above. Every label here
    # is a fixed width with AutoEllipsis instead of AutoSize: the original bug
    # was an AutoSize label that simply grew past the edge of the group box and
    # got clipped mid-path with no way to read the rest. Now it truncates
    # cleanly and the untruncated value is one hover away.
    $grpStatus = New-Object System.Windows.Forms.GroupBox
    $grpStatus.Text = "  Status  "; $grpStatus.Font = $FontSection; $grpStatus.ForeColor = $t.Primary
    $grpStatus.Location = New-Object System.Drawing.Point(20, $yPos)
    $grpStatus.Size = New-Object System.Drawing.Size(625, 86); $grpStatus.BackColor = $t.GroupBg
    $Form.Controls.Add($grpStatus)

    # Indicator light. It mirrors whatever colour the status text is given, via
    # ForeColorChanged - so the ~20 places that set $lblStatus.ForeColor drive it
    # for free and none of them had to change.
    $lblStatusDot = New-Object System.Windows.Forms.Label
    $lblStatusDot.Text = [string][char]0x25CF   # filled circle
    $lblStatusDot.Font = New-UTWFont "Heading"
    $lblStatusDot.ForeColor = $t.TextDim
    $lblStatusDot.Location = New-Object System.Drawing.Point(15, 18)
    $lblStatusDot.AutoSize = $false; $lblStatusDot.Size = New-Object System.Drawing.Size(16, 22)
    $lblStatusDot.TextAlign = "MiddleLeft"; $lblStatusDot.Tag = "accent-cyan"  # never recoloured by the theme
    $grpStatus.Controls.Add($lblStatusDot)

    $lblStatus = New-Object System.Windows.Forms.Label; $lblStatus.Text = "Ready"
    $lblStatus.Font = $FontNormal; $lblStatus.ForeColor = $t.TextDim
    $lblStatus.Location = New-Object System.Drawing.Point(34, 18)
    $lblStatus.Size = New-Object System.Drawing.Size(411, 22)
    $lblStatus.AutoSize = $false; $lblStatus.TextAlign = "MiddleLeft"; $lblStatus.AutoEllipsis = $true
    $lblStatus.Anchor = $anchLR; $lblStatus.Tag = "dim"
    $grpStatus.Controls.Add($lblStatus)
    $lblStatus.Add_ForeColorChanged({ $lblStatusDot.ForeColor = $lblStatus.ForeColor })

    $lblProgress = New-Object System.Windows.Forms.Label
    $lblProgress.Text = ""; $lblProgress.Font = New-UTWFont 9 ([System.Drawing.FontStyle]::Bold)
    $lblProgress.ForeColor = $t.Primary
    $lblProgress.Location = New-Object System.Drawing.Point(450, 18)
    $lblProgress.Size = New-Object System.Drawing.Size(160, 22)
    $lblProgress.TextAlign = "MiddleRight"; $lblProgress.Tag = "title"; $lblProgress.Anchor = $anchTR
    $grpStatus.Controls.Add($lblProgress)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15, 44)
    $progressBar.Size     = New-Object System.Drawing.Size(595, 14)
    $progressBar.Minimum  = 0; $progressBar.Maximum = 100; $progressBar.Value = 0
    $progressBar.Style    = "Continuous"; $progressBar.Anchor = $anchLR
    $grpStatus.Controls.Add($progressBar)

    $lblLogPath = New-Object System.Windows.Forms.Label; $lblLogPath.Text = "Logs: (select USMT folder first)"
    $lblLogPath.Font = $FontSmall; $lblLogPath.ForeColor = $t.TextDim
    $lblLogPath.Location = New-Object System.Drawing.Point(15, 62)
    $lblLogPath.Size = New-Object System.Drawing.Size(595, 18)
    $lblLogPath.AutoSize = $false; $lblLogPath.TextAlign = "MiddleLeft"; $lblLogPath.AutoEllipsis = $true
    $lblLogPath.Anchor = $anchLR; $lblLogPath.Tag = "dim"
    $lblLogPath.Cursor = [System.Windows.Forms.Cursors]::Hand
    $grpStatus.Controls.Add($lblLogPath)
    $lblLogPath.Add_Click({
        if ($Script:AppConfig.LogFolder -and (Test-Path $Script:AppConfig.LogFolder)) {
            Start-Process explorer.exe $Script:AppConfig.LogFolder
        }
    })
    $Script:LogPathLabel = $lblLogPath

    # Full path on the tooltip, because even a full-width label runs out of room
    # on a deep UNC share, and the truncated half is the half you already know.
    $Script:PathTip = New-Object System.Windows.Forms.ToolTip
    $Script:PathTip.InitialDelay = 300; $Script:PathTip.ReshowDelay = 100; $Script:PathTip.AutoPopDelay = 30000
    function Set-LogPathDisplay {
        param([string]$Path)
        if (-not $Script:LogPathLabel) { return }
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $Script:LogPathLabel.Text = "Logs: (select USMT folder first)"
            $Script:PathTip.SetToolTip($Script:LogPathLabel, "")
            return
        }
        $Script:LogPathLabel.Text      = "Logs: $Path"
        $Script:LogPathLabel.ForeColor = $Script:T.TextDim
        $Script:PathTip.SetToolTip($Script:LogPathLabel, "$Path`r`n`r`n(click to open in Explorer)")
    }
    $yPos += 96

    # ======================= LAYOUT FINALISATION =======================
    # Order matters here:
    #   1. natural CLIENT size from the layout pass
    #   2. anchors (must be after the client size so margins are positive)
    #   3. scaling, clamped to what the work area can actually show
    #   4. stored sizes + MinimumSize, derived from the SCALED form
    #   5. fit to the work area

    # =====================================================================
    #  TWO-COLUMN LAYOUT
    # =====================================================================
    # The setup panels are a fixed-width column of fixed-pixel controls. Left
    # as direct children of a resizable form they produced the obvious fault:
    # the GROUPS stretched with the window while everything inside them stayed
    # put, so maximising the tool opened up a wide empty band down the right of
    # every panel, with only the three right-anchored controls out there.
    #
    #   left  - setup, at its natural width, scrolls if the window is short
    #   right - the log, which is the thing that genuinely benefits from space
    #
    # A SplitContainer also replaces the two collapse buttons: dragging the
    # divider does what "Hide Setup" and "Hide Output" did between them, and
    # does it continuously rather than in one jump.
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Orientation = "Vertical"     # a vertical splitter = side-by-side panels
    $split.Dock = "Fill"
    $split.BackColor = (Get-DividerColor)
    $split.SplitterWidth = 6
    $split.Tag = "split"
    # Widening the window gives the extra width to the RIGHT half. The setup
    # column is a stack of labelled fields at a readable width - stretching it
    # only spreads the labels away from their boxes - whereas the list and the
    # log genuinely get better with room. The divider is still draggable if you
    # disagree, and where you leave it is remembered.
    $split.FixedPanel = "Panel1"
    # Panel1MinSize / Panel2MinSize / SplitterDistance are NOT set here. Each of
    # them validates against the control's CURRENT width, and a freshly created
    # SplitContainer is 150px wide - so asking for a 380px minimum throws
    # "SplitterDistance must be between Panel1MinSize and Width - Panel2MinSize"
    # and takes the whole window down before it is built. They are applied in
    # Set-SplitterLayout once the form has a real size.

    # =====================================================================
    #  ZONES AND MOVABLE PANELS
    # =====================================================================
    # Every group box in the window is a PANEL that can be sent to any of three
    # zones and ordered within it, and each zone stretches its panels to its own
    # width. Nothing is placed at an absolute position on the form any more.
    #
    #   Left        - $split.Panel1
    #   RightTop    - $splitRight.Panel1
    #   RightBottom - $splitRight.Panel2
    #
    # A zone is a single-column TableLayoutPanel, which is what makes this
    # tractable: rows are explicit, order is a row index, gaps come from Margin,
    # and the whole arrangement is rebuilt by refilling the table. The previous
    # design placed groups at fixed Y coordinates and shuffled them by hand,
    # which is why showing the Expert panel had to move the Actions box, and why
    # every panel was stuck at 625px whatever the window did.
    #
    # This is not foobar2000's free-form docking - you cannot drag a panel
    # anywhere and split arbitrarily. It is zone placement plus ordering plus
    # two draggable dividers, which covers "put the USMT box on the right" and
    # "give the log the whole window" without a docking framework.
    # --spacing-2 from the design system scale, rather than a number chosen by eye.
    $Script:LayoutGap = $Script:Tokens.Space["2"]
    $Script:Zones = @{}         # key -> the TableLayoutPanel that holds the panels
    $Script:ZoneHosts = @{}     # key -> the scrolling Panel the table sits in
    $Script:Panels = @()

    function New-Zone {
        <#
            A zone is ONE scrolling Panel. The panels in it are docked straight
            into it - there is no TableLayoutPanel any more.

            A TLP was the obvious choice (explicit rows, order as a row index)
            and it worked, but it is measurably the slower container: the same
            eight group boxes with thirty controls each, resized, cost 35.8 ms
            through a TableLayoutPanel against 23.9 ms docked into a plain Panel.
            A third of the layout cost of every divider drag was the container
            itself, and it was buying explicitness this code can express just as
            well with a height and a dock style.

            Docking order is the one subtlety: WinForms resolves docks from the
            HIGHEST z-order down, so the control added LAST ends up at the top.
            Update-Layout therefore adds the bottom-most panel first, and the
            Fill panel before any of them so it is left with the remainder.
        #>
        param([string]$Key, $Parent)
        # Composited, like the banner. WS_EX_COMPOSITED presents the panel and
        # its children in one buffered pass, which is what stops AutoScroll's
        # blit-and-patch showing while the bar is being dragged - the repaint on
        # Scroll below fixes it when the drag ENDS, this fixes it during.
        $hostPanel = if ($Script:NativeHelpers) {
            try { New-Object UTWCompositedPanel } catch { New-Object System.Windows.Forms.Panel }
        } else { New-Object System.Windows.Forms.Panel }
        $hostPanel.Dock = "Fill"
        $hostPanel.AutoScroll = $true
        $hostPanel.BackColor = $Script:T.DarkBg
        # SCROLLING HAS TO REPAINT, not blit.
        #
        # AutoScroll moves the pixels it already has and invalidates only the
        # strip newly exposed at the edge. That is right when a control's
        # background belongs to the control, and wrong here, because the backdrop
        # is anchored to the WINDOW: blitting drags it along with the content, so
        # the artwork smeared and piled up as the zone scrolled underneath the
        # panels. Repainting the zone on a scroll costs one frame and puts the
        # picture back where it belongs - behind everything, not moving with it.
        $hostPanel.Add_Scroll({
            param($ss, $se)
            if ($Script:OverlayEnabled) { try { $ss.Invalidate($true) } catch { } }
        })
        $Parent.Controls.Add($hostPanel)

        # ClientSizeChanged, NOT SizeChanged.
        #
        # A scroll bar appearing changes the CLIENT width without changing the
        # control's Size, so SizeChanged never fires - and the panels, which are
        # docked to the client area, silently became 17px narrower than the
        # width everything inside them had been fitted to. (The inner
        # TableLayoutPanel used to provide this signal for free by resizing
        # itself; taking it out took the signal with it.)
        # Three of these, one per zone; there are deliberately none per panel.
        $hostPanel.Add_ClientSizeChanged({ try { Update-Stretch } catch { } })
        Add-OverlayPaint $hostPanel "zone"

        $Script:Zones[$Key]     = $hostPanel
        $Script:ZoneHosts[$Key] = $hostPanel
        return $hostPanel
    }

    function Set-FieldButtonFit {
        <#
            Sizes the buttons that stand beside a field, ONCE, after the form has
            been scaled.

            Everything about this has to happen late. A single-line TextBox
            ignores the height it is constructed with and takes one from its
            font, so before the scale pass the number beside it is an intention,
            not a measurement - matching against it there put the Browse button
            off its row entirely. And it must not run inside Update-Fields: doing
            that fought the geometry pass and hid half the Migration Details
            panel.

            So: once, late, off real controls. Bottoms are aligned rather than
            tops, because that is how the design has always had them - the field
            sits at y=28 and the button at y=26 for exactly that reason.
        #>
        $pairs = @(
            @{ B = $btnBrowseUSMT; F = $txtUSMTPath; Pad = 20 }
        )
        foreach ($p in $pairs) {
            if (-not $p.B -or -not $p.F) { continue }
            try {
                $right = $p.B.Right
                $p.B.Height = $p.F.Height
                $p.B.Top    = $p.F.Bottom - $p.B.Height
                $p.B.Width  = [System.Windows.Forms.TextRenderer]::MeasureText($p.B.Text, $p.B.Font).Width + $p.Pad
                $p.B.Left   = $right - $p.B.Width      # the right edge stays where it was
            } catch { }
        }
        # The lookup pair: matched to each other and to the height of the buttons
        # in every other panel, which is what "they are bigger than the others"
        # was about.
        try {
            $lw = 0
            foreach ($b in @($btnListUsers, $btnListStores)) {
                $w2 = [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $b.Font).Width + 20
                if ($w2 -gt $lw) { $lw = $w2 }
            }
            if ($lw -gt 0) {
                # Height too, not just width. These were built at a design 28
                # while every button beside a field ends up at the field's own
                # height - 42 against 33 once scaled, which is what "they are
                # bigger than the buttons in the other panels" was.
                $lh = if ($btnBrowseUSMT -and $btnBrowseUSMT.Height -gt 0) { $btnBrowseUSMT.Height } else { $btnListUsers.Height }
                foreach ($b in @($btnListUsers, $btnListStores)) { $b.Width = $lw; $b.Height = $lh }
                $btnListStores.Left = $btnListUsers.Right + [int](6 * $Script:LayoutScale)
                # THE standard field-button size, in real pixels, published for
                # the dialogs. They are separate forms scaled separately, so
                # without a number to copy they can only be "about right" - which
                # is what every attempt at these two buttons has been.
                $Script:StdBtnW = $lw
                $Script:StdBtnH = $lh
            }
        } catch { }
    }

    function Add-OverlayPaint {
        <#
            Makes a surface paint the themed backdrop behind whatever is on it.

            The handler does one DrawImage of a cached bitmap - see
            Get-OverlayBitmap. With the overlay off it does nothing at all, so
            the default configuration pays nothing for the feature existing.
        #>
        param($Control, [string]$Surface)
        if (-not $Control) { return }
        $Control.Tag = "overlay-$Surface"
        # One list of every surface that carries the backdrop, so the timer,
        # the toggles and the theme change cannot drift apart about which
        # controls need repainting.
        if (-not $Script:OverlaySurfaces) { $Script:OverlaySurfaces = @() }
        $Script:OverlaySurfaces += $Control
        $Control.Add_Paint({
            param($paintSender, $e)
            if (-not $Script:OverlayEnabled) { return }
            try {
                $sfc = "$($paintSender.Tag)" -replace '^overlay-', ''
                $cw = $paintSender.ClientSize.Width; $ch = $paintSender.ClientSize.Height
                $cww = $cw; $chh = $ch      # $ch is reused as a loop variable below
                # ONE BACKDROP BEHIND THE WHOLE WINDOW, when the XAML artwork is
                # in use: every surface draws its own part of a single picture,
                # so the panels sit on a continuous image instead of each
                # showing an independent copy of it. The banner is exempt - it
                # is the picture, at its own full strength.
                $done = $false
                if ($Script:UseXamlArt -and $sfc -ne "header") {
                    $back = Get-WindowBackdrop -Width $Form.ClientSize.Width -Height $Form.ClientSize.Height `
                                -ThemeName $Script:CurrentThemeName
                    if ($back) {
                        $o = $Form.PointToClient($paintSender.PointToScreen([System.Drawing.Point]::Empty))
                        # THE WHOLE BACKDROP DRIFTS, by moving where it is drawn.
                        #
                        # The banner animates by compositing extra transparent
                        # layers; doing that on every surface is what cost the
                        # better part of a second a frame. Here there is nothing
                        # to composite - the picture is one blit already, so
                        # shifting where it lands animates it for no extra work
                        # at all.
                        #
                        # It ping-pongs inside the slack between the window's
                        # size and the backdrop's (quantised up to a 256 grid),
                        # so an edge can never be dragged into view and no second
                        # blit is needed to cover one.
                        $dx = 0; $dy = 0
                        if ($Script:OverlayAnimate -and -not $Script:Dragging -and $Script:WindowActive) {
                            $slackX = [Math]::Max(0, $back.Width  - $Form.ClientSize.Width)
                            $slackY = [Math]::Max(0, $back.Height - $Form.ClientSize.Height)
                            $tr = $Script:OverlayPhase * $Script:DriftStep
                            if ($slackX -gt 1) {
                                $p = ($tr % (2 * $slackX))
                                $dx = -[Math]::Abs($p - $slackX)
                            }
                            if ($slackY -gt 1) {
                                # Half the rate on the vertical, so the two axes
                                # do not turn round together and the drift never
                                # retraces its own path.
                                $p2 = ([int]($tr / 2) % (2 * $slackY))
                                $dy = -[Math]::Abs($p2 - $slackY)
                            }
                        }
                        $e.Graphics.DrawImageUnscaled($back, (-$o.X + $dx), (-$o.Y + $dy))
                        # Each surface washes its own region, because they carry
                        # different amounts of text and the shared picture cannot
                        # be dimmed for all of them at once.
                        $v = if ($Script:SurfaceVeil.ContainsKey($sfc)) { $Script:SurfaceVeil[$sfc] } else { 120 }
                        if ($v -gt 0) {
                            $vc = if ($sfc -eq "log") { $Script:T.OutputBg } else { $Script:T.GroupBg }
                            $vb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($v, $vc))
                            try { $e.Graphics.FillRectangle($vb, 0, 0, $cww, $chh) } finally { $vb.Dispose() }
                        }
                        $done = $true
                    }
                }
                if (-not $done) {
                    $bmp = Get-OverlayBitmap -Surface $sfc -Width $cw -Height $ch `
                            -ThemeName $Script:CurrentThemeName -Layer "ground"
                    if ($bmp) { $e.Graphics.DrawImageUnscaled($bmp, 0, 0) }
                }
                # The moving layers, each drawn twice at a wrapping offset. Two
                # blits per layer whatever is on it - which is the whole reason
                # the confetti can drift without costing anything per shape.
                # Two layers going opposite ways is what reads as motion; one
                # going one way just reads as a picture sliding.
                # ...but not while the window is being resized. The timer already
                # stands down during a drag; the PAINTING has to stand down with
                # it, or every resize frame still pays for four alpha blits of a
                # banner-sized layer. Two motion layers made that visible:
                # resizing while animating went to 95.6 ms against 79.8 ms with
                # the animation off.
                # PARTIAL CLIP = this paint is for one transparent child, not for
                # the whole surface. There are ~48 of those per panel repaint, so
                # everything below here that the child cannot see is skipped.
                $whole = ($e.ClipRectangle.Width -ge $cww -and $e.ClipRectangle.Height -ge $chh)
                # THE MOTION LAYERS ARE NOT SKIPPED ON A PARTIAL CLIP.
                #
                # They were, as a fast path, and that is what put a box back
                # around the banner's text the moment the animation was switched
                # on - with the graphics alone it never appeared. A transparent
                # caption repaints by asking its parent to paint into the
                # caption's clip, so skipping the motion there drew the caption's
                # rectangle from the ground layer alone while everything around
                # it had ground plus motion. The box was the drifting layer
                # missing, in exactly the shape of the words.
                #
                # It costs almost nothing to put back: only the banner animates,
                # and the banner has six children, not the forty-eight the fast
                # path was written for.
                if ((Test-OverlayAnimated $Script:CurrentThemeName $sfc) -and -not $Script:Dragging) {
                    foreach ($spec in (Get-MotionSpec $Script:CurrentThemeName)) {
                        $mot = Get-OverlayBitmap -Surface $sfc -Width $cw -Height $ch `
                                -ThemeName $Script:CurrentThemeName -Layer $spec.Layer
                        if (-not $mot) { continue }
                        if ($spec.Axis -eq "X") {
                            $span = $mot.Width
                            $off = ($Script:OverlayPhase * $spec.Speed) % $span
                            if ($off -lt 0) { $off += $span }
                            $e.Graphics.DrawImageUnscaled($mot, ($off - $span), 0)
                            $e.Graphics.DrawImageUnscaled($mot, $off, 0)
                        } else {
                            $span = $mot.Height
                            $off = ($Script:OverlayPhase * $spec.Speed) % $span
                            if ($off -lt 0) { $off += $span }
                            $e.Graphics.DrawImageUnscaled($mot, 0, ($off - $span))
                            $e.Graphics.DrawImageUnscaled($mot, 0, $off)
                        }
                    }
                }
                # PUT THE GROUP BOX BACK.
                #
                # A GroupBox draws its border and its caption in OnPaint, and the
                # Paint event fires afterwards - so blitting the backdrop over
                # the client area covered both, and every panel lost its title
                # the moment the graphics went on. Nothing in the source says so;
                # it only shows on screen.
                #
                # Redrawn here with TextRenderer, which is what the control
                # itself uses, so the caption lands exactly where it always did.
                # Only when the caption band is actually in the clip - a caption
                # sitting halfway down the panel does not need the group box
                # title measured and redrawn on its behalf.
                if ($paintSender -is [System.Windows.Forms.GroupBox] -and $paintSender.Text -and
                    $e.ClipRectangle.Y -le ($paintSender.Font.Height + 2)) {
                    $cap = $paintSender.Text
                    $cf  = $paintSender.Font
                    $ts  = [System.Windows.Forms.TextRenderer]::MeasureText($cap, $cf)
                    $bandY = [int]($ts.Height / 2)
                    # Stronger than the divider colour, and 1.6px rather than 1.
                    # A panel edge has to read as an edge with a splitter bar of
                    # similar weight right next to it; at the divider's own
                    # strength the two cancelled out and the panels looked
                    # borderless wherever they met one.
                    # Worked out once per theme, not once per paint. This runs on
                    # every repaint of every panel, and a transparent caption
                    # makes that once per caption as well.
                    if ($Script:PanelEdgeKey -ne $Script:CurrentThemeName) {
                        $b0 = Get-DividerColor
                        $Script:PanelEdgeColor = [System.Drawing.Color]::FromArgb(
                                [int]($b0.R + (($Script:T.Text.R - $b0.R) * 0.35)),
                                [int]($b0.G + (($Script:T.Text.G - $b0.G) * 0.35)),
                                [int]($b0.B + (($Script:T.Text.B - $b0.B) * 0.35)))
                        $Script:PanelEdgeKey = $Script:CurrentThemeName
                    }
                    # 1px, not 1.6. A fractional pen width is antialiased along
                    # its whole length, and this draws on every panel on every
                    # frame of a resize - it put ~20 ms on a divider frame for a
                    # difference the colour change already delivers.
                    $bp = New-Object System.Drawing.Pen($Script:PanelEdgeColor, 1)
                    try {
                        # the frame, broken where the caption sits
                        $e.Graphics.DrawLine($bp, 8, $bandY, 0, $bandY)
                        $e.Graphics.DrawLine($bp, 0, $bandY, 0, ($chh - 1))
                        $e.Graphics.DrawLine($bp, 0, ($chh - 1), ($cww - 1), ($chh - 1))
                        $e.Graphics.DrawLine($bp, ($cww - 1), ($chh - 1), ($cww - 1), $bandY)
                        $e.Graphics.DrawLine($bp, ($cww - 1), $bandY, (10 + $ts.Width), $bandY)
                    } finally { $bp.Dispose() }
                    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $cap, $cf,
                        (New-Object System.Drawing.Point(9, 0)), $paintSender.ForeColor)
                }
                # NOTHING IS DRAWN OVER THE BANNER'S TEXT. Not a halo, not the
                # text itself.
                #
                # A Label paints with TextRenderer (GDI); Graphics.DrawString is
                # GDI+, and the two lay the same string out 1px apart - measured.
                # So a halo lands 2px out on one side and flush on the other,
                # which is the "weird overlay or duplicate" this was reported as
                # three times. GDI text cannot be drawn translucently, so there
                # is no aligned fallback. Redrawing the captions here fails the
                # same way for a different reason: a Label pads its text inside
                # its own bounds and TextRenderer at the label origin does not.
                #
                # The banner earns legibility the way the panels do - see
                # $Script:SurfaceQuiet - not by painting over the artwork.
            } catch { }
        })
    }

    # The animation timer.
    #
    # 20 frames a second, and it EARNS its keep frame by frame: it does nothing
    # at all unless the backdrop is on, animation is on, the theme has something
    # moving, and the window is idle. It stops dead during a resize or a divider
    # drag - a frame there costs ~50 ms and is not going to share with confetti -
    # and while a migration is running, because a capture wants the CPU more
    # than the background does.
    $Script:OverlayTimer = New-Object System.Windows.Forms.Timer
    $Script:OverlayTimer.Interval = 50
    $Script:OverlayTimer.Add_Tick({
        # OVERRUN GUARD. If a tick ever costs more than the interval there is
        # always a timer message pending, DoEvents never drains the queue, and
        # the window stops responding - which is exactly what happened when the
        # panels were animated too. Rather than trust the estimate, measure each
        # tick and back the interval off if the machine cannot keep up; a remote
        # session or a busy desktop is entitled to a slower animation, not to a
        # hung one.
        if ($Script:OverlayTicking) { return }
        $Script:OverlayTicking = $true
        # MEASURE THE GAP BETWEEN TICKS, not the work inside one.
        #
        # The first version timed the tick body and never fired, because the
        # body only posts Invalidate calls - it is fast by construction. The
        # expense is the painting that happens afterwards, and the symptom is
        # that the next tick arrives late because the queue is still draining.
        # So the honest measure of "the machine cannot keep up" is the interval
        # we actually ACHIEVED versus the one we asked for.
        $gap = 0
        if ($Script:OverlayLastTick) { $gap = ([DateTime]::UtcNow - $Script:OverlayLastTick).TotalMilliseconds }
        $Script:OverlayLastTick = [DateTime]::UtcNow
        try {
            if ($Script:Dragging -or $Script:OperationRunning) { return }
            if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
            # NOT IN FRONT = NOT DRAWN.
            #
            # A locked workstation or another virtual desktop still delivers
            # timer ticks, so the tool carried on compositing a backdrop nobody
            # could see - and came back sluggish because the work had been
            # queueing up behind a window that was never repainting. Whether the
            # window is in front is the cheapest honest test of "is any of this
            # visible", and it costs one flag read per tick.
            if (-not $Script:WindowActive) { return }
            if (-not (Test-OverlayAnimated $Script:CurrentThemeName)) { return }
            $Script:OverlayPhase += 1
            foreach ($c in $Script:OverlaySurfaces) {
                # The banner animates by compositing layers and is listed in
                # $Script:AnimatedSurfaces. Everything else animates only when
                # the continuous backdrop is in use, where "animating" is one
                # blit landing a few pixels further along - see the paint
                # handler. That is cheap enough to do everywhere; compositing
                # layers everywhere was not.
                $ck = "$($c.Tag)" -replace '^overlay-', ''
                # ONE FRAME IN FIVE for the drifting surfaces.
                #
                # The banner needs 20fps: confetti falling at 5px a tick has to
                # be smooth. The backdrop does not - it ping-pongs a couple of
                # hundred pixels over minutes, and at that speed four frames out
                # of five are indistinguishable. Repainting all thirteen surfaces
                # at the banner's rate took the layout test from 25 seconds to
                # 171: every frame was affordable and there were five times more
                # of them than the picture needed.
                $drifts = ($Script:UseXamlArt -and $ck -ne "header" -and ($Script:OverlayPhase % $Script:DriftEvery) -eq 0)
                if ($c -and $c.Visible -and ($drifts -or (Test-OverlayAnimated $Script:CurrentThemeName $ck))) {
                    # $true - INVALIDATE THE CHILDREN TOO.
                    #
                    # A transparent caption is painted from its parent, but it
                    # only repaints when it is invalidated. Invalidating the
                    # parent alone advanced the artwork behind the title while
                    # the title's own rectangle kept the previous frame, so the
                    # moving background appeared to stop dead inside a box the
                    # shape of the words - "it looks like it gets cut off".
                    $c.Invalidate($true)
                }
            }
        } catch { } finally {
            $Script:OverlayTicking = $false
            # NEVER BACK OFF BECAUSE OF A RESIZE.
            #
            # Frames are late during a drag for a reason that has nothing to do
            # with the animation - the window is busy laying itself out, and the
            # animation has already stood down. Counting those as "the machine
            # cannot keep up" doubled the interval two or three times on the way
            # through a resize and then left it there, so the animation came out
            # of every resize permanently slower until the graphics were toggled.
            # That is the "it slows down after resizing" that kept coming back.
            $skipBackoff = ($Script:Dragging -or -not $Script:WindowActive)
            if ($skipBackoff) {
                $Script:OverlayLate = 0
                $Script:OverlayLastTick = $null
                $gap = 0
            }
            # Two frames arriving 2.5x later than asked for means the window is
            # spending all its time painting. Back off rather than let the
            # message queue stop draining - a saturated queue is not a slow
            # animation, it is a window that has stopped responding.
            if ($gap -gt ($Script:OverlayTimer.Interval * 2.5) -and $Script:OverlayTimer.Interval -lt 400) {
                # Four in a row, not two. Maximising does not raise ResizeBegin,
                # so it cannot be excluded the way a drag is, and it stalls a
                # frame or two on the way past. The back-off is for a machine
                # that is genuinely too slow, which shows as late frames that
                # keep coming rather than a brief stumble.
                $Script:OverlayLate++
                if ($Script:OverlayLate -ge 4) {
                    $Script:OverlayTimer.Interval = [int][Math]::Min(400, $Script:OverlayTimer.Interval * 2)
                    $Script:OverlayLate = 0
                    Write-CrashLog ("Overlay animation backed off to $($Script:OverlayTimer.Interval) ms - frames were arriving {0:N0} ms apart" -f $gap)
                }
            } elseif ($gap -gt 0) { $Script:OverlayLate = 0 }
        }
    })

    function Set-TransparentLabels {
        <#
            Stops every caption sitting in its own solid rectangle when the
            backdrop is on - "every single theme has these boxes around the
            text like the title and subtitles".

            A Label with no BackColor of its own does not inherit its parent's
            paint, it inherits its parent's COLOUR and then fills itself with
            it. Over a painted panel that is a grey box with a word in it. The
            fix is Color.Transparent, which makes WinForms render the parent -
            including the parent's Paint handler, which is where the artwork is.

            Only Label, CheckBox and RadioButton: they are the control types
            that declare SupportsTransparentBackColor. Buttons and text boxes
            do not, and asking them for it silently does nothing.

            Off restores inheritance rather than picking a colour, so the tool
            with the backdrop switched off looks exactly as it always has.
        #>
        param([bool]$On)
        $paint = {
            param($ctrl, $Colour)
            foreach ($ch in $ctrl.Controls) {
                if ($ch -is [System.Windows.Forms.Label] -or
                    $ch -is [System.Windows.Forms.CheckBox] -or
                    $ch -is [System.Windows.Forms.RadioButton]) {
                    # The Expert toggle paints itself to show its state; leave it be.
                    if (-not [Object]::ReferenceEquals($ch, $chkExpertMode)) {
                        try {
                            if ($null -eq $Colour) { $ch.ResetBackColor() }
                            else                   { $ch.BackColor = $Colour }
                        } catch { }
                    }
                }
                & $paint $ch $Colour
            }
        }
        if (-not $On) { try { & $paint $Form $null } catch { }; return }

        # TRANSPARENT, EVERYWHERE. It is the only thing with no visible box.
        #
        # Two cheaper schemes were tried and both showed. A flat fill - one
        # colour per surface, or the backdrop sampled under each caption - is
        # still flat over a gradient, so a wide caption sits in a visible patch.
        # Reported on "USMT files found", "Action", "Save to", the hints, the
        # check boxes and the status bar. No flat colour disappears into artwork
        # that is not flat.
        #
        # Transparency was never the wrong answer; the paint handler being
        # expensive was. A transparent caption is drawn by asking its parent to
        # repaint clipped to the caption, so the parent's handler runs once per
        # caption - 49 repaints on a 48-caption panel. Fixed in Add-OverlayPaint
        # with fast paths that skip the motion layers and the group box caption
        # when the clip does not need them.
        try { & $paint $Form ([System.Drawing.Color]::Transparent) } catch { }

    }

    function Set-OverlayTimerState {
        # The one place that decides whether the timer runs. Both switches call
        # it, so the flag cannot end up true with the timer stopped - which is
        # how the tool came up showing the artwork standing still after a
        # restart.
        try {
            if ($Script:OverlayEnabled -and $Script:OverlayAnimate) {
                $Script:OverlayTimer.Interval = 50      # undo any earlier back-off
                $Script:OverlayTimer.Start()
            } else { $Script:OverlayTimer.Stop() }
        } catch { }
    }

    function Set-OverlayAnimate {
        <#
            Motion on or off. Deliberately does NOT touch the caches.

            It used to call Set-OverlayEnabled, which throws away every rendered
            master and repaints the window from nothing - so turning the movement
            on or off stalled for the length of a full re-render, for a change
            that does not alter a single pixel of the artwork.
        #>
        param([bool]$On)
        $Script:OverlayAnimate = $On
        Set-OverlayTimerState
        foreach ($c in $Script:OverlaySurfaces) {
            if ($c) { try { $c.Invalidate($false) } catch { } }
        }
    }

    function Set-OverlayEnabled {
        <#
            Turns the backdrop on or off and repaints the surfaces that show it.
            Also called after a theme change, because the cached art belongs to
            the theme it was drawn for.
        #>
        param([bool]$On)
        $Script:OverlayEnabled = $On
        Clear-OverlayCache
        Set-OverlayTimerState
        # Re-colour first: the opaque controls (the log, the lookup list, the
        # plan pane) take their background FROM the artwork, and Get-OverlayTint
        # answers differently depending on the flag set just above. Then make
        # the captions transparent, because Apply-Theme does not touch them and
        # would otherwise not undo it either.
        try { Apply-Theme -Form $Form -ThemeName $Script:CurrentThemeName } catch { }
        Set-TransparentLabels $On
        # EVERY registered surface, not a hand-written list of four.
        #
        # This is why turning the graphics on appeared to do nothing except in
        # the title bar: only the header and the three zone hosts were
        # invalidated here, and the panels kept whatever they had already
        # painted. Switching the animation on afterwards then made them all
        # appear at once, because the timer walks $Script:OverlaySurfaces - the
        # list this now uses.
        $seen = @($pnlHeader, $Script:ZoneHosts["Left"], $Script:ZoneHosts["RightTop"], $Script:ZoneHosts["RightBottom"])
        foreach ($c in @($seen + $Script:OverlaySurfaces)) {
            if ($c) { try { $c.Invalidate($true) } catch { } }
        }
    }

    function Register-Panel {
        param([string]$Key, [string]$Title, $Ctl, [string]$Zone, [int]$Order,
              [int]$DesignHeight = 0, [switch]$Fill)
        $Script:Panels += , ([pscustomobject]@{
            Key = $Key; Title = $Title; Ctl = $Ctl
            Zone = $Zone; Order = $Order
            DesignHeight = $DesignHeight; Fill = [bool]$Fill; Shown = $true
        })
        # NO per-panel SizeChanged handler.
        #
        # There was one, to catch a panel being moved to a narrower zone - its
        # width changes without any zone's changing. But Update-Layout already
        # ends with Update-StretchNow, so that case was covered twice over, and
        # the handlers were not free: a .NET event calling back into a
        # PowerShell scriptblock costs a few milliseconds of runspace
        # marshalling, and one divider nudge fired eleven of them (eight panels
        # plus three zones) before any of them did any work. That overhead alone
        # was about half the cost of a frame. Three zone-level handlers are
        # enough, and they are the ones that fire on a real resize.
    }

    function Update-Layout {
        <#
            Rebuilds all three zones from the registry. Cheap enough to call for
            any change - moving a panel, showing the Expert box, loading a saved
            arrangement - which means there is exactly one code path that
            decides where anything is.
        #>
        # Batched during startup. Restoring the saved settings changes the
        # arrangement two or three times in a row - the saved layout, then the
        # saved mode - and each rebuild reparents every panel and re-fits every
        # control inside it. One rebuild at the end does the same job.
        if ($Script:LayoutSuspended) { $Script:LayoutDirty = $true; return }
        $Script:LayoutDirty = $false
        $gap = [int]($Script:LayoutGap * $Script:LayoutScale)
        if ($gap -lt 4) { $gap = 4 }
        # A rebuild reparents every panel, which is the one case where the
        # window really would be seen assembling itself. It happens on a menu
        # click, not on every frame of a drag, so the freeze is worth its cost
        # here - which is exactly why it is not used in the resize path.
        $formPaint = Suspend-Paint $Form
        foreach ($zk in @("Left", "RightTop", "RightBottom")) {
            $z = $Script:Zones[$zk]
            if (-not $z) { continue }
            $z.SuspendLayout()
            try {
                $z.Controls.Clear()
                $items = @($Script:Panels | Where-Object { $_.Zone -eq $zk -and $_.Shown -and $_.Ctl } | Sort-Object Order)
                # Per PANEL, not per zone and not one number for the window.
                #
                # A panel carrying labelled rows cannot go below the label plus
                # the box; the log and the lookup list are just a box of text and
                # can. Holding those two to the setup column's width is what made
                # them overhang the right zone and lose the border down that
                # side. Keying it off the zone instead was the obvious next
                # guess and is also wrong - panels MOVE between zones, so a Tools
                # panel sent to the right would inherit a floor far below its own
                # content and overhang exactly the same way.
                $minW  = [int]($Script:PanelDesignWidth * $Script:LayoutScale)
                $minWN = [int]($Script:RightZoneMinWidth * $Script:LayoutScale)

                # The FILL panel goes in first, so it docks LAST and is left with
                # whatever the fixed-height ones do not take.
                foreach ($p in @($items | Where-Object { $_.Fill })) {
                    $p.Ctl.Visible = $true
                    $p.Ctl.Dock = "Fill"
                    # A panel can be sent to a zone narrower than its own
                    # contents. Nothing can make a labelled row narrower than its
                    # label plus its box, so the honest answer is a minimum width
                    # and a scroll bar, not a silently clipped right-hand edge.
                    # A MINIMUM HEIGHT, not just a minimum width.
                    #
                    # Dock=Fill takes whatever the Top-docked panels leave, and
                    # when they add up to more than the zone that is nothing at
                    # all: measured, the Fill panel goes to height 0 and simply
                    # is not there. That is the reported fault - turning Expert
                    # mode on adds a tall panel and the summary disappeared, with
                    # no way to scroll to it because a zero-height control adds
                    # nothing to scroll to. With a floor it keeps its size and
                    # the zone's AutoScroll can reach it.
                    $minH = if ($p.DesignHeight -gt 0) { [int]($p.DesignHeight * $Script:LayoutScale) }
                            else { [int](140 * $Script:LayoutScale) }
                    $pw = if ($Script:NarrowPanels -contains $p.Key) { $minWN } else { $minW }
                    $p.Ctl.MinimumSize = New-Object System.Drawing.Size($pw, $minH)
                    $z.Controls.Add($p.Ctl)
                }
                # Then the fixed-height ones, BOTTOM-most first: the last control
                # added has the highest z-order and docks first, so it takes the
                # top. A thin spacer between each pair gives the gap, because
                # Dock ignores Margin.
                $tops = @($items | Where-Object { -not $_.Fill })
                for ($i = $tops.Count - 1; $i -ge 0; $i--) {
                    $p = $tops[$i]
                    if ($i -lt ($tops.Count - 1) -or @($items | Where-Object { $_.Fill }).Count -gt 0) {
                        $sp = New-Object System.Windows.Forms.Panel
                        $sp.Dock = "Top"; $sp.Height = $gap; $sp.BackColor = $Script:T.DarkBg
                        $z.Controls.Add($sp)
                    }
                    $p.Ctl.Visible = $true
                    $p.Ctl.Dock = "Top"
                    $pw = if ($Script:NarrowPanels -contains $p.Key) { $minWN } else { $minW }
                    $p.Ctl.MinimumSize = New-Object System.Drawing.Size($pw, 0)
                    $p.Ctl.Height = [int]($p.DesignHeight * $Script:LayoutScale)
                    $z.Controls.Add($p.Ctl)
                }
                # TELL THE ZONE HOW TALL ITS CONTENTS ARE.
                #
                # AutoScroll works out its range from children that are POSITIONED
                # past the edge, and a docked child never is - Dock lays out
                # inside whatever room is left, so the range stayed at the
                # visible height and the scroll bar stopped at the last panel
                # that happened to fit. Reported as "you can't scroll past the
                # actions bar": the summary below it was real, sized, and
                # unreachable.
                #
                # The stack's true height is known here, so say so outright.
                $stack = 0
                foreach ($p in $items) {
                    $h2 = if ($p.Fill) {
                        if ($p.DesignHeight -gt 0) { [int]($p.DesignHeight * $Script:LayoutScale) }
                        else { [int](140 * $Script:LayoutScale) }
                    } else { [int]($p.DesignHeight * $Script:LayoutScale) }
                    $stack += $h2 + $gap
                }
                $z.AutoScrollMinSize = New-Object System.Drawing.Size(0, $stack)
            } catch {
                Write-CrashLog "Zone '$zk' rebuild failed: $($_.Exception.Message)"
            } finally { $z.ResumeLayout($true) }
        }
        # Controls.Clear() leaves a hidden panel parentless, which is what we
        # want, but Visible has to say so too or it can flash on the form.
        foreach ($p in @($Script:Panels | Where-Object { -not $_.Shown -and $_.Ctl })) {
            try { $p.Ctl.Visible = $false } catch { }
        }
        # An empty zone gives its space back rather than sitting there blank.
        # This is what makes "send everything to the left" actually hand the
        # whole window to the setup column.
        try {
            $rt = @($Script:Panels | Where-Object { $_.Zone -eq "RightTop"    -and $_.Shown }).Count
            $rb = @($Script:Panels | Where-Object { $_.Zone -eq "RightBottom" -and $_.Shown }).Count
            $lf = @($Script:Panels | Where-Object { $_.Zone -eq "Left"        -and $_.Shown }).Count
            $splitRight.Panel1Collapsed = ($rt -eq 0)
            $splitRight.Panel2Collapsed = ($rb -eq 0)
            $split.Panel2Collapsed      = (($rt + $rb) -eq 0)
            $split.Panel1Collapsed      = ($lf -eq 0)
        } catch { }
        Resume-Paint $formPaint
        Update-StretchNow
    }

    # ---- Horizontal stretch inside a panel ----
    # The panels resize now, but their contents are laid out at fixed pixel
    # positions. Rather than re-introduce Anchor - which is a margin captured at
    # an unpredictable moment, and the direct cause of the vanishing Browse
    # button - each control that should follow the width is registered with two
    # shares: how much of the extra width moves it (DX) and how much widens it
    # (DW). 0.5 means "half", which is how the two-column rows keep their halves
    # equal. Base positions are recorded once, while every panel is still at its
    # design width, and every later size is computed from those.
    $Script:StretchMap = @()
    # Every group box in this layout is 625 design px wide; the header panel is
    # the odd one out at 665.
    $Script:PanelDesignWidth = 625
# The right column's panels are a log and a list - neither has a labelled row to
# keep whole, so they do not need the setup column's width and holding them to it
# only made them overhang a zone they could not fit in. This is their own floor,
# and Set-SplitterLayout uses the same number so the divider cannot be dragged past
# the point where a whole panel still fits.
$Script:RightZoneMinWidth = 330
# The panels that may use it: a log and a list, neither of which has a labelled
# row to keep whole. Everything else keeps the setup column's width wherever it
# is sent, so moving a panel between zones cannot shrink it below its contents.
$Script:NarrowPanels = @("Output", "Lookup")
    function Add-Stretch {
        param($Ctl, $Container, [double]$DX = 0, [double]$DW = 0, [int]$DesignWidth = 0)
        if (-not $Ctl -or -not $Container) { return }
        $Script:StretchMap += , ([pscustomobject]@{
            Ctl = $Ctl; Container = $Container; DX = $DX; DW = $DW
            DesignWidth = $(if ($DesignWidth -gt 0) { $DesignWidth } else { $Script:PanelDesignWidth })
            BaseX = 0; BaseW = 0; BaseC = 0
        })
    }
    function Get-DesignClientWidth {
        # What a container's CLIENT width is when the container is at its design
        # width - i.e. the design width scaled, less whatever the border costs.
        param($Container, [int]$DesignWidth)
        $chrome = $Container.Width - $Container.ClientSize.Width
        if ($chrome -lt 0) { $chrome = 0 }
        return ([int]($DesignWidth * $Script:LayoutScale) - $chrome)
    }
    function Save-StretchBase {
        <#
            Called once, immediately after scaling and BEFORE anything is docked
            into a zone.

            BaseC is COMPUTED from the design width rather than read off the
            container. Reading it looked equivalent and was not: a container
            that had already been resized by something else - the Expert panel
            is docked and undocked as the mode changes - recorded a base that
            was tens of pixels out, and every control in it was then stretched
            by that much too far and hung over the edge of its own panel.
            Deriving it from the number the layout was authored at cannot drift.
        #>
        foreach ($e in $Script:StretchMap) {
            try {
                $e.BaseX = $e.Ctl.Left; $e.BaseW = $e.Ctl.Width
                $e.BaseC = Get-DesignClientWidth $e.Container $e.DesignWidth
            } catch { }
        }
        $Script:DetailsBaseWidth = Get-DesignClientWidth $grpDetails $Script:PanelDesignWidth
        $Script:StretchReady = $true
    }
    function Update-Stretch {
        <#
            Re-fits every registered control to its panel's CURRENT width.

            Called from a size-changed handler on each zone as well as from
            Update-Layout, because the width a panel has the instant it is added
            to a zone is not the width it ends up with: the table has not laid
            out yet, and the scroll bar that will take 17px off has not appeared.
            Running only at Add time left everything sized for the wider,
            momentary value and hanging over the panel edge. It recomputes from
            the recorded base every time, so calling it repeatedly is free of
            drift - and the guard stops the Update-Fields call inside it from
            re-entering through another resize.
        #>
        <#
            COALESCED. Marks the layout dirty and lets a short timer do the work
            once, instead of doing it here and now.

            This is the fix for "it is fast for three seconds and then it
            crawls". One nudge of a divider resizes both splitter panels, which
            resizes three zones, which resizes eight panels - and every one of
            those raises SizeChanged, and every one of those used to run a full
            stretch pass. Eleven passes at ~50 ms each is 570 ms of work for one
            frame of a drag, measured. The mouse produces frames far faster than
            that, so the queue grew for as long as the drag lasted, which is
            exactly what "fast at first, then crawling" is.

            The re-entrancy guard did not help: these fire one after another, not
            nested. They have to be COLLAPSED, not merely serialised.

            The timer is started only if it is not already running, so it fires
            a fixed ~16 ms after the FIRST event of a burst rather than being
            pushed back by each new one - a continuous drag still updates, at a
            bounded rate, instead of never.
        #>
        if (-not $Script:StretchReady) { return }
        $Script:StretchPending = $true
        if ($Script:StretchTimer) {
            if (-not $Script:StretchTimer.Enabled) { $Script:StretchTimer.Start() }
        } else {
            Update-StretchNow          # before the timer exists (startup)
        }
    }

    # ~60 frames a second, which is as often as a screen can show a change.
    $Script:StretchTimer = New-Object System.Windows.Forms.Timer
    $Script:StretchTimer.Interval = 16
    $Script:StretchTimer.Add_Tick({
        $Script:StretchTimer.Stop()
        if ($Script:StretchPending) {
            $Script:StretchPending = $false
            Update-StretchNow
        }
    })

    function Enter-DragMode {
        <#
            Marks a drag in progress. The flag makes Update-Stretch do geometry
            only, and lets the repaint be queued instead of forced.

            It does NOT suspend layout on the zones. That was tried: freezing
            the panel tree for the duration of a drag measured 49.5 ms a frame
            against 44.7 ms for laying it out live, so it bought nothing and
            cost the live feedback of watching the panels resize under the
            divider. What was actually slow was the zone table being AutoSize -
            see the note in Update-Layout.
        #>
        $Script:Dragging = $true
    }
    function Exit-DragMode {
        $Script:Dragging = $false
        try { Update-StretchNow } catch { }
        # Nothing to re-read here any more: a transparent caption shows whatever
        # its parent paints, so it follows the artwork through a resize on its
        # own. The sampled-colour scheme this replaced needed a pass after every
        # drag, and doing that inline took a divider frame from 65 ms to 340 ms.
        #
        # But the surfaces DO need a repaint. Mid-drag they are handed the last
        # bitmap that was rendered, which is the wrong size once the drag has
        # moved on - too small leaves a strip of bare panel, which is the "weird
        # boxes in the middle" seen while stretching the window. The correct
        # size is rendered now that the mouse is up.
        # COALESCED. SplitterMoved fires once a frame while a divider is moving,
        # not once when it stops, so repainting every surface here directly cost
        # a divider frame 83 ms against 55 ms. One repaint after things settle
        # is all this needs.
        if ($Script:OverlayEnabled) {
            if (-not $Script:SettleTimer) {
                $Script:SettleTimer = New-Object System.Windows.Forms.Timer
                $Script:SettleTimer.Interval = 220
                # The whole tick is guarded: an exception escaping a Timer tick
                # is a modal dialog, not a logged error.
                $Script:SettleTimer.Add_Tick({
                    try {
                        $Script:SettleTimer.Stop()
                        if ($Script:Dragging -or $Form.IsDisposed -or $Form.Disposing) { return }
                        # Back to full speed. A resize can only ever have made
                        # the animation look slow for reasons that are now over.
                        if ($Script:OverlayTimer -and $Script:OverlayTimer.Interval -ne 50) {
                            $Script:OverlayTimer.Interval = 50
                        }
                        $Script:OverlayLate = 0
                        $Script:OverlayLastTick = $null
                        foreach ($c in $Script:OverlaySurfaces) {
                            if ($c) { try { $c.Invalidate($true) } catch { } }
                        }
                    } catch { }
                })
            }
            $Script:SettleTimer.Stop(); $Script:SettleTimer.Start()
        }
    }

    function Suspend-Paint {
        # Freezes painting for a control and everything under it. Returns the
        # handle so the caller can put it back, or IntPtr.Zero when the native
        # helper is unavailable and the caller should simply not bother.
        param($Control)
        if (-not $Script:RedrawAvailable -or -not $Control) { return [IntPtr]::Zero }
        try {
            if (-not $Control.IsHandleCreated) { return [IntPtr]::Zero }
            [RedrawHelper]::Suspend($Control.Handle)
            return $Control.Handle
        } catch { return [IntPtr]::Zero }
    }
    function Resume-Paint {
        param($Handle)
        if (-not $Script:RedrawAvailable) { return }
        if ($Handle -eq [IntPtr]::Zero) { return }
        try { [RedrawHelper]::Resume($Handle, (-not $Script:Dragging)) } catch { }
    }
    function Update-StretchNow {
        # Update-Stretch with the re-entrancy guard, for callers that know they
        # are not already inside one (the perf probe).
        if ($Script:StretchBusy) { return }
        $Script:StretchBusy = $true
        try { Update-StretchCore } finally { $Script:StretchBusy = $false }
    }
    function Update-StretchCore {
        # Which panels were touched, so each is repainted exactly once.
        #
        # A ComboBox with FlatStyle=Flat draws its own drop-down arrow, and
        # Windows only invalidates the NEWLY exposed strip when a control grows.
        # The arrow was therefore left painted at the old right edge as well as
        # the new one - two arrows on one box, until anything forced a full
        # repaint (such as opening the drop-down, which is why clicking it
        # "magically fixed" it).
        $touched = @{}
        # One layout pass for the whole sweep instead of one per control. Without
        # this, moving forty controls inside six panels triggers forty layout
        # passes and forty partial repaints, which is what a divider drag felt
        # like. Suspended here, resumed with the repaint at the end.
        $suspended = @{}
        foreach ($e in $Script:StretchMap) {
            if (-not $e.Container) { continue }
            $k = $e.Container.GetHashCode()
            if (-not $suspended.ContainsKey($k)) {
                $suspended[$k] = $e.Container
                try { $e.Container.SuspendLayout() } catch { }
            }
        }
        # NOT WM_SETREDRAW. Freezing and thawing the zone with RedrawWindow and
        # RDW_ALLCHILDREN walks all ~150 child windows and measured 37 ms per
        # frame - on its own, more than half the cost of a frame, and it was
        # being paid to prevent flicker that two cheaper things already prevent:
        # the controls are double-buffered, and the whole of each panel that
        # changed is invalidated below rather than just the strip Windows
        # exposes. (Suspend-Paint is kept for the one place that genuinely
        # batches a rebuild - see Update-Layout.)
        foreach ($e in $Script:StretchMap) {
            if ($e.BaseC -le 0) { continue }
            try {
                $d = $e.Container.ClientSize.Width - $e.BaseC
                if ($d -lt 0) { $d = 0 }        # never squeeze below the design layout
                $moved = $false
                if ($e.DX -ne 0) {
                    $nx = $e.BaseX + [int]($d * $e.DX)
                    if ($nx -ne $e.Ctl.Left) { $e.Ctl.Left = $nx; $moved = $true }
                }
                if ($e.DW -ne 0) {
                    $nw = [Math]::Max(8, $e.BaseW + [int]($d * $e.DW))
                    if ($nw -ne $e.Ctl.Width) { $e.Ctl.Width = $nw; $moved = $true }
                }
                if ($moved) { $touched[$e.Container.GetHashCode()] = $e.Container }
            } catch { }
        }
        # Migration Details re-places itself: which controls are even on screen
        # depends on the operation, so it cannot be a static map.
        #
        # During a drag this is the GEOMETRY ONLY. The full Update-Fields also
        # word-wraps ten tooltips, rewrites the window title, rebuilds the
        # summary pane and regenerates the command preview - none of which can
        # change because a divider moved, and all of which used to run on every
        # frame. The full pass runs once when the drag finishes.
        if ($Script:FieldsReady) {
            if ($Script:Dragging) { try { Update-DetailsGeometry } catch { } }
            else                  { try { Update-Fields } catch { } }
            $touched[$grpDetails.GetHashCode()] = $grpDetails
        }
        # Resume with layout suppressed ($false), then invalidate only the
        # panels that actually changed. Resuming with layout ON here would run
        # the pass this whole block exists to avoid.
        foreach ($c in $suspended.Values) { try { $c.ResumeLayout($false) } catch { } }
        # One repaint per panel that actually changed, children included.
        #
        # Invalidate($true) rather than Refresh(): it QUEUES the paint for the
        # next WM_PAINT, which Windows coalesces, instead of forcing it
        # synchronously here. Invalidating the whole panel rather than letting
        # Windows expose only the newly uncovered strip is also what stops the
        # combo boxes drawing their drop-down arrow twice - which is what the
        # much more expensive WM_SETREDRAW freeze used to be here for.
        foreach ($c in $touched.Values) { try { $c.Invalidate($true) } catch { } }
    }

    # ---- The header becomes one panel ----
    # Title, subtitle, elevation banner and the mode toggle were five loose
    # controls sitting on the form at fixed coordinates. As a single panel they
    # are one thing the layout can place, and they can be moved or hidden like
    # anything else.
    # LOAD-BEARING: the header panel is added to the FORM here, and every group
    # box stays on the form too. Nothing is moved into a zone until after
    # Set-FormScale has run.
    #
    # Form.Scale() walks the form's control TREE. A control that has been taken
    # off the form is not in that tree and is silently left at 1.0 - so pulling
    # the panels out at this point produced a window whose group boxes were the
    # right (scaled) height with design-sized contents inside them, and a USMT
    # Browse button back outside its group. Reparenting happens in Update-Layout,
    # which runs after the scaling pass.
    # Composited when the helper compiled, so the banner's transparent captions
    # and the artwork drifting behind them are presented in the same frame. Falls
    # back to a plain Panel if the Add-Type block failed, because a stutter is
    # better than no window.
    $pnlHeader = if ($Script:NativeHelpers) {
        try { New-Object UTWCompositedPanel } catch { New-Object System.Windows.Forms.Panel }
    } else { New-Object System.Windows.Forms.Panel }
    $pnlHeader.BackColor = $t.DarkBg
    $pnlHeader.Location = New-Object System.Drawing.Point(0, 0)
    $pnlHeader.Size = New-Object System.Drawing.Size(625, 70)
    $Form.Controls.Add($pnlHeader)
    # The one surface where the backdrop is properly visible: everything on
    # the header is a label, and a WinForms label does not paint its own
    # background - so the art shows behind the title, not only in the gaps.
    Add-OverlayPaint $pnlHeader "header"
    foreach ($c in @($lblTitle, $lblSubtitle, $lblAdminWarn, $lblMode, $chkExpertMode, $rbSimple, $rbExpert, $pnlAccent)) {
        if ($c) { $Form.Controls.Remove($c); $pnlHeader.Controls.Add($c) }
    }
    # The theme picker moved to the menu bar; keeping a duplicate in the header
    # was one of the redundancies worth removing.
    foreach ($c in @($lblTheme, $cmbTheme)) {
        if ($c) { $Form.Controls.Remove($c); $c.Visible = $false }
    }

    # The right column splits again, horizontally: the list on top, the log
    # underneath. This is the space maximising actually buys you - a list of the
    # profiles or stores you are working with, rather than a wider log.
    $splitRight = New-Object System.Windows.Forms.SplitContainer
    $splitRight.Orientation = "Horizontal"
    $splitRight.Dock = "Fill"
    $splitRight.BackColor = (Get-DividerColor)
    $splitRight.SplitterWidth = 6
    $splitRight.Tag = "split"
    $split.Panel2.Controls.Add($splitRight)

    # Named for what it is FOR, not for what it holds. "Users and stores" said
    # nothing about why the panel exists; it is the fill-in-the-blanks half of
    # Migration Details - it looks up the two values that are easiest to get
    # wrong by typing (whose profile, and which store) and puts them in the
    # form for you.
    $grpBrowse = New-Object System.Windows.Forms.GroupBox
    $grpBrowse.Text = "  Lookup  "; $grpBrowse.Font = $FontSection; $grpBrowse.ForeColor = $t.Primary
    $grpBrowse.BackColor = $t.GroupBg
    # On the FORM until Update-Layout moves it, for the same reason as the
    # header: a panel outside the form's control tree is not scaled by
    # Form.Scale(), and comes out with design-sized contents in a scaled box.
    $grpBrowse.Location = New-Object System.Drawing.Point(0, 0)
    $grpBrowse.Size = New-Object System.Drawing.Size(625, 300)
    $Form.Controls.Add($grpBrowse)

    # A toolbar row across the top of the group. Everything in it DOCKS - the
    # two buttons in a left-docked strip, the hint filling what is left - so it
    # follows the group's width without an anchor, and therefore without the
    # captured-margin trap that anchors bring.
    $pnlBrowseBar = New-Object System.Windows.Forms.Panel
    # Two lines of room. The hint wraps rather than being cut off when the
    # panel is narrow, and a wrapped second line has somewhere to go.
    $pnlBrowseBar.Dock = "Top"; $pnlBrowseBar.Height = 52; $pnlBrowseBar.BackColor = $t.GroupBg
    $pnlBrowseBar.Tag = "group-panel"
    $grpBrowse.Controls.Add($pnlBrowseBar)

    $pnlBrowseBtns = New-Object System.Windows.Forms.Panel
    $pnlBrowseBtns.Dock = "Left"; $pnlBrowseBtns.Width = 240; $pnlBrowseBtns.BackColor = $t.GroupBg
    $pnlBrowseBtns.Tag = "group-panel"
    $pnlBrowseBar.Controls.Add($pnlBrowseBtns)

    $btnListUsers = New-Object System.Windows.Forms.Button
    $btnListUsers.Text = "List users"; $btnListUsers.Font = $FontNormal
    $btnListUsers.Location = New-Object System.Drawing.Point(8, 3); $btnListUsers.Size = New-Object System.Drawing.Size(110, 28)
    $btnListUsers.FlatStyle = "Flat"; $btnListUsers.BackColor = $t.MedBg; $btnListUsers.ForeColor = $t.Text; $btnListUsers.Tag = "browse"
    $pnlBrowseBtns.Controls.Add($btnListUsers)
    $btnListStores = New-Object System.Windows.Forms.Button
    $btnListStores.Text = "List stores"; $btnListStores.Font = $FontNormal
    $btnListStores.Location = New-Object System.Drawing.Point(124, 3); $btnListStores.Size = New-Object System.Drawing.Size(110, 28)
    $btnListStores.FlatStyle = "Flat"; $btnListStores.BackColor = $t.MedBg; $btnListStores.ForeColor = $t.Text; $btnListStores.Tag = "browse"
    $pnlBrowseBtns.Controls.Add($btnListStores)
    # Sized as a PAIR by Set-FieldButtonFit, once the form has been scaled.

    $lblBrowseHint = New-Object System.Windows.Forms.Label
    $lblBrowseHint.Text = "Pick a row, then use the buttons below. Right-click works too."
    $lblBrowseHint.Font = $FontSmall; $lblBrowseHint.ForeColor = $t.TextDim; $lblBrowseHint.Tag = "dim"
    # AutoEllipsis, not wrapping. Docked Fill with wrapping on, narrowing the
    # panel broke this sentence onto a second line inside a bar only tall enough
    # for one - so it read as clipped text rather than as a hint. Trailing dots
    # are the honest way to say "there is more of this".
    $lblBrowseHint.AutoSize = $false; $lblBrowseHint.TextAlign = "MiddleLeft"; $lblBrowseHint.AutoEllipsis = $true
    $lblBrowseHint.Dock = "Fill"
    $lblBrowseHint.Padding = New-Object System.Windows.Forms.Padding(6, 0, 4, 0)
    $pnlBrowseBar.Controls.Add($lblBrowseHint)
    $lblBrowseHint.BringToFront()

    <#
        VISIBLE BUTTONS FOR THE THINGS THAT WERE RIGHT-CLICK ONLY.

        Right-click is a mouse gesture. Over RDP on a phone it is a long press
        that has to be held still, on a row that is a few millimetres tall, and
        it is the only way to reach these actions - including Delete Profile,
        which was added to the context menu and nowhere else. On a touch screen
        that made the most important action in this panel the hardest to reach.

        The menu stays: it is faster with a mouse and it is where the Refresh
        lives. This is the same three actions, always on screen, at a size a
        finger can hit.
    #>
    $pnlBrowseActions = New-Object System.Windows.Forms.Panel
    $pnlBrowseActions.Dock = "Bottom"; $pnlBrowseActions.Height = 38; $pnlBrowseActions.BackColor = $t.GroupBg
    $pnlBrowseActions.Tag = "group-panel"
    $grpBrowse.Controls.Add($pnlBrowseActions)

    $btnBrowseUse = New-Object System.Windows.Forms.Button
    # Text is set by Update-BrowseActions - this list shows profiles or stores
    # depending on which button filled it, and one label cannot be right for both.
    $btnBrowseUse.Text = "Select profile"; $btnBrowseUse.Font = $FontNormal
    $btnBrowseUse.Location = New-Object System.Drawing.Point(8, 4); $btnBrowseUse.Size = New-Object System.Drawing.Size(110, 30)
    $btnBrowseUse.FlatStyle = "Flat"; $btnBrowseUse.BackColor = $t.MedBg; $btnBrowseUse.ForeColor = $t.Text; $btnBrowseUse.Tag = "browse"
    $btnBrowseUse.Add_Click({ & $Script:BrowseActivate $false })
    $pnlBrowseActions.Controls.Add($btnBrowseUse)

    $btnBrowseAdd = New-Object System.Windows.Forms.Button
    $btnBrowseAdd.Text = "Add to list"; $btnBrowseAdd.Font = $FontNormal
    $btnBrowseAdd.Location = New-Object System.Drawing.Point(124, 4); $btnBrowseAdd.Size = New-Object System.Drawing.Size(110, 30)
    $btnBrowseAdd.FlatStyle = "Flat"; $btnBrowseAdd.BackColor = $t.MedBg; $btnBrowseAdd.ForeColor = $t.Text; $btnBrowseAdd.Tag = "browse"
    $btnBrowseAdd.Add_Click({ & $Script:BrowseActivate $true })
    $pnlBrowseActions.Controls.Add($btnBrowseAdd)

    # Red, and last, and separated from the two harmless ones by the gap. It
    # deletes documents and desktops; it should not sit flush against "Use".
    $btnBrowseDelete = New-Object System.Windows.Forms.Button
    $btnBrowseDelete.Text = "Delete profile..."; $btnBrowseDelete.Font = $FontNormal
    $btnBrowseDelete.Location = New-Object System.Drawing.Point(256, 4); $btnBrowseDelete.Size = New-Object System.Drawing.Size(130, 30)
    $btnBrowseDelete.FlatStyle = "Flat"; $btnBrowseDelete.BackColor = $t.MedBg; $btnBrowseDelete.ForeColor = $t.Error; $btnBrowseDelete.Tag = "browse"
    $btnBrowseDelete.Add_Click({ & $Script:BrowseDeleteProfile })
    $pnlBrowseActions.Controls.Add($btnBrowseDelete)

    function Update-BrowseActions {
        # Enabled state in one place, so the buttons and the context menu cannot
        # disagree about whether there is anything to act on.
        try {
            $has   = ($lvBrowse.SelectedItems.Count -gt 0)
            $users = ($Script:BrowseMode -eq "Users")
            $btnBrowseUse.Text       = if ($users) { "Select profile" } else { "Select store" }
            $btnBrowseUse.Enabled    = $has
            $btnBrowseAdd.Visible    = $users
            $btnBrowseAdd.Enabled    = $has -and $users
            $btnBrowseDelete.Visible = $users
            $btnBrowseDelete.Enabled = $has -and $users
        } catch { }
    }

    $lvBrowse = New-Object System.Windows.Forms.ListView
    $lvBrowse.View = "Details"; $lvBrowse.FullRowSelect = $true; $lvBrowse.MultiSelect = $false
    $lvBrowse.HideSelection = $false; $lvBrowse.HeaderStyle = "Nonclickable"
    $lvBrowse.Dock = "Fill"
    $lvBrowse.Font = $FontNormal; $lvBrowse.BackColor = $t.MedBg; $lvBrowse.ForeColor = $t.Text
    $lvBrowse.BorderStyle = "None"
    $lvBrowse.Add_SelectedIndexChanged({ Update-BrowseActions })
    $grpBrowse.Controls.Add($lvBrowse)
    $lvBrowse.BringToFront()

    # $grpOutput stays on the form until Update-Layout, so it gets scaled.
    $txtOutput.Dock = "Fill"
    # The backdrop behind the output log and the lookup list.
    #
    # A RichTextBox and a ListView are opaque, and WinForms gives no supported
    # way to make them otherwise, so the art cannot appear UNDER the text. The
    # see-through route was built and measured before being abandoned: a
    # WS_EX_TRANSPARENT RichTextBox took 1387 ms to append 300 lines against
    # 489 ms opaque, on the one control that tells anybody what a migration did.
    #
    # So the log is joined to the picture from both sides instead. The group
    # paints the real artwork and its padding leaves a wide enough margin to see
    # it, and the log itself takes its background colour FROM that artwork via
    # Get-OverlayTint - so the two meet in the same family of colour rather than
    # the log reading as a grey hole punched in the backdrop.
    $grpOutput.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 14)
    $grpBrowse.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 14)
    Add-OverlayPaint $grpOutput "panel"
    Add-OverlayPaint $grpBrowse "panel"

    # ...and every other panel, at the same quiet level. A group box paints its
    # own background and its labels do not, so the artwork shows behind the
    # fields exactly as it does behind the title - just far fainter, because
    # unlike the banner these carry small text that has to stay legible. The
    # levels are in $Script:SurfaceQuiet in UTW-Themes.ps1.
    foreach ($gp in @($grpTools, $grpOperation, $grpDetails, $grpOptions, $grpExpert, $grpActions, $grpPlan, $grpStatus)) {
        if ($gp) { Add-OverlayPaint $gp "panel" }
    }
    # ---- The three zones, and what starts in each ----
    [void](New-Zone "Left"        $split.Panel1)
    [void](New-Zone "RightTop"    $splitRight.Panel1)
    [void](New-Zone "RightBottom" $splitRight.Panel2)

    # Design heights are the group heights the layout above was written at.
    # Order is 10, 20, 30... so a panel can be slotted between two others
    # without renumbering the rest.
    Register-Panel -Key "Header"    -Title "Header"                   -Ctl $pnlHeader    -Zone "Left"        -Order 10 -DesignHeight 70
    Register-Panel -Key "Tools"     -Title "USMT Location"            -Ctl $grpTools     -Zone "Left"        -Order 20 -DesignHeight 75
    Register-Panel -Key "Operation" -Title "Operation"                -Ctl $grpOperation -Zone "Left"        -Order 30 -DesignHeight 100
    Register-Panel -Key "Details"   -Title "Migration Details"        -Ctl $grpDetails   -Zone "Left"        -Order 40 -DesignHeight 170
    Register-Panel -Key "Options"   -Title "Options"                  -Ctl $grpOptions   -Zone "Left"        -Order 50 -DesignHeight 156
    Register-Panel -Key "Expert"    -Title "Expert"                   -Ctl $grpExpert    -Zone "Left"        -Order 60 -DesignHeight 384
    Register-Panel -Key "Actions"   -Title "Actions"                  -Ctl $grpActions   -Zone "Left"        -Order 70 -DesignHeight 68
    # The only FILL panel in the left column, so it takes the space that used
    # to sit empty between Actions and the status bar.
    Register-Panel -Key "Plan"      -Title "Summary"                  -Ctl $grpPlan      -Zone "Left"        -Order 80 -Fill
    Register-Panel -Key "Lookup"    -Title "Lookup"                   -Ctl $grpBrowse    -Zone "RightTop"    -Order 10 -Fill
    Register-Panel -Key "Output"    -Title "Output log"               -Ctl $grpOutput    -Zone "RightBottom" -Order 10 -Fill
    # Expert starts hidden; the mode toggle turns it on.
    ($Script:Panels | Where-Object { $_.Key -eq "Expert" }).Shown = $false

    # ---- Which controls follow a panel's width ----
    # DX = share of the extra width that MOVES the control, DW = share that
    # WIDENS it. A two-column row gives each column half of both, which is what
    # keeps the halves equal at any width.
    Add-Stretch $pnlAccent      $pnlHeader    -DW 1
    Add-Stretch $lblAdminWarn   $pnlHeader    -DX 1
    Add-Stretch $lblMode        $pnlHeader    -DX 1
    Add-Stretch $chkExpertMode  $pnlHeader    -DX 1

    Add-Stretch $txtUSMTPath    $grpTools     -DW 1
    Add-Stretch $btnBrowseUSMT  $grpTools     -DX 1
    Add-Stretch $lblUSMTStatus  $grpTools     -DW 1

    Add-Stretch $cmbAction      $grpOperation -DW 0.5
    Add-Stretch $lblScope       $grpOperation -DX 0.5
    Add-Stretch $cmbScope       $grpOperation -DX 0.5 -DW 0.5
    Add-Stretch $cmbSaveTo      $grpOperation -DW 0.5
    Add-Stretch $lblSaveToHint  $grpOperation -DX 0.5 -DW 0.5

    Add-Stretch $lblOptChecks     $grpOptions -DX 0.5
    Add-Stretch $pnlOptRule       $grpOptions -DX 0.5
    Add-Stretch $chkVerifyProfile $grpOptions -DX 0.5
    Add-Stretch $chkCheckDisk     $grpOptions -DX 0.5
    Add-Stretch $chkCheckInactive $grpOptions -DX 0.5
    Add-Stretch $chkEstimateSize  $grpOptions -DX 0.5

    Add-Stretch $lblExpertHint   $grpExpert -DW 1
    Add-Stretch $txtCommand      $grpExpert -DW 1
    Add-Stretch $lblExpertState  $grpExpert -DW 1
    Add-Stretch $btnCmdRevert    $grpExpert -DX 1
    Add-Stretch $btnCmdCopy      $grpExpert -DX 1
    Add-Stretch $btnCmdPaste     $grpExpert -DX 1
    Add-Stretch $lblArchHint     $grpExpert -DW 1
    Add-Stretch $pnlDangerRule   $grpExpert -DW 1

    Add-Stretch $btnRun      $grpActions -DW 1
    Add-Stretch $btnStop     $grpActions -DX 1
    Add-Stretch $btnOpenLogs $grpActions -DX 1

    # Status bar along the bottom of the whole window, menu along the top.
    $Form.Controls.Remove($grpStatus)
    $grpStatus.Dock = "Bottom"
    $Form.Controls.Add($split)
    $Form.Controls.Add($grpStatus)
    $Form.Controls.Add($menu)
    # Docking order decides who gets the edge first: menu on top, status at the
    # bottom, and the splitter takes what is left.
    $menu.Dock = "Top"
    $split.BringToFront()

    # Inside the status bar the fixed-pixel children now need to follow its
    # width, since it is docked and no longer 625 wide.
    $lblStatus.Anchor   = $anchLR
    $progressBar.Anchor = $anchLR
    $lblLogPath.Anchor  = $anchLR
    $lblProgress.Anchor = $anchTR

    # ---- 1. Client area ----
    # CLIENT, not Form.Height. The old code set the outer height, which silently
    # handed the title bar and borders a slice of the layout - and that slice
    # grows with DPI (~39px at 100%, ~55px at 150%, ~64px at 175%).
    #
    # The menu and the status bar are DOCKED, so they take their height out of
    # the client area before the split gets any. Both have to be added on or the
    # bottom of the setup column is clipped by exactly their combined height -
    # which is what the menu bar did the moment it was introduced.
    $menuH   = if ($menu.Height -gt 0) { $menu.Height } else { 24 }
    $statusH = $grpStatus.Height
    # The window no longer has to be tall enough for the entire setup column -
    # that column scrolls now. Demanding the full height forced Get-FittedScale
    # to shrink the whole UI on any ordinary screen just to fit a stack of
    # panels most of which are below the fold anyway. 760 design px shows the
    # operation and details comfortably; the rest is a scroll away.
    $naturalH = $yPos + 16 + $menuH + $statusH
    $openH    = [Math]::Min($naturalH, (760 + $menuH + $statusH))
    $Form.ClientSize = New-Object System.Drawing.Size(1180, $openH)

    # ---- 2. Deferred anchors ----
    # NOT $txtOutput and NOT $grpStatus. Both are DOCKED now, and in WinForms
    # setting Anchor silently resets Dock to None - so these two lines undid the
    # docking a few lines above them. The log snapped back to its 602x175 design
    # size inside a much larger group ("a small square in the box") and the
    # status bar snapped back to its old absolute position, leaving a band of
    # empty form below it. Dock and Anchor are mutually exclusive; pick one.
    #
    # The children INSIDE the docked status bar still need anchors, and those
    # are set where the split is assembled.

    # ---- 3. Scale the finished layout to the display ----
    # MinimumSize is cleared first because Form.Scale() scales that too.
    $Form.MinimumSize = [System.Drawing.Size]::Empty
    $Script:UIScale   = Get-FittedScale -Form $Form -Desired $Script:UIScale
    Set-FormScale -Form $Form -Factor $Script:UIScale
    # From here on the tree is no longer in design pixels. Anything that places
    # a control at runtime has to go through Set-DesignBounds.
    $Script:LayoutScale = $Script:UIScale

    # ORDER IS LOAD-BEARING. Every panel is still at its design width right now,
    # standing alone and not yet docked into a zone, which is the only moment at
    # which "how wide was this control meant to be" can be read off the controls
    # themselves. Record it, THEN dock everything, THEN let Update-Stretch work
    # out the difference. Recording afterwards would capture whatever width the
    # first zone happened to hand out and treat that as the design.
    Save-StretchBase
    Update-Layout

    # The divider goes just right of the setup column, so the left side shows
    # everything at its natural width and the log takes the rest.
    $Script:SetupColumnWidth = [int](($Script:SetupDesignWidth + 17) * $Script:UIScale)
    Set-SplitterLayout

    # ---- 4. Stored sizes for the Output toggle, from the scaled form ----
    $wa = (Get-TargetScreen).WorkingArea
    $Script:OutputMinHeight     = [int](70 * $Script:UIScale)
    $Script:DefaultFormWidth    = [Math]::Min($Form.Width,  $wa.Width)
    $Script:ExpandedFormHeight  = [Math]::Min($Form.Height, $wa.Height)
    $Script:MinFormHeight       = [int](520 * $Script:UIScale)

    # ---- 5. Watch for the display changing under a window already built ----
    #
    # POLLED, NOT EVENT-DRIVEN, and that is deliberate. WM_DPICHANGED only
    # arrives for a per-monitor-aware process, so it is silent on the older
    # Windows this still has to run on, and DisplaySettingsChanged does not fire
    # reliably when an RDP session is reconnected from a different client - which
    # is the exact case that started this. One API call every two seconds costs
    # nothing measurable and catches all of them, including the ones nobody has
    # thought of yet.
    $Script:LastSeenDpi = Get-DisplayDpi $Form
    $Script:DpiWatch = New-Object System.Windows.Forms.Timer
    $Script:DpiWatch.Interval = 2000
    $Script:DpiWatch.Add_Tick({
        if ($env:UTW_LAYOUT_SELFTEST) { return }
        try {
            $now = Get-DisplayDpi $Form
            if ($now -le 0 -or [Math]::Abs($now - $Script:LastSeenDpi) -lt 1) { return }
            $Script:LastSeenDpi = $now
            # Minimised windows report the monitor they were last on and have no
            # useful work area; wait until it is back on screen.
            if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }

            $want = Get-TargetUiScale $now
            if ([Math]::Abs($want - $Script:LayoutScale) -lt 0.02) { return }
            if (Invoke-DisplayRescale -Form $Form -NewScale $want) {
                Append-Output "Display changed to $([int]$now) DPI - the window has been resized to match." $Script:T.TextDim
            }
        } catch { Write-CrashLog "DPI watch failed: $($_.Exception.Message)" }
    })
    $Script:DpiWatch.Start()

    # ---- Mirror the progress bar onto the taskbar button ----
    #
    # MIRRORED, NOT DRIVEN. The bar is set inline in a dozen places along the
    # migration path, and threading a taskbar call through all of them would put
    # twelve new edits into the code that actually runs a migration - for a
    # cosmetic feature. Watching the control instead costs one comparison every
    # half second and cannot affect the run at all.
    #
    # The COM call only happens when something changed, so an idle window makes
    # no calls whatsoever.
    $Script:LastTaskbarPct   = -1
    $Script:LastTaskbarStyle = ""
    $Script:TaskbarMirror = New-Object System.Windows.Forms.Timer
    $Script:TaskbarMirror.Interval = 500
    $Script:TaskbarMirror.Add_Tick({
        if ($env:UTW_LAYOUT_SELFTEST -or -not $Script:NativeHelpers) { return }
        try {
            if (-not $Form.IsHandleCreated) { return }
            $style = "$($progressBar.Style)"
            $pct   = [int]$progressBar.Value
            if ($pct -eq $Script:LastTaskbarPct -and $style -eq $Script:LastTaskbarStyle) { return }
            $Script:LastTaskbarPct = $pct; $Script:LastTaskbarStyle = $style
            if ($style -eq "Marquee") {
                [TaskbarProgress]::SetState($Form.Handle, 1)      # indeterminate
            } elseif ($pct -le 0 -or $pct -ge 100) {
                [TaskbarProgress]::SetState($Form.Handle, 0)      # clear it
            } else {
                [TaskbarProgress]::SetValue($Form.Handle, $pct)
            }
        } catch { }
    })
    $Script:TaskbarMirror.Start()
    $Form.Add_FormClosed({
        try { [TaskbarProgress]::SetState($Form.Handle, 0) } catch { }
        try { $Script:TaskbarMirror.Stop(); $Script:TaskbarMirror.Dispose() } catch { }
    })
    # Nothing is listed yet, so the action buttons start disabled rather than
    # live-looking with no row to act on.
    Update-BrowseActions
    $Form.Add_FormClosed({ try { $Script:DpiWatch.Stop(); $Script:DpiWatch.Dispose() } catch { } })

    # MinimumSize is the COLLAPSED height plus a readable slice of the output
    # box, never the full layout height. The old code locked it to the full
    # height so the form could "grow but not shrink" - on a screen shorter than
    # the layout that made the bottom of the window permanently unreachable.
    Set-FormMinimumSize -Form $Form

    # ---- 5. Fit and position within the work area ----
    $Form.Width  = $Script:DefaultFormWidth
    $Form.Height = $Script:ExpandedFormHeight
    Set-FormWithinWorkArea -Form $Form

    # Again, now that the form is at its FINAL size. The first call runs while
    # the window is still mid-resize, so the divider was being clamped against
    # a width the window no longer has - and with FixedPanel=Panel1 that clamped
    # value would then have been kept for good.
    Set-SplitterLayout

    # Everything is in place, so this is the moment to switch on double
    # buffering across the whole tree - before the window is ever painted.
    Set-DoubleBuffered -Control $Form

    # Late enough that every field has the height its font actually gives it.
    try { Set-FieldButtonFit } catch { Write-CrashLog "Field button fit: $($_.Exception.Message)" }

    Write-CrashLog "Boot: layout finalised at $($Script:BootClock.ElapsedMilliseconds) ms"
    Write-CrashLog "Layout: scale=$($Script:UIScale) form=$($Form.Width)x$($Form.Height) client=$($Form.ClientSize.Width)x$($Form.ClientSize.Height) split=$($split.SplitterDistance)/$($split.Width)"

    # ---- 6. Re-fit whenever the display changes underneath us ----
    # Switching a monitor from 150% to 175% while the tool is open leaves a
    # system-DPI-aware window stretched by Windows to ~117% of its old size,
    # against a work area that just got smaller - so the bottom of the window
    # (output panel, progress bar, status) ends up under the taskbar or off
    # screen entirely. Polling the work area is deliberate: SystemEvents fires
    # on its own thread, and marshalling scriptblocks back onto the UI thread
    # from a PowerShell host is a good way to earn an intermittent crash.
    # The horizontal divider is a fraction of the height, so it has to be
    # recomputed when the window changes size - otherwise maximising leaves the
    # list at its old few pixels while the log takes everything.
    $Form.Add_ResizeEnd({ try { Update-SplitterFit } catch { }; Exit-DragMode })
    $Form.Add_SizeChanged({
        # Maximise and restore do not raise ResizeEnd.
        if ($Form.WindowState -ne $Script:LastWindowState) {
            $Script:LastWindowState = $Form.WindowState
            try { Update-SplitterFit; Update-StretchNow } catch { }
        }
    })
    $Script:LastWindowState = $Form.WindowState
    # Dragging the divider changes a panel's width without changing the form's,
    # so the contents have to be re-fitted from here as well.
    #
    # SplitterMoving fires on every mouse move during the drag and SplitterMoved
    # once at the end. The flag tells Update-Stretch which it is in: during the
    # drag it does geometry only, and the one expensive pass happens once, when
    # the divider is let go.
    $split.Add_SplitterMoving({ Enter-DragMode })
    $splitRight.Add_SplitterMoving({ Enter-DragMode })
    $split.Add_SplitterMoved({ Exit-DragMode })
    $splitRight.Add_SplitterMoved({ Exit-DragMode })
    # A window resize is the same story: many frames, then one settled size.
    $Form.Add_ResizeBegin({ Enter-DragMode })
    # Whether the backdrop is worth animating. Deactivate fires for a lock
    # screen, another virtual desktop and any other window taking focus; on the
    # way back the surfaces are repainted once so the picture is current rather
    # than however many frames stale.
    $Script:WindowActive = $true
    $Form.Add_Deactivate({ $Script:WindowActive = $false })
    $Form.Add_Activated({
        $Script:WindowActive = $true
        if ($Script:OverlayEnabled) {
            foreach ($c in $Script:OverlaySurfaces) { if ($c) { try { $c.Invalidate($true) } catch { } } }
        }
    })

    # One line recording what the docked controls actually became. Docking
    # failures are invisible in the source - setting Anchor after Dock silently
    # cancels the Dock - so the finished geometry is written down where both a
    # support call and the startup test can read it.
    $Form.Add_Shown({
        try {
            # Settle first. Resizes are coalesced onto a 16 ms timer now, so the
            # last scroll bar to appear during the first layout may not have
            # been answered yet when this runs - and the diagnostic would report
            # a mid-flight state, which is worse than no diagnostic at all.
            Update-StretchNow
            [System.Windows.Forms.Application]::DoEvents()
            Update-StretchNow
            # The group's own padding goes into the line so the test can assert
            # the log fills the space EXACTLY rather than guessing a tolerance.
            # A fixed 40px of slack could not tell "Dock was cancelled by a
            # later Anchor" - the fault this exists to catch - apart from "the
            # artwork frame around the log was widened on purpose".
            Write-CrashLog ("Docked: out={0}x{1} in grp {2}x{3} dock={4} | status dock={5} h={6} | split={7}/{8} right={9}/{10} | pad={11}x{12}" -f `
                $txtOutput.Width, $txtOutput.Height, $grpOutput.Width, $grpOutput.Height, $txtOutput.Dock,
                $grpStatus.Dock, $grpStatus.Height,
                $split.SplitterDistance, $split.Width,
                $splitRight.SplitterDistance, $splitRight.Height,
                $grpOutput.Padding.Horizontal, $grpOutput.Padding.Vertical)
            # The left column's real geometry, for the same reason. A group box
            # that has been stretched by a bad anchor margin looks identical in
            # the source and parks its right-anchored buttons off-screen; the
            # only way to see it is to write down what the group actually
            # became. "browse" is the right edge of the USMT Browse button,
            # which must land inside the group that owns it.
            # The zone child counts and the panel's actual PARENT are in here
            # because "the group is the wrong width" has two completely
            # different causes - a bad anchor, or the panel never having been
            # moved into its zone at all - and the width alone cannot tell them
            # apart.
            Write-CrashLog ("Left: panel={0} grpTools={1} browse={2} grpDetails={3} actions={4} run={5} zones={6}/{7}/{8} toolsIn={9}" -f `
                $Script:Zones["Left"].ClientSize.Width, $grpTools.Width, $btnBrowseUSMT.Right,
                $grpDetails.Width, $grpActions.Width, $btnRun.Width,
                $Script:Zones["Left"].Controls.Count, $Script:Zones["RightTop"].Controls.Count,
                $Script:Zones["RightBottom"].Controls.Count,
                $(if ($grpTools.Parent) { $grpTools.Parent.GetType().Name } else { "none" }))
            # The Expert panel, which is hidden at startup but already laid out.
            # Its controls were reordered by hand in design pixels, so what
            # matters is that the reading order survived scaling: command box,
            # then the ordinary settings, then the red block, all inside the
            # group. A hidden control still reports its bounds.
            Write-CrashLog ("Expert: grp={0}x{1} cmd={2},{3}+{4}x{5} paste={6} arch={7} logexit={8} rule={9} danger={10} del={11}" -f `
                $grpExpert.Width, $grpExpert.Height,
                $txtCommand.Left, $txtCommand.Top, $txtCommand.Width, $txtCommand.Height,
                $btnCmdPaste.Right, $cmbArch.Top, $chkLogOnExit.Top,
                $pnlDangerRule.Top, $lblDangerSection.Top, $chkDeleteSource.Bottom)
            # THE FILL PANEL'S HEIGHT, with the Expert box taking its space.
            #
            # Dock=Fill takes what the Top-docked panels leave, and when they add
            # up to more than the zone that is nothing at all - the summary went
            # to height 0 and simply was not there, with no way to scroll to a
            # control that occupies no space. Reported as "with expert mode on
            # the summary box disappears and there's no way to get to it".
            # Buttons that stand beside a field. This one has been got wrong
            # three times - too tall, off the row, outside its panel - and none
            # of it shows in the source, so the numbers go in the log.
            Write-CrashLog ("SelfBtn usmt: btn={0},{1}+{2}x{3} fld={4},{5}+{6}x{7} panel={8}" -f `
                $btnBrowseUSMT.Left, $btnBrowseUSMT.Top, $btnBrowseUSMT.Width, $btnBrowseUSMT.Height,
                $txtUSMTPath.Left, $txtUSMTPath.Top, $txtUSMTPath.Width, $txtUSMTPath.Height,
                $grpTools.Width)
            Write-CrashLog ("SelfBtn list: users={0}+{1}x{2} stores={3}+{4}x{5}" -f `
                $btnListUsers.Left, $btnListUsers.Width, $btnListUsers.Height,
                $btnListStores.Left, $btnListStores.Width, $btnListStores.Height)
            foreach ($fp in @($Script:Panels | Where-Object { $_.Fill -and $_.Shown -and $_.Ctl })) {
                Write-CrashLog ("SelfFill {0}: zone={1} h={2} minH={3} visible={4}" -f `
                    $fp.Key, $fp.Zone, $fp.Ctl.Height, $fp.Ctl.MinimumSize.Height, $fp.Ctl.Visible)
            }
        } catch { }
    })

    function Invoke-LayoutSelfTest {
        <#
            Drives the resizable layout and writes down what it became at each
            step, then closes the window. Runs only when UTW_LAYOUT_SELFTEST is
            set in the environment, so it costs a shipping user nothing.

            It exists because the interesting failures here are all "the panel
            resized but its contents did not", and that is invisible in the
            source and unreachable from a test harness - the layout functions
            live inside this one enormous function and cannot be lifted out.
            Making the app measure itself is the only honest way to check it.
        #>
        $step = {
            param([string]$Name)
            [System.Windows.Forms.Application]::DoEvents()
            $z = $Script:Zones["Left"]
            Write-CrashLog ("SelfTest {0}: zone={1} tools={2} browseR={3} run={4} runR={5} srcR={6} arrowX={7} dstX={8} dstR={9} cmdR={10} leftN={11} rtN={12}" -f `
                $Name, $z.ClientSize.Width, $grpTools.Width, $btnBrowseUSMT.Right,
                $btnRun.Width, $btnRun.Right, $txtSourcePC.Right, $lblRouteArrow.Left,
                $txtNewPC.Left, $txtNewPC.Right, $txtCommand.Right,
                @($Script:Panels | Where-Object { $_.Zone -eq "Left" -and $_.Shown }).Count,
                @($Script:Panels | Where-Object { $_.Zone -eq "RightTop" -and $_.Shown }).Count)
        }
        try {
            # Expert mode ON for the whole run: it is the heavier layout, and
            # the checks on the command box mean nothing without it on screen.
            $rbExpert.Checked = $true
            # From the SHIPPED layout, not from whatever was saved last time -
            # otherwise the "make it wider" step can start from a column that is
            # already wider than the target and the run proves nothing.
            Reset-PanelLayout
            # A capture with both machines in play, so the paired row is live.
            $cmbAction.SelectedIndex = 2      # Export + Import
            $cmbScope.SelectedIndex  = 0      # Single Profile
            Update-Fields

            # UTW_SELFTEST_RESCALE=1.5 builds the window at whatever scale this
            # run started at and then moves it to 1.5, standing in for an RDP
            # session reconnecting from a different display.
            #
            # It happens HERE, before anything is measured, so the numbers that
            # follow can be compared directly against a run that started at 1.5
            # in the first place. That comparison is the whole point: a window
            # that has been rescaled has to end up where a window that was built
            # that way would be, and nothing short of measuring both says so.
            # ---- The lookup list, actually filled ----
            #
            # THE HOLE THREE BUGS CAME THROUGH. Nothing in the suite ever called
            # Show-BrowseUsers, because it needs a machine to enumerate - so the
            # list could be built wrong and every test still passed. It has
            # happened three times: five columns collapsed into one by a stray
            # leading comma, a path bug that made two machines look like one
            # folder, and blocked rows landing a column out.
            #
            # This machine is a machine. Enumerating it proves the headers and
            # the cells agree, whatever the chosen column set.
            try {
                Show-BrowseUsers
                [System.Windows.Forms.Application]::DoEvents()
                $hdrs = $lvBrowse.Columns.Count
                $rows = $lvBrowse.Items.Count
                $bad  = 0
                foreach ($it in $lvBrowse.Items) {
                    # SubItems includes the item's own text, so it should equal
                    # the column count exactly.
                    if ($it.SubItems.Count -ne $hdrs) { $bad++ }
                }
                Write-CrashLog ("SelfBrowse: cols={0} rows={1} misaligned={2} first={3}" -f `
                    $hdrs, $rows, $bad,
                    $(if ($lvBrowse.Columns.Count) { $lvBrowse.Columns[0].Text } else { "none" }))
            } catch {
                Write-CrashLog "SelfBrowse: FAILED - $($_.Exception.Message)"
            }

            # UTW_SELFTEST_STACKED=1 flips the window into the narrow-screen
            # layout before anything is measured. What has to be true afterwards
            # is that the left zone now has the WHOLE width and that no panel
            # hangs off the edge of it - the failure this layout is prone to is
            # a container that resized while its contents did not.
            if ($env:UTW_SELFTEST_STACKED) {
                Set-StackedLayout $true
                [System.Windows.Forms.Application]::DoEvents()
                # "roundtrip" turns it back off again. Everything measured after
                # this must match an ordinary run exactly - going stacked and
                # back is a thing somebody will do, and a layout that does not
                # come home is worse than one that never left.
                if ($env:UTW_SELFTEST_STACKED -eq "roundtrip") {
                    Set-StackedLayout $false
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $zl = $Script:Zones["Left"]
                $over = 0
                foreach ($pd in @($Script:Panels | Where-Object { $_.Shown -and $_.Ctl })) {
                    $r = $pd.Ctl.Right
                    if ($pd.Ctl.Parent -and $r -gt $pd.Ctl.Parent.ClientSize.Width) {
                        $over = [Math]::Max($over, $r - $pd.Ctl.Parent.ClientSize.Width)
                    }
                }
                Write-CrashLog ("SelfTest stacked: orient={0} splitW={1} splitH={2} dist={3} zoneW={4} overhang={5}" -f `
                    $split.Orientation, $split.Width, $split.Height, $split.SplitterDistance, $zl.ClientSize.Width, $over)
            }

            if ($env:UTW_SELFTEST_RESCALE) {
                $target = 0.0
                if ([double]::TryParse($env:UTW_SELFTEST_RESCALE, [ref]$target) -and $target -gt 0) {
                    $okRescale = Invoke-DisplayRescale -Form $Form -NewScale $target
                    Write-CrashLog "SelfTest rescale: to=$target applied=$okRescale now=$($Script:LayoutScale)"
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
            & $step "default"

            $split.SplitterDistance = [int]($split.Width * 0.75)
            Update-Stretch
            & $step "wide"

            $split.SplitterDistance = [Math]::Max($split.Panel1MinSize, [int]($split.Width * 0.30))
            Update-Stretch
            & $step "narrow"

            $Form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
            Update-SplitterFit; Update-Stretch
            & $step "maximised"

            $Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            Update-SplitterFit; Update-Stretch

            # Move a panel to another zone - the thing the layout editor does.
            $p = $Script:Panels | Where-Object { $_.Key -eq "Tools" } | Select-Object -First 1
            $p.Zone = "RightTop"; $p.Order = 5
            Update-Layout
            & $step "toolsright"

            Reset-PanelLayout
            & $step "reset"

            # How long ONE resize frame costs, at two window sizes. A drag fires
            # these faster than they can complete if they are slow, and the
            # backlog is what turns a smooth drag into a crawl a few seconds in -
            # so the number that matters is the per-frame cost, not the total.
            # Each PART of a resize frame, timed separately. "It is slow" is not
            # actionable; which of the four things a frame does is slow, is.
            $Script:Dragging = $true
            $split.SplitterDistance = [int]($split.Width * 0.5)
            [System.Windows.Forms.Application]::DoEvents()
            $N = 40
            $bench = {
                param([string]$Name, [scriptblock]$Work)
                [System.Windows.Forms.Application]::DoEvents()
                $sw = [Diagnostics.Stopwatch]::StartNew()
                for ($i = 0; $i -lt $N; $i++) { & $Work $i }
                $sw.Stop()
                Write-CrashLog ("SelfPerf {0,-10}: {1,7} ms per frame" -f `
                    $Name, [Math]::Round($sw.Elapsed.TotalMilliseconds / $N, 1))
            }
            & $bench "paint"      { $h = Suspend-Paint $Script:ZoneHosts["Left"]; Resume-Paint $h }
            & $bench "geometry"   { Update-DetailsGeometry }
            & $bench "stretchmap" {
                foreach ($e in $Script:StretchMap) {
                    if ($e.BaseC -le 0) { continue }
                    $d = $e.Container.ClientSize.Width - $e.BaseC
                    if ($d -lt 0) { $d = 0 }
                    if ($e.DX -ne 0) { $null = $e.BaseX + [int]($d * $e.DX) }
                    if ($e.DW -ne 0) { $null = $e.BaseW + [int]($d * $e.DW) }
                }
            }
            & $bench "invalidate" { $grpDetails.Invalidate($true); $grpTools.Invalidate($true) }
            # One whole frame of OUR work.
            & $bench "fullframe"  { Update-StretchNow }
            $Script:Dragging = $false
            & $bench "settled"    { Update-StretchNow }
            $Script:Dragging = $true

            # The left/right divider - the one that costs the most, because it
            # resizes the setup column.
            & $bench "splitLive"  { param($i) $split.SplitterDistance = $split.SplitterDistance + $(if ($i % 2) { 2 } else { -2 }) }
            # The same, with the setup column's layout frozen. The gap between
            # these two IS the cost of reflowing the column live, and the lower
            # figure is the floor: what the two nested SplitContainers cost on
            # their own, which nothing in this file can reduce.
            #
            # (Freezing the right-hand zones as well measured the same, and
            # freezing the output box and the lookup list changed nothing - the
            # setup column is the whole of the difference.)
            $Script:ZoneHosts["Left"].SuspendLayout()
            & $bench "splitNoLeft" { param($i) $split.SplitterDistance = $split.SplitterDistance + $(if ($i % 2) { 2 } else { -2 }) }
            $Script:ZoneHosts["Left"].ResumeLayout($true)

            # The vertical paths, timed separately - horizontal came out fast and
            # vertical did not, and they touch different controls.
            & $bench "vertSplit"  { param($i) $splitRight.SplitterDistance = $splitRight.SplitterDistance + $(if ($i % 2) { 2 } else { -2 }) }
            & $bench "formHeight" { param($i) $Form.Height = $Form.Height + $(if ($i % 2) { 2 } else { -2 }) }

            # ---- the same frame, with the themed backdrop ON ----
            # The overlay's whole design is "render once, blit thereafter". If
            # that is ever broken - a painter called per paint instead of per
            # size, or a cache key that never hits - it shows up here as a
            # resize frame that suddenly costs what 250 shapes cost to draw.
            Set-OverlayEnabled $true
            # ONE THING AT A TIME. These benches ask "what does the backdrop cost
            # on a resize frame"; the animation has its own bench further down.
            # Since motion became the default, the drift timer was repainting
            # thirteen surfaces underneath these measurements and they turned
            # noisy enough to fail on a busy machine - not because the backdrop
            # was slow, but because two things were being measured as one.
            $wasAnim = $Script:OverlayAnimate
            Set-OverlayAnimate $false
            [System.Windows.Forms.Application]::DoEvents()
            # Two faults that were reported from the running window and that
            # nothing could have caught from the source:
            #   "turning graphics on only showed them in the title bar" - the
            #     toggle invalidated four hand-listed controls and not the
            #     panels, so they kept whatever they had already painted.
            #   "every theme has these boxes around the text" - captions fill
            #     themselves with the parent's COLOUR rather than inheriting its
            #     paint, so each one sat in its own opaque rectangle.
            $tl = 0; $op = 0
            $countLabels = {
                param($c)
                foreach ($ch in $c.Controls) {
                    if ($ch -is [System.Windows.Forms.Label] -or $ch -is [System.Windows.Forms.CheckBox]) {
                        if ($ch.BackColor.A -eq 0) { $script:tlCount++ }
                        # A caption painted the artwork's own colour rather than
                        # inheriting the panel's - the cheap way to have no box.
                        elseif ($ch.BackColor -ne $ch.Parent.BackColor) { $script:tintCount++ }
                    }
                    & $countLabels $ch
                }
            }
            $script:tlCount = 0; $script:tintCount = 0
            & $countLabels $Form
            $tl = $script:tlCount
            $op = @($Script:OverlaySurfaces | Where-Object { $_ -and "$($_.Tag)" -like "overlay-*" }).Count
            Write-CrashLog ("SelfOverlay: surfaces={0} transparentCaptions={1} tintedCaptions={2}" -f $op, $tl, $script:tintCount)
            & $bench "overlaySplit" { param($i) $split.SplitterDistance = $split.SplitterDistance + $(if ($i % 2) { 2 } else { -2 }) }
            & $bench "overlayFrame" { Update-StretchNow }
            # The honest worst case: a new surface size on every frame, which is
            # what a real drag asks for. Without the mid-drag guard this is a
            # full re-render per frame.
            #
            # Dragging must actually be SET for this to measure the guard. It was
            # left false, so this quietly benchmarked a cold render instead and
            # only passed while the artwork was cheap enough not to notice - then
            # failed at 59 ms the moment the painters got richer, blaming a guard
            # it was never exercising.
            $Script:Dragging = $true
            & $bench "overlayPaint" { param($i)
                $null = Get-OverlayBitmap -Surface "header" -Width (700 + $i) -Height 105 -ThemeName $Script:CurrentThemeName }
            $Script:Dragging = $false
            # The render itself, which happens once per size rather than per frame.
            # ---- the cost of ANIMATING ----
            # One tick is: bump a counter, invalidate the surfaces, and let each
            # of them blit a ground bitmap plus the motion layer twice. Nothing
            # is re-rendered. Measured on Clown Fiesta, the heaviest painter,
            # because that is the one anybody will actually run it on.
            $wasTheme2 = $Script:CurrentThemeName
            Set-ActiveTheme "Clown Fiesta"; $Script:CurrentThemeName = "Clown Fiesta"
            Set-OverlayAnimate $true      # back on: this is the bench that wants it
            $Script:Dragging = $false
            [System.Windows.Forms.Application]::DoEvents()
            # The paint itself, forced synchronously on the one surface that
            # moves. Refresh() rather than Invalidate()+DoEvents: DoEvents runs
            # everything else that is queued as well, which is why the first
            # version of this measured 200 ms and told us nothing about the
            # animation at all.
            Write-CrashLog "BC5 before animPaint bench"
            & $bench "animPaint" {
                $Script:OverlayPhase += 2
                $pnlHeader.Refresh()
            }
            # A resize frame WHILE it is animating - the case the timer stands
            # down for.
            $Script:Dragging = $true
            & $bench "animSplit" { param($i) $split.SplitterDistance = $split.SplitterDistance + $(if ($i % 2) { 2 } else { -2 }) }
            $Script:Dragging = $false
            Set-OverlayAnimate $false
            Set-ActiveTheme $wasTheme2; $Script:CurrentThemeName = $wasTheme2
            Clear-OverlayCache
            $swR = [Diagnostics.Stopwatch]::StartNew()
            $null = Get-OverlayBitmap -Surface "header" -Width 900 -Height 105 -ThemeName $Script:CurrentThemeName
            $null = Get-OverlayBitmap -Surface "zone"   -Width 900 -Height 900 -ThemeName $Script:CurrentThemeName
            $swR.Stop()
            Write-CrashLog ("SelfPerf overlayRender: {0} ms (once per size, not per frame)" -f [int]$swR.Elapsed.TotalMilliseconds)
            # And the heaviest painter in the tool, on its own.
            $wasTheme = $Script:CurrentThemeName
            Set-ActiveTheme "Clown Fiesta"; $Script:CurrentThemeName = "Clown Fiesta"
            Clear-OverlayCache
            $swC = [Diagnostics.Stopwatch]::StartNew()
            $null = Get-OverlayBitmap -Surface "header" -Width 900 -Height 105 -ThemeName "Clown Fiesta"
            $swC.Stop()
            Write-CrashLog ("SelfPerf clownRender  : {0} ms (once per size)" -f [int]$swC.Elapsed.TotalMilliseconds)
            Set-ActiveTheme $wasTheme; $Script:CurrentThemeName = $wasTheme
            Set-OverlayAnimate $wasAnim   # leave it as the user had it
            Set-OverlayEnabled $false
            $Script:Dragging = $false

            # ---- which fields does each operation actually show? ----
            # "The source computer field is gone for Export + Import" is a
            # question about visibility, and visibility is decided across two
            # functions now. Asking the running window is the only answer that
            # cannot be wrong.
            foreach ($combo in @(@(0,0,"Export/Single"), @(1,0,"Import/Single"),
                                 @(2,0,"Export+Import/Single"), @(2,2,"Export+Import/Settings"),
                                 @(3,0,"Extract"), @(4,0,"CleanUp"), @(5,0,"CompareSync"))) {
                $cmbAction.SelectedIndex = $combo[0]
                $cmbScope.SelectedIndex  = $combo[1]
                Update-Fields
                [System.Windows.Forms.Application]::DoEvents()
                $on = @()
                foreach ($f in @(@("srcLbl",$lblSourcePC), @("srcBox",$txtSourcePC), @("srcFind",$btnFindSrc),
                                 @("dstLbl",$lblNewPC),    @("dstBox",$txtNewPC),    @("dstFind",$btnFindDst),
                                 @("user",$txtUsername),   @("pick",$btnPickUser),
                                 @("store",$txtImportStore), @("usb",$txtUSBPath), @("unc",$txtCentralPath),
                                 @("mig",$txtMigrationFile), @("extract",$txtExtractPath))) {
                    if ($f[1].Visible) { $on += $f[0] }
                }
                Write-CrashLog ("SelfFields {0,-22}: {1}" -f $combo[2], ($on -join " "))
            }
            $cmbAction.SelectedIndex = 2; $cmbScope.SelectedIndex = 0; Update-Fields

            # ---- does anything clip at the narrowest the window can get? ----
            $wasW = $Form.Width; $wasH = $Form.Height
            $Form.Width = $Form.MinimumSize.Width
            [System.Windows.Forms.Application]::DoEvents()
            Update-StretchNow
            [System.Windows.Forms.Application]::DoEvents()
            $clipped = @()
            foreach ($pd in @($Script:Panels | Where-Object { $_.Shown -and $_.Ctl })) {
                $inner = $pd.Ctl.ClientSize.Width
                foreach ($ch in $pd.Ctl.Controls) {
                    if ($ch.Visible -and $ch.Right -gt ($inner + 2)) {
                        $clipped += "$($pd.Key)/$($ch.GetType().Name)@$($ch.Right)>$inner"
                    }
                }
            }
            Write-CrashLog ("SelfClip at minWidth {0}: zone={1} overflow={2} {3}" -f `
                $Form.Width, $Script:Zones["Left"].ClientSize.Width, $clipped.Count,
                (($clipped | Select-Object -First 6) -join " "))
            $Form.Width = $wasW; $Form.Height = $wasH

            # The dialogs, measured rather than eyeballed. Each is opened, its
            # control rectangles are written down, and it is closed from a timer
            # - ShowDialog blocks, so there is no other way to look inside one.
            foreach ($d in @(@("About", { Show-AboutDialog }),
                             @("Settings", { Show-SettingsEditor }),
                             @("Layout", { Show-LayoutEditor }))) {
                $Script:SelfTestName = $d[0]
                $tm = New-Object System.Windows.Forms.Timer
                $tm.Interval = 700
                $tm.Add_Tick({
                    $tm2 = $Script:SelfTestTimer
                    $dlg = [System.Windows.Forms.Application]::OpenForms |
                           Where-Object { $_ -ne $Form -and $_.Visible } | Select-Object -First 1
                    if (-not $dlg) { return }
                    $tm2.Stop()
                    # Widest right edge and lowest bottom of any LEAF control,
                    # in FORM coordinates, versus the client area: anything
                    # outside it is being clipped.
                    #
                    # The dialogs dock their contents into nested panels now, so
                    # walking only $dlg.Controls sees three containers and calls
                    # it a day - it would report a dialog as fine however badly
                    # its actual contents were placed.
                    $mr = 0; $mb = 0; $n = 0
                    $walk = New-Object System.Collections.Generic.Queue[object]
                    foreach ($c in $dlg.Controls) { $walk.Enqueue($c) }
                    while ($walk.Count -gt 0) {
                        $c = $walk.Dequeue()
                        if ($c.Controls.Count -gt 0) {
                            foreach ($k in $c.Controls) { $walk.Enqueue($k) }
                            continue                      # containers are not content
                        }
                        $n++
                        $tl = $dlg.PointToClient($c.Parent.PointToScreen($c.Location))
                        if (($tl.X + $c.Width)  -gt $mr) { $mr = $tl.X + $c.Width }
                        if (($tl.Y + $c.Height) -gt $mb) { $mb = $tl.Y + $c.Height }
                    }
                    # Row count too: the layout editor is only usable if its
                    # zone headings are in the list (they are what a panel is
                    # dragged onto), and "did the list fill at all" is the
                    # cheapest thing that can go wrong unnoticed.
                    $rows = 0; $sizable = 0
                    $lvd = $null
                    $q2 = New-Object System.Collections.Generic.Queue[object]
                    foreach ($c in $dlg.Controls) { $q2.Enqueue($c) }
                    while ($q2.Count -gt 0) {
                        $c = $q2.Dequeue()
                        if ($c -is [System.Windows.Forms.ListView]) { $lvd = $c }
                        foreach ($k in $c.Controls) { $q2.Enqueue($k) }
                    }
                    if ($lvd) { $rows = $lvd.Items.Count }
                    if ($dlg.FormBorderStyle -eq [System.Windows.Forms.FormBorderStyle]::Sizable) { $sizable = 1 }
                    Write-CrashLog ("SelfDlg {0}: client={1}x{2} maxRight={3} maxBottom={4} controls={5} rows={6} sizable={7}" -f `
                        $Script:SelfTestName, $dlg.ClientSize.Width, $dlg.ClientSize.Height, $mr, $mb, $n, $rows, $sizable)
                    $dlg.Close()
                })
                $Script:SelfTestTimer = $tm
                $tm.Start()
                # The startup test closes the window on its own watchdog, and a
                # dialog cannot be shown over a form that has already gone. This
                # is a diagnostic step, so a closed window means "stop", not
                # "log an exception" - which is what it did, twice, and reported
                # as a startup fault.
                if ($Form.IsDisposed -or $Form.Disposing) { $tm.Stop(); $tm.Dispose(); break }
                & $d[1]
                $tm.Stop(); $tm.Dispose()
            }
        } catch {
            Write-CrashLog "SelfTest failed: $($_.Exception.Message)"
        }
        $Form.Close()
    }
    if ($env:UTW_LAYOUT_SELFTEST) { $Form.Add_Shown({ Invoke-LayoutSelfTest }) }

    $Script:LastWorkArea = (Get-FormWorkArea $Form)
    $fitTimer = New-Object System.Windows.Forms.Timer
    $fitTimer.Interval = 1500
    $fitTimer.Add_Tick({
        try {
            if ($Form.IsDisposed -or $Form.WindowState -ne [System.Windows.Forms.FormWindowState]::Normal) { return }
            $now = Get-FormWorkArea $Form
            if ($now -eq $Script:LastWorkArea) { return }
            $Script:LastWorkArea = $now
            Write-CrashLog "Display changed: work area now $($now.Width)x$($now.Height) - re-fitting $($Form.Width)x$($Form.Height)"
            $Form.SuspendLayout()
            try {
                Set-FormMinimumSize    -Form $Form
                Set-FormWithinWorkArea -Form $Form -KeepPosition
            } finally { $Form.ResumeLayout($true) }
        } catch {
            Write-CrashLog "Re-fit failed: $($_.Exception.Message)"
        }
    })
    $fitTimer.Start()


    # ---- Helpers ----
    function Get-ClownVerdict {
        <#
            The Clown Fiesta verdict line. Two honks for a success, one for a
            failure - so the outcome is audible in the text even before you read
            it, which is the joke and also, mildly, the point.

            Returns $null in every other theme, and the caller falls back to the
            plain wording. Nothing about the run changes; this is the label only.
        #>
        param([bool]$Success)
        if ($cmbTheme.SelectedItem.ToString() -ne "Clown Fiesta") { return $null }
        $star = [char]0x2605
        if ($Success) { return "$star HONK HONK! Migration Successful!" }
        return "$star HONK! Migration failed!"
    }

    function Get-ClownProgress {
        param([int]$Pct, [string]$Phase = "")
        if ($cmbTheme.SelectedItem.ToString() -ne "Clown Fiesta") { return $null }
        $road = [char]0x00B7  # middle dot
        $trackLen = 20
        $star = [char]0x2605  # Ã¢Ëœâ€¦
        $car  = "$([char]0x25BA)$([char]0x263B)"  # Ã¢â€“ÂºÃ¢ËœÂ»
        if ($Phase -and $Pct -le 0) {
            $clownPhases = @{ "Scanning" = "$star Scanning..."; "Estimating" = "$star Estimating..."; "Working" = "$star Working..."; "Saving" = "$star Saving..." }
            if ($clownPhases.ContainsKey($Phase)) { return $clownPhases[$Phase] }
            return $null
        }
        $safePct = [Math]::Max(0, [Math]::Min(100, $Pct))
        $pos = [Math]::Floor($safePct / 100 * $trackLen)
        if ($pos -ge $trackLen) { $pos = $trackLen - 1 }
        $left  = [string]::new($road, $pos)
        $right = [string]::new($road, ($trackLen - $pos - 1))
        return "$star${left}${car}${right}$star $safePct%"
    }

    # ---- Parse USMT progress log CSV into friendly text ----
    function Format-ProgressLine {
        param([string]$RawLine)
        $l = $RawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($l)) { return $null }
        # Progress log CSV patterns:
        #   "PHASE, Scanning"  "PHASE, Collecting"  "PHASE, Applying"  "PHASE, Saving"
        #   "detectedUser, DOMAIN\user"
        #   "totalSizeInMBToTransfer, 1234"
        #   "totalPercentageCompleted, 75"
        #   "numFileCollected, 500"   "numFileFailed, 0"
        #   "numBytesTransferred, 123456"
        #   "Successful run"   "errorCode, 72"
        if ($l -match '^PHASE,\s*(.+)$')                        { return "Phase: $($Matches[1].Trim())" }
        if ($l -match '^detectedUser,\s*(.+)$')                 { return "Detected user: $($Matches[1].Trim())" }
        if ($l -match '^totalSizeInMBToTransfer,\s*(\d+)')      { return "Total size to transfer: $($Matches[1]) MB" }
        if ($l -match '^totalPercentageCompleted,\s*(\d+)')     { return "Progress: $($Matches[1])%" }
        if ($l -match '^numFileCollected,\s*(\d+)')             { return "Files collected: $($Matches[1])" }
        if ($l -match '^numFileFailed,\s*(\d+)')                { $n = $Matches[1]; if ($n -ne "0") { return "Files failed: $n" } else { return $null } }
        if ($l -match '^numBytesTransferred,\s*(\d+)')          { $mb = [Math]::Round([int64]$Matches[1] / 1MB, 1); return "Transferred: $mb MB" }
        if ($l -match '^numDUCollected,\s*(\d+)')               { return "Data units collected: $($Matches[1])" }
        if ($l -match '^numObjectsCollected,\s*(\d+)')          { return "Objects collected: $($Matches[1])" }
        if ($l -match '^numObjectsFailed,\s*(\d+)')             { $n = $Matches[1]; if ($n -ne "0") { return "Objects failed: $n" } else { return $null } }
        if ($l -match '^Successful run')                        { return "USMT completed successfully" }
        if ($l -match '^errorCode,\s*(\d+)')                    { return "USMT error code: $($Matches[1])" }
        # Skip noisy lines: ScanState / LoadState version headers, timestamps, commas-only
        if ($l -match '^(ScanState|LoadState|scanstate|loadstate)\s' -or $l -match '^\d{4}/' -or $l -match '^,+$') { return $null }
        # Return anything else as-is (unknown progress lines)
        return $l
    }

    function Write-UTWError {
        <#
            For failures that belong to THIS tool - staging, shares, scheduled
            tasks, store locks. Microsoft's return-code page has nothing to say
            about any of them, so these are pointed at the UTW notes instead.
        #>
        param([Parameter(Mandatory)][string]$What, [string]$Try = "", [string]$Detail = "")
        foreach ($row in (Format-UTWErrorLines -What $What -Try $Try -Detail $Detail)) {
            $c = switch ($row.Kind) {
                "error" { $Script:T.Error }
                "warn"  { $Script:T.Warning }
                default { $Script:T.TextDim }
            }
            Append-Output $row.Text $c
        }
    }

    function Write-USMTExit {
        <#
            Prints the exit code with its meaning and the reference link. The
            link is left as bare text on purpose: the output pane detects URLs
            and the LinkClicked handler opens it, so it is clickable without
            any of this code knowing how a browser gets launched.
        #>
        param([int]$Code, [string]$LogPath = "")
        # USMT'S OWN SUMMARY FIRST, when there is a log to read it from.
        #
        # The exit code is a category, not a cause. A destination disk that
        # filled up came back as code 26 - "bad XML, more than one Windows
        # installation, or an unknown fault" - and sent the operator looking at
        # migration XML while the log said "Not enough disk space" 25,427 times
        # and printed a tip saying so. What USMT actually found outranks what
        # its exit code implies, so it is printed above it.
        if ($LogPath) {
            try {
                $sum = Get-USMTErrorSummary -LogPath $LogPath
                if ($sum) { foreach ($line in $sum.Text) { Append-Output $line $Script:T.Error } }
            } catch { }
        }
        foreach ($row in (Format-USMTExitLines $Code)) {
            $c = switch ($row.Kind) {
                "ok"    { $Script:T.Success }
                "error" { $Script:T.Error }
                "warn"  { $Script:T.Warning }
                default { $Script:T.TextDim }
            }
            Append-Output $row.Text $c
        }
    }

    function Append-Output {
        param([string]$Text, [System.Drawing.Color]$Color)
        $txtOutput.SelectionStart  = $txtOutput.TextLength
        $txtOutput.SelectionLength = 0
        $txtOutput.SelectionColor  = $Color
        $txtOutput.AppendText("$Text`n")
        $txtOutput.ScrollToCaret()
        # Parse percentage from USMT output (e.g. "PHASE 2 Collecting  52%")
        if ($Text -match '(\d{1,3})\s*%') {
            $pct = [int]$Matches[1]
            if ($pct -ge 0 -and $pct -le 100) {
                $progressBar.Style = "Continuous"
                $progressBar.Value = $pct
                $clown = Get-ClownProgress -Pct $pct
                $lblProgress.Text = if ($clown) { $clown } else { "$pct%" }
            }
        } elseif ($Text -match 'Scanning') {
            $progressBar.Style = "Continuous"; $progressBar.Value = 10
            $clown = Get-ClownProgress -Pct 10 -Phase "Scanning"
            $lblProgress.Text = if ($clown) { $clown } else { "Scanning..." }
        } elseif ($Text -match 'Estimating') {
            $progressBar.Style = "Continuous"; $progressBar.Value = 25
            $clown = Get-ClownProgress -Pct 25 -Phase "Estimating"
            $lblProgress.Text = if ($clown) { $clown } else { "Estimating..." }
        } elseif ($Text -match 'Applying|Collecting') {
            $progressBar.Style = "Continuous"; $progressBar.Value = 40
            $clown = Get-ClownProgress -Pct 40 -Phase "Working"
            $lblProgress.Text = if ($clown) { $clown } else { "Working..." }
        } elseif ($Text -match 'Saving|Writing') {
            $progressBar.Style = "Continuous"; $progressBar.Value = 70
            $clown = Get-ClownProgress -Pct 70 -Phase "Saving"
            $lblProgress.Text = if ($clown) { $clown } else { "Saving..." }
        }
    }
    function Set-UIRunning {
        param([bool]$Running)
        # Read by the Run click guard, which must not re-enable the button after
        # a handler that DID start something.
        $Script:OperationRunning = $Running
        $btnRun.Enabled         = -not $Running
        $btnStop.Enabled        = $Running
        # One clock for the whole operation, started the moment the UI locks.
        if ($Running -and -not $Script:OpStartTime) { $Script:OpStartTime = Get-Date }
        $cmbAction.Enabled      = -not $Running
        $cmbScope.Enabled       = -not $Running   # Update-Fields refines this below
        $cmbTheme.Enabled       = -not $Running   # prevent theme glitches mid-operation
        $cmbSaveTo.Enabled      = -not $Running
        $txtCentralPath.Enabled = -not $Running
        $txtImportStore.Enabled = -not $Running
        $btnBrowseImportStore.Enabled = -not $Running
        $btnBrowseStoreList.Enabled  = -not $Running
        $btnFindSrc.Enabled          = -not $Running
        $btnFindDst.Enabled          = -not $Running
        $btnBrowseCentral.Enabled = -not $Running
        $txtUsername.Enabled    = -not $Running
        $btnPickUser.Enabled    = -not $Running
        $txtDomain.Enabled      = -not $Running
        $txtNewPC.Enabled       = -not $Running
        $txtSourcePC.Enabled    = -not $Running
        $txtUSBPath.Enabled     = -not $Running
        $txtUSMTPath.Enabled    = -not $Running
        $btnBrowseUSMT.Enabled  = -not $Running
        $chkOverwrite.Enabled   = -not $Running
        $chkCleanup.Enabled     = -not $Running
        $chkVerifyProfile.Enabled    = -not $Running
        $chkCheckDisk.Enabled        = -not $Running
        $chkCheckInactive.Enabled    = -not $Running
        $chkEstimateSize.Enabled     = -not $Running
        $chkCleanStores.Enabled      = -not $Running   # Update-Fields refines this
        $chkCleanProfiles.Enabled    = -not $Running   # Update-Fields refines this
        $chkExcludeOneDrive.Enabled  = -not $Running
        # Expert controls lock down with everything else - editing the command
        # mid-run would show something that is not what is executing.
        $txtCommand.ReadOnly    = $Running
        $btnCmdRevert.Enabled   = -not $Running
        $btnCmdPaste.Enabled    = -not $Running
        $chkODDetect.Enabled    = -not $Running
        $txtODPattern.Enabled   = -not $Running
        $txtODMin.Enabled       = -not $Running
        $cmbArch.Enabled            = -not $Running
        $chkLogOnExit.Enabled       = -not $Running
        $chkRenameOnRestore.Enabled = -not $Running
        $txtRenameTo.Enabled        = (-not $Running) -and $chkRenameOnRestore.Checked
        $chkDeleteSource.Enabled    = -not $Running
        $menu.Enabled               = -not $Running
        $btnListUsers.Enabled       = -not $Running
        $btnListStores.Enabled      = -not $Running
        $rbSimple.Enabled       = -not $Running
        $rbExpert.Enabled       = -not $Running
        $chkExpertMode.Enabled  = -not $Running
        # Update-Fields owns whether OneDrive/Extract controls apply at all, so
        # re-run it on the way out rather than leaving everything blanket-enabled.
        # Every terminal path passes through here, so it is also where the
        # single-run state from a sizing pass gets cleared.
        if (-not $Running) {
            Update-Fields
            $Script:ExportPlan = $null
            $Script:OpStartTime = $null
            # Every terminal path passes through here, success or failure, so
            # this is also where the destination claim is given back.
            if ($Script:StoreLock) { Unlock-StorePath $Script:StoreLock; $Script:StoreLock = $null }
        }
        # Progress bar
        if ($Running) {
            $progressBar.Style = "Marquee"
            $progressBar.Value = 0
            $lblProgress.Text  = ""
        } else {
            $progressBar.Style = "Continuous"
            $progressBar.Value = 0
            $lblProgress.Text  = ""
        }
    }

    # Which input fields the CURRENT operation actually uses.
    #
    # Values are kept when a field is hidden - re-selecting an operation should
    # bring its old computer names back - but a hidden field must never feed the
    # run. Reading Control.Visible cannot answer this: collapsing Setup hides
    # every field at once, which would blank the whole form mid-migration. So
    # Update-Fields records intent here and Get-ActiveText reads it.
    $Script:FieldApplies = @{}

    function Update-WindowTitle {
        <#
            The taskbar button is the only thing that distinguishes two windows
            when both are minimised, so it carries what actually tells them
            apart: WHICH MIGRATION this window is doing.

                User Transfer Wizard  -  #2  PC-TEST01 -> PC-NEW02

            A bare number was the first attempt and was nearly useless - and it
            never incremented anyway, so every extra window claimed to be the
            same one. The number is kept for the case where nothing is filled in
            yet, and dropped entirely for a lone window, which needs no label.
        #>
        $parts = @()
        if ($Script:InstanceNumber -and $Script:InstanceNumber -gt 1) { $parts += "#$($Script:InstanceNumber)" }

        $src = if ($Script:FieldApplies["SourcePC"]) { $txtSourcePC.Text.Trim() } else { "" }
        $dst = if ($Script:FieldApplies["NewPC"])    { $txtNewPC.Text.Trim() }    else { "" }
        $op  = try { Get-OperationText } catch { "" }
        $arrow = "->"
        $route = ""
        if ($op -match "Clean Up") {
            $route = if ($src) { "clean up $src" } else { "clean up this PC" }
        } elseif ($op -match "Extract") {
            $route = "extract"
        } elseif ($src -and $dst) {
            $route = "$src $arrow $dst"
        } elseif ($dst) {
            $route = "$arrow $dst"
        } elseif ($src) {
            $route = "from $src"
        }
        if ($route) { $parts += $route }
        # A hand-edited command survives a switch back to Simple, where the
        # panel that would show it is hidden. The title is then the only place
        # it can be seen, so it says so.
        if ($Script:CmdEdited) { $parts += "custom command" }
        if (-not $Script:IsElevated) { $parts += "NOT RUNNING AS ADMINISTRATOR" }

        $base = if ($Script:TitleBase) { $Script:TitleBase } else { "User Transfer Wizard" }
        $Form.Text = if ($parts.Count) { "$base  -  " + ($parts -join "  -  ") } else { $base }
    }

    function Get-ActiveText {
        param([string]$Key, [System.Windows.Forms.Control]$Control)
        if (-not $Script:FieldApplies[$Key]) { return "" }
        return $Control.Text.Trim()
    }

    # =====================================================================
    #  Expert mode
    # =====================================================================
    # Extra arguments the operator typed that this tool does not model. Kept
    # per leg, so adding /vsc to the capture does not also land on the restore.
    $Script:ExtraExport = @()
    $Script:ExtraImport = @()
    # Set while the panel is writing to the checkboxes or vice versa, so the two
    # directions cannot chase each other round the loop.
    $Script:CmdSyncing  = $false
    # True once the text no longer matches what would be generated.
    $Script:CmdEdited   = $false

    function Invoke-ProgramCompare {
        <#
            "What did the old machine have that this one has not?"

            USMT moves files and settings; it has never moved applications. So
            after every migration somebody opens Programs and Features on two
            machines and reads them side by side. This is that, done properly.
        #>
        $oldPC = Get-ActiveText "SourcePC" $txtSourcePC
        $newPC = Get-ActiveText "NewPC"    $txtNewPC
        if (-not $oldPC) { $oldPC = $env:COMPUTERNAME }
        if (-not $newPC) {
            Show-ThemedMessage "Name the old PC and the new PC first - the two computer boxes in Migration Details." "Compare programs" "OK" "Warning"
            return
        }
        if ((Test-IsThisComputer $oldPC) -and (Test-IsThisComputer $newPC)) {
            Show-ThemedMessage "The old PC and the new PC are the same machine." "Compare programs" "OK" "Warning"
            return
        }
        # Said once per session. The list is read live from the uninstall
        # registry on the old machine - so it has to be run while that machine
        # is still intact. After the profile is removed or the PC is re-imaged
        # there is nothing left to compare, and "what did we need to reinstall?"
        # can no longer be answered.
        if (-not $Script:ProgCompareWarned) {
            $Script:ProgCompareWarned = $true
            $ans = Show-ThemedMessage ("Run this comparison BEFORE you migrate and clean up the old PC.`n`n" +
                "It reads the installed-programs list live from $oldPC. Once that machine is wiped or handed back, " +
                "the record of what was installed is gone.`n`nCompare now?") "Compare programs" "YesNo" "Warning"
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $lblStatus.Text = "Reading installed programs..."; $lblStatus.ForeColor = $Script:AccentCyan
        [System.Windows.Forms.Application]::DoEvents()
        $r = Compare-MachinePrograms -OldPC $oldPC -NewPC $newPC
        $lblStatus.Text = "Ready"; $lblStatus.ForeColor = $Script:T.TextDim
        if (-not $r.Ok) {
            Write-UTWError -What "could not compare the installed programs" -Detail $r.Error `
                -Try "Both machines must be on, and you must be an administrator on them."
            return
        }
        Append-Output ("$oldPC has $($r.OldCount) program(s), $newPC has $($r.NewCount). " +
                       "$(@($r.Missing).Count) missing, $(@($r.Differs).Count) at a different version.") $Script:AccentCyan
        if ($r.FolderError) { Append-Output $r.FolderError $Script:T.Warning }
        Show-ProgramCompareDialog -Result $r
    }
    function Invoke-CatchUpSync {
        <#
            The whole catch-up operation: work out which two profile folders are
            being compared, list what differs, let the operator pick, copy that.

            THE ORDER MATTERS. Resolving the profile pair comes first and is the
            part most likely to be wrong, because the same person is often not
            spelled the same on both machines - alicew on the old PC, alicex on
            the new. Guessing silently would copy one person's documents into
            another person's profile, so the match is offered and confirmed, not
            assumed, whenever it is not exact.
        #>
        $oldPC = Get-ActiveText "SourcePC" $txtSourcePC
        $newPC = Get-ActiveText "NewPC"    $txtNewPC
        $user  = $txtUsername.Text.Trim()
        if (-not $oldPC) { $oldPC = $env:COMPUTERNAME }
        if (-not $newPC -or -not $user) {
            Show-ThemedMessage "Fill in the old PC, the new PC and the profile name first." "Compare & Sync" "OK" "Warning"
            return
        }
        # Same rule as a migration. This name is used to look a profile up rather
        # than to build a command, but it has no business containing command
        # punctuation either, and one rule is easier to trust than two.
        if (-not (Test-ValidUsername $user)) {
            Show-ThemedMessage "'$user' is not a usable profile name. Letters, numbers, spaces, dots, hyphens and one DOMAIN\ prefix." "Compare & Sync" "OK" "Warning"
            return
        }
        # PARENTHESES ARE LOAD-BEARING. Written as
        # "Test-IsThisComputer $oldPC -and (...)" this parses perfectly and is
        # wrong: -and becomes an ARGUMENT to the command rather than an
        # operator, so the guard is whatever the first call returned and the
        # second machine is never checked at all.
        if ((Test-IsThisComputer $oldPC) -and (Test-IsThisComputer $newPC)) {
            Show-ThemedMessage "The old PC and the new PC are the same machine." "Compare & Sync" "OK" "Warning"
            return
        }

        $lblStatus.Text = "Reading profiles..."; $lblStatus.ForeColor = $Script:AccentCyan
        [System.Windows.Forms.Application]::DoEvents()

        # The real folder on each side, read off the machine rather than guessed
        # from the username - a profile folder keeps the name it was created
        # with, so a rename leaves C:\Users\alicew behind an account called
        # alicex.
        $oldInfo = Get-RemoteUserProfiles -ComputerName $oldPC
        $newInfo = Get-RemoteUserProfiles -ComputerName $newPC
        if (-not $oldInfo.Ok) { Write-UTWError -What "could not list profiles on $oldPC" -Detail $oldInfo.Error; $lblStatus.Text = "Ready"; return }
        if (-not $newInfo.Ok) { Write-UTWError -What "could not list profiles on $newPC" -Detail $newInfo.Error; $lblStatus.Text = "Ready"; return }

        $oldP = @($oldInfo.Profiles | Where-Object { $_.Migratable -and $_.Leaf -ieq $user }) | Select-Object -First 1
        if (-not $oldP) {
            $near = Get-ProfileNameMatches -SourceUser $user -Candidates @($oldInfo.Profiles | Where-Object { $_.Migratable } | ForEach-Object { $_.Leaf })
            $hint = if ($near.Count -and $near[0].Score -ge 50) { " Did you mean '$($near[0].Name)'?" } else { "" }
            Show-ThemedMessage "There is no profile called '$user' on $oldPC.$hint" "Compare & Sync" "OK" "Warning"
            $lblStatus.Text = "Ready"; return
        }

        # THE NAME ON THE OTHER MACHINE. Exact match wins silently; anything
        # else is put to the operator with the best candidates first.
        $newP = @($newInfo.Profiles | Where-Object { $_.Migratable -and $_.Leaf -ieq $user }) | Select-Object -First 1
        if (-not $newP) {
            $cands = @($newInfo.Profiles | Where-Object { $_.Migratable })
            $ranked = Get-ProfileNameMatches -SourceUser $user -Candidates @($cands | ForEach-Object { $_.Leaf })
            $pick = Show-ProfileMatchDialog -SourceUser $user -SourcePC $oldPC -DestPC $newPC -Ranked $ranked
            if (-not $pick) { $lblStatus.Text = "Ready"; return }
            $newP = @($cands | Where-Object { $_.Leaf -ieq $pick }) | Select-Object -First 1
            if (-not $newP) { $lblStatus.Text = "Ready"; return }
        }

        $lblStatus.Text = "Comparing $($oldP.Leaf) on $oldPC with $($newP.Leaf) on $newPC..."
        $scopeNote = if ($Script:SyncIncludeAppData) { "user folders + AppData\Roaming" } else { "user folders only" }
        Append-Output "Comparing $oldPC\$($oldP.Leaf) against $newPC\$($newP.Leaf) - $scopeNote..." $Script:AccentCyan
        [System.Windows.Forms.Application]::DoEvents()

        $cmp = Get-ProfileSyncPreview -SourcePC $oldPC -SourceUser $oldP.Leaf -SourcePath $oldP.Path `
                                      -DestPC   $newPC -DestUser   $newP.Leaf -DestPath   $newP.Path
        $lblStatus.Text = "Ready"; $lblStatus.ForeColor = $Script:T.TextDim
        if (-not $cmp.Ok) {
            Write-UTWError -What "could not compare the two profiles" -Detail $cmp.Error `
                -Try "Check you are an administrator on both machines and that both are on."
            return
        }
        if ($cmp.Error) { Append-Output $cmp.Error $Script:T.Warning }
        if (-not @($cmp.Items).Count) {
            Append-Output "Nothing has changed in $($cmp.Scope -join ', ') on $oldPC since the migration." $Script:T.Success
            Show-ThemedMessage "Nothing to copy.`r`n`r`nLooked in: $($cmp.Scope -join ', ')`r`n`r`nThose folders hold the same files, or the new PC's copies are the newer ones.`r`n`r`nIf you expected a program's settings to differ, turn on 'Compare & Sync: include AppData' in Settings and compare again." "Compare & Sync" "OK" "Information"
            return
        }

        Append-Output "$(@($cmp.Items).Count) file(s) differ. Nothing has been copied yet." $Script:AccentCyan
        $chosen = Show-CatchUpDialog -Comparison $cmp -OldPC $oldPC -NewPC $newPC
        if (-not $chosen -or -not @($chosen).Count) {
            Append-Output "Compare & Sync cancelled - nothing was copied." $Script:T.TextDim
            return
        }

        $lblStatus.Text = "Copying $(@($chosen).Count) item(s)..."; $lblStatus.ForeColor = $Script:AccentCyan
        [System.Windows.Forms.Application]::DoEvents()
        $res = Invoke-ProfileSyncCopy -Items $chosen -DestRoot $cmp.Dest
        foreach ($e in $res.Errors) { Append-Output "Could not copy $e" $Script:T.Error }
        if ($res.Ok) {
            Append-Output "Copied $($res.Copied) item(s), $(Format-Size $res.Bytes), to $newPC\$($newP.Leaf)." $Script:T.Success
            $lblStatus.Text = "$($Script:CheckMark) Sync complete"; $lblStatus.ForeColor = $Script:T.Success
            Invoke-TaskbarFlash -Form $Form
        } else {
            Append-Output "Copied $($res.Copied), failed $($res.Failed)." $Script:T.Warning
            $lblStatus.Text = "Sync finished with errors"; $lblStatus.ForeColor = $Script:T.Warning
            Invoke-TaskbarFlash -Form $Form
        }
    }
    function Get-ExpertContext {
        <#
            Everything Get-CommandPreview needs, read from the live form. The
            paths here are PREDICTED, not final - a remote run's exact log name
            carries a timestamp that does not exist until it starts - so the
            preview shows the shape and the values that matter.
        #>
        $opText = Get-OperationText
        $mode   = Get-StoreMode
        $isCombo   = $opText -match [regex]::Escape([char]0x21C4)
        $isImport  = (-not $isCombo) -and ($opText -match "Import")
        $isExport  = (-not $isCombo) -and ($opText -match "Export")
        $isExtract = $opText -match "Extract"
        $isCleanup = $opText -match "Clean Up"
        $isSync    = $opText -match "Compare"
        $isAll     = $opText -match "All Profiles"
        $isSet     = $opText -match "Computer Settings"

        $kind = if     ($isCleanup) { "Cleanup" }
                elseif ($isExtract) { "Extract" }
                elseif ($isCombo)   { "Combo" }
                elseif ($isImport)  { "Import" }
                else                { "Export" }

        $src  = Get-ActiveText "SourcePC" $txtSourcePC
        $dst  = Get-ActiveText "NewPC"    $txtNewPC
        # Split the same way the run does. Reading the box raw made "alice, bob"
        # preview as one account literally called "alice, bob".
        $ulist = @(Get-UsernameList)
        $user  = if ($ulist.Count -gt 0) { $ulist[0] } else { "" }
        $sub  = if ($isSet) { "Settings_$(if ($src) { $src } else { $env:COMPUTERNAME })" }
                elseif ($isAll) { if ($src) { $src } else { $env:COMPUTERNAME } }
                else { $user }

        # Where the store lands, by the same rules the run uses.
        $expStore = switch ($mode) {
            "Central" { $p = Get-ActiveText "CentralPath" $txtCentralPath
                        if ($p) { Join-Path $p "$(if ($src) { $src } else { $env:COMPUTERNAME })_$sub" } else { "<network share>\$sub" } }
            "USB"     { $p = Get-ActiveText "USBPath" $txtUSBPath
                        if ($p) { Join-Path $p "$($Script:AppConfig.DefaultStorePath)\$sub" } else { "<drive>\$sub" } }
            default   { if ($dst) { "\\$dst\C`$\$($Script:AppConfig.DefaultStorePath)\$sub" } else { "<new PC>\$sub" } }
        }
        $impStore = if ($isImport) {
                        $picked = Get-ActiveText "ImportStore" $txtImportStore
                        if ($picked) { $picked } else { "<migration file>" }
                    } else {
                        "C:\$($Script:AppConfig.DefaultStorePath)\$sub"
                    }

        $cleanupPCs = @()
        if ($isCleanup) {
            foreach ($n in ($txtSourcePC.Text -split '[,;]')) { $n = $n.Trim(); if ($n) { $cleanupPCs += $n } }
            if ($cleanupPCs.Count -eq 0) { $cleanupPCs = @($env:COMPUTERNAME) }
        }

        return @{
            Kind = $kind; USMTPath = $txtUSMTPath.Text.Trim()
            # A drive store cannot do both legs in one run, and the preview has
            # to know that or it shows a LoadState that will never be issued.
            DriveStore = ($mode -eq "USB")
            Verbosity = $Script:AppConfig.Verbosity; Domain = $txtDomain.Text.Trim()
            LogFolder = $Script:AppConfig.LogFolder
            Username = $user; AllProfiles = $isAll; SettingsOnly = $isSet
            # WHAT THE RUN WILL ACTUALLY PASS, not a reconstruction of it.
            #
            # These three were missing, so a two-user capture previewed as a
            # ONE-user command line and a restore-under-a-different-name showed
            # no /mu: at all. A preview that disagrees with the run is worse
            # than no preview, because it is the thing people check.
            Usernames = $(if ($ulist.Count -gt 1) { $ulist } else { @() })
            RenameFrom = (Get-RenameFrom); RenameTo = (Get-RenameTo)
            Overwrite = ($chkOverwrite.Checked -and $chkOverwrite.Enabled)
            ExcludeOneDrive = ($chkExcludeOneDrive.Checked -and $chkExcludeOneDrive.Enabled)
            # Resolved Config.xml decision, so the preview shows the /config that
            # will actually run. Under 'auto' this is only true once a run's
            # build check has found a mismatch; a note row explains that.
            ApplyConfig = (Should-ApplyConfigXml)
            SourcePC = $src; DestPC = $dst
            ExportStore = $expStore; ImportStore = $impStore
            LogLabel = $(if ($isSet) { "Settings" } elseif ($isAll) { "AllProfiles" } elseif ($user) { $user } else { "user" })
            MigFile = $txtMigrationFile.Text.Trim(); ExtractTo = $txtExtractPath.Text.Trim()
            CleanupPCs = $cleanupPCs; CleanStores = $chkCleanStores.Checked
            ExtraExport = $Script:ExtraExport; ExtraImport = $Script:ExtraImport
            # THE OPTIONS, so the preview can show what they actually cause.
            #
            # The panel listed the two USMT commands and nothing else, which made
            # it look as though ticking a pre-check did nothing - the steps it
            # adds are things this tool does itself, and a step with no command
            # to print was simply left out. Silence read as "no effect".
            VerifyProfile = ($chkVerifyProfile.Checked -and $chkVerifyProfile.Enabled)
            CheckDisk     = ($chkCheckDisk.Checked     -and $chkCheckDisk.Enabled)
            CheckInactive = ($chkCheckInactive.Checked -and $chkCheckInactive.Enabled)
            EstimateSize  = ($chkEstimateSize.Checked  -and $chkEstimateSize.Enabled)
            DeleteSource  = ($chkDeleteSource.Checked  -and $chkDeleteSource.Enabled)
            RenameOn      = ($chkRenameOnRestore.Checked -and $chkRenameOnRestore.Enabled)
            ODDetect      = ($chkODDetect.Checked      -and $chkODDetect.Enabled)
        }
    }

    function Update-CommandPreview {
        <#
            Regenerates the panel from the current form state. Does nothing if
            the operator has edited the text - their edit is the source of truth
            until they press Regenerate, because silently overwriting what
            someone just typed is the worst thing an editor can do.
        #>
        param([switch]$Force)
        if (-not $grpExpert) { return }
        if ($Script:CmdSyncing) { return }
        if ($Script:CmdEdited -and -not $Force) { return }

        $Script:CmdSyncing = $true
        try {
            $rows = Get-CommandPreview (Get-ExpertContext)
            $lines = @()
            foreach ($r in $rows) {
                $lines += "REM $($r.Label)  -  runs on $($r.Where)"
                # A STEP THAT IS NOT A COMMAND IS NOT PRINTED AS ONE.
                #
                # The pre-checks and the staging copy are things this tool does
                # itself; there is no command line to run and nothing to edit.
                # Printing them as `"(UTW)" Copy ...` would read like something
                # that could be pasted into a prompt, which is the opposite of
                # what this panel is for. They are described instead, as
                # comments, so the sequence is complete and still honest about
                # which parts of it are actually commands.
                if ($r.Tool -like "(*)") {
                    $lines += "REM     $($r.Args)"
                } else {
                    $lines += "`"$($r.Tool)`" $($r.Args)"
                }
                $lines += ""
            }
            $txtCommand.Text = ($lines -join "`r`n").TrimEnd()
            $Script:CmdEdited = $false
            $lblExpertState.ForeColor = $Script:T.TextDim
            $lblExpertState.Text = "generated from the options above"
        } catch {
            $txtCommand.Text = "Could not build a preview: $($_.Exception.Message)"
        } finally {
            $Script:CmdSyncing = $false
        }
    }

    function Read-CommandPanel {
        <#
            Parses what is in the box back into the form. Runs on every edit, so
            deleting /o unticks Overwrite and deleting the OneDrive XML unticks
            that box - which is the half of the two-way binding that makes the
            panel worth editing rather than just reading.
        #>
        if ($Script:CmdSyncing) { return }
        $Script:CmdSyncing = $true
        try {
            $exportSeen = $false; $importSeen = $false
            $exExtra = @(); $imExtra = @()
            $ow = $null; $od = $null
            foreach ($raw in ($txtCommand.Text -split "`r?`n")) {
                $line = $raw.Trim()
                if (-not $line -or $line -match '^REM\b') { continue }
                $p = Read-USMTCommandEdits $line
                if (-not $p.Ok) { continue }
                if ($p.Tool -match 'scanstate') {
                    $exportSeen = $true; $exExtra += $p.Extra
                    if ($null -eq $ow) { $ow = $p.Overwrite }
                    if ($null -eq $od) { $od = $p.ExcludeOneDrive }
                } elseif ($p.Tool -match 'loadstate') {
                    $importSeen = $true; $imExtra += $p.Extra
                }
            }
            $Script:ExtraExport = @($exExtra)
            $Script:ExtraImport = @($imExtra)
            # Only a capture carries these two, so an import-only edit must not
            # reach over and clear the checkboxes it never mentioned.
            if ($exportSeen) {
                if ($chkOverwrite.Enabled -and $null -ne $ow)       { $chkOverwrite.Checked = $ow }
                if ($chkExcludeOneDrive.Enabled -and $null -ne $od) { $chkExcludeOneDrive.Checked = $od }
            }
            $Script:CmdEdited = $true
            Update-WindowTitle
            $lblExpertState.ForeColor = $Script:AccentOrange
            $extraCount = $Script:ExtraExport.Count + $Script:ExtraImport.Count
            $lblExpertState.Text = if ($extraCount -gt 0) {
                "edited - $extraCount custom argument$(if ($extraCount -ne 1) { 's' }) will be used"
            } else { "edited - this exact command will be used" }
        } catch {
            Write-CrashLog "Command panel parse failed: $($_.Exception.Message)"
        } finally {
            $Script:CmdSyncing = $false
        }
    }

    function Get-USMTPathForRun {
        <#
            Which USMT folder this run should use. Auto asks the machine the
            command will run ON - which for a remote capture is not this one.
            A machine that cannot be asked keeps the configured folder rather
            than guessing, because guessing wrong stops the run outright.
        #>
        param([string]$TargetPC = "")
        $base = $txtUSMTPath.Text.Trim()
        $sel  = if ($cmbArch.SelectedItem) { $cmbArch.SelectedItem.ToString() } else { "Auto (ask the PC)" }

        # --- architecture (unchanged) ---
        $result = $base
        if ($sel -match "64-bit") {
            $result = Get-USMTPathForArch -BasePath $base -Arch "amd64"
        } elseif ($sel -match "32-bit") {
            $result = Get-USMTPathForArch -BasePath $base -Arch "x86"
        } elseif ($TargetPC) {
            $a = Get-RemoteArchitecture -ComputerName $TargetPC
            if (-not $a.Ok) {
                Append-Output "Could not read the architecture of $TargetPC - using the configured USMT folder." $Script:T.TextDim
            } elseif ($a.Arch -eq "x86") {
                $p = Get-USMTPathForArch -BasePath $base -Arch "x86"
                if ($p -eq $base) {
                    Append-Output "$($Script:WarningSign) $TargetPC is 32-bit but no USMT\x86 folder was found - the 64-bit build will not run there." $Script:T.Warning
                } else {
                    Append-Output "$TargetPC is 32-bit - using $p" $Script:AccentCyan
                }
                $result = $p
            }
        }

        # --- version: use a build-matched USMT set if more than one is deployed ---
        # (amd64-<build> siblings, or a "...\Build <n>\amd64" folder per version).
        # Skipped entirely when there is only one set, so a single-folder setup
        # is unaffected.
        if ($TargetPC) {
            try {
                $ob = Get-RemoteOSBuild -ComputerName $TargetPC
                if ($ob.Ok) {
                    $vp = Get-USMTPathForVersion -BasePath $result -TargetBuild $ob.Build
                    if ($vp -and ($vp -ne $result)) {
                        $shown = Split-Path $vp -Leaf
                        if ($shown -match '^(amd64|x86|i386)$') { $shown = "$(Split-Path (Split-Path $vp -Parent) -Leaf)\$shown" }
                        Append-Output "USMT: $TargetPC is Windows build $($ob.Build) - using $shown (USMT build $(Get-UsmtBuild -USMTPath $vp))." $Script:AccentCyan
                        Write-CrashLog "USMT version pick for ${TargetPC} (build $($ob.Build)): $vp"
                        $result = $vp
                    }
                }
            } catch { Write-CrashLog "USMT version selection skipped for ${TargetPC}: $($_.Exception.Message)" }
        }
        return $result
    }

    function Get-RenameTo {
        # Empty unless the option is ticked AND a name was typed. Both, so an
        # abandoned experiment cannot leave a rename armed.
        if (-not $chkRenameOnRestore.Checked) { return "" }
        return $txtRenameTo.Text.Trim()
    }
    function Get-RenameFrom {
        # The account being renamed FROM is the one being restored - there is
        # never a case where they differ.
        if (-not (Get-RenameTo)) { return "" }
        $l = Get-UsernameList
        if ($l.Count -gt 0) { return $l[0] }
        return ""
    }

    function Get-UsernameList {
        <#
            The username box, split into names. One name is the ordinary case
            and comes back as a one-element list, so callers do not need two
            code paths for "one user" and "several".
        #>
        $out = @()
        foreach ($n in ($txtUsername.Text -split '[,;]')) {
            $n = $n.Trim()
            if ($n -and ($out -notcontains $n)) { $out += $n }
        }
        # THE COMMA IS LOAD-BEARING. Do not remove it.
        #
        # "return @($out)" looks like it guarantees an array and does not:
        # PowerShell unrolls a collection on the way out, so ONE user came back
        # as a String. A string has a .Count of 1 and indexes by CHARACTER, so
        # every caller that checked the count and then took [0] got "d" instead
        # of "asmith" - a single-user export naming an account nobody has, which
        # USMT then captures nothing for and still exits 0.
        #
        # Typing the variable does not help either; a List[string] unrolls just
        # the same. Wrapping in a one-element array is what survives it, and the
        # caller unwraps back to the array it wanted.
        return ,@($out)
    }

    function Get-ODPattern {
        # Falls back to the built-in default rather than matching nothing, which
        # is what an empty box would otherwise silently do.
        $p = $txtODPattern.Text.Trim()
        if ($p) { return $p }
        return $Script:OneDriveFolderPattern
    }

    function Get-ODMinBytes {
        <#
            The threshold in bytes. Anything unparseable is treated as 0 - which
            means "always ask" - because the safe failure for a check like this
            is to interrupt too often, never to stay silent.
        #>
        $raw = $txtODMin.Text.Trim()
        if (-not $raw) { return [long]0 }
        $mb = 0
        if ([int]::TryParse($raw, [ref]$mb) -and $mb -ge 0) { return ([long]$mb * 1MB) }
        return [long]0
    }

    function Get-CommandOverride {
        <#
            The arg string for one leg if the operator edited it, otherwise "".
            Returned WITHOUT the tool path - that is not theirs to change, since
            the tool that runs is decided by the operation.
        #>
        param([ValidateSet("Export","Import")][string]$Leg)
        if (-not $Script:CmdEdited) { return "" }
        $want = if ($Leg -eq "Export") { 'scanstate' } else { 'loadstate' }
        foreach ($raw in ($txtCommand.Text -split "`r?`n")) {
            $line = $raw.Trim()
            if (-not $line -or $line -match '^REM\b') { continue }
            $tokens = @(Split-CommandLine $line)
            if ($tokens.Count -lt 2) { continue }
            if ($tokens[0].Trim('"') -match $want) {
                return (($tokens | Select-Object -Skip 1) -join " ")
            }
        }
        return ""
    }

    # ---- updateFields  -  toggles visible controls based on operation/dest selection ----
    function Update-DetailsGeometry {
        <#
            Places the Migration Details row for the panel's CURRENT width.

            Split out of Update-Fields so that resizing costs only this. Which
            controls belong on screen is decided by Update-Fields and cached in
            $Script:FieldLayout; this reads that cache and does nothing but
            arithmetic, visibility and placement - cheap enough to run on every
            frame of a divider drag, which is exactly what it is for.
        #>
        if (-not $Script:FieldLayout) { return }
        $f = $Script:FieldLayout
        $sideBySide = $f.SideBySide; $findSrc = $f.FindSrc;   $findDst = $f.FindDst
        $showNew    = $f.ShowNew;    $showSrc = $f.ShowSrc
        $showStore  = $f.ShowStore;  $showUSB = $f.ShowUSB;   $showCentral = $f.ShowCentral
        $isCleanup  = $f.IsCleanup

        # ---- How much wider than its design width is this panel? ----
        # Migration Details stretches with its zone now, so every X and every
        # width below is "the design number, scaled" PLUS a share of whatever
        # extra room the panel has been given. $extra is already in real pixels
        # and must not be scaled again - hence Set-RealBounds rather than
        # Set-DesignBounds for the whole block.
        #
        # A two-column row splits $extra down the middle so the halves stay
        # equal; a full-width row takes all of it.
        $sc = $Script:LayoutScale
        $D  = { param($n) [int][Math]::Round($n * $sc) }
        $extra = 0
        if ($Script:DetailsBaseWidth -gt 0) {
            $extra = $grpDetails.ClientSize.Width - $Script:DetailsBaseWidth
            if ($extra -lt 0) { $extra = 0 }
        }
        $half  = [int]($extra / 2)
        $findW = & $D $Script:FindBtnWidth
        # COPIED FROM A BOX, not scaled from a design number - the same reason
        # the route arrow does it, written down there: a single-line TextBox
        # takes its height from the FONT, so at most scale factors it does not
        # land on 26*scale. Every button beside a field was getting the scaled
        # number and coming out a pixel or three off its box, which is what
        # "Browse store and Choose are not like the Find button" is.
        $btnH  = if ($txtNewPC -and $txtNewPC.Height -gt 0) { $txtNewPC.Height } else { & $D 26 }

        # Row 1 left grows by the same half as row 1 right, so the username box
        # and its picker keep pace with the machine box opposite them.
        Set-RealBounds $txtUsername -X (& $D 112) -Y (& $D 54) -Width ((& $D 128) + $half)
        Set-RealBounds $btnPickUser -X ((& $D 244) + $half) -Y (& $D 53) -Width (& $D 72) -Height $btnH

        # The rows that are only ever shown one at a time still have to be
        # placed for the current width, or they keep the geometry from whenever
        # they were last visible.
        Set-RealBounds $txtImportStore       -X (& $D 15)  -Y (& $D 110) -Width ((& $D 365) + $extra)
        Set-RealBounds $btnBrowseStoreList   -X ((& $D 388) + $extra) -Y (& $D 108) -Width (& $D 100) -Height $btnH
        Set-RealBounds $btnBrowseImportStore -X ((& $D 496) + $extra) -Y (& $D 108) -Width (& $D 104) -Height $btnH
        Set-RealBounds $lblUSBPath      -X ((& $D 320) + $half) -Y (& $D 88)
        Set-RealBounds $txtUSBPath      -X ((& $D 320) + $half) -Y (& $D 110) -Width ((& $D 187) + $half)
        Set-RealBounds $btnBrowseUSB    -X ((& $D 515) + $extra) -Y (& $D 108) -Width (& $D 85) -Height $btnH
        Set-RealBounds $lblCentralPath  -X ((& $D 320) + $half) -Y (& $D 88)
        Set-RealBounds $txtCentralPath  -X ((& $D 320) + $half) -Y (& $D 110) -Width ((& $D 187) + $half)
        Set-RealBounds $btnBrowseCentral -X ((& $D 515) + $extra) -Y (& $D 108) -Width (& $D 85) -Height $btnH
        Set-RealBounds $txtMigrationFile -X (& $D 15) -Y (& $D 54)  -Width ((& $D 490) + $extra)
        Set-RealBounds $btnBrowseMig     -X ((& $D 515) + $extra) -Y (& $D 52)  -Width (& $D 85) -Height $btnH
        Set-RealBounds $txtExtractPath   -X (& $D 15) -Y (& $D 110) -Width ((& $D 490) + $extra)
        Set-RealBounds $btnBrowseExtract -X ((& $D 515) + $extra) -Y (& $D 108) -Width (& $D 85) -Height $btnH

        if ($sideBySide) {
            # y=86, not 88: this label is FontNormal and 22px tall against the
            # 20px of the FontSmall one opposite, so it needs the extra two
            # pixels to clear its own box.
            # The destination half starts halfway through the extra width, so
            # both machine boxes gain the same amount.
            $dstX = (& $D 335) + $half
            $dstT = (& $D $Script:PairBoxWidth) + $half     # total width of the half
            Set-RealBounds $lblNewPC -X $dstX -Y (& $D 86)
            # Then sit it exactly on the other label's baseline. Two different
            # fonts scaled and rounded independently land a pixel apart at some
            # factors; measuring off the real control cannot.
            $lblNewPC.Top = $lblSourcePC.Bottom - $lblNewPC.Height
            # The button width comes from $Script:FindBtnWidth, the same constant
            # the button was BUILT with and the same one the source side uses.
            # It was hard-coded to 26 here, so the button was silently squashed
            # to 26px the moment Update-Fields ran - which is every time the
            # operation changes - and the word "Find" was clipped to a sliver.
            Set-RealBounds $txtNewPC -X $dstX -Y (& $D 108) -Width $(if ($findDst) { $dstT - $findW - (& $D 4) } else { $dstT })
            if ($findDst) { Set-RealBounds $btnFindDst -X ($dstX + $dstT - $findW) -Y (& $D 108) -Width $findW -Height $btnH }
            Set-RealBounds $lblRouteArrow -X ((& $D 280) + $half) -Y (& $D 108) -Width (& $D 55)
            # Height is COPIED from the box, not scaled from a design number: a
            # single-line TextBox derives its height from the font, so only the
            # box knows what "the same height as the boxes" comes out to at this
            # scale. Getting it from anywhere else leaves the glyph off-centre.
            $lblRouteArrow.Height = $txtNewPC.Height
        } else {
            $dstX = (& $D 320) + $half
            $dstT = (& $D 280) + $half
            Set-RealBounds $lblNewPC -X $dstX -Y (& $D 32)
            Set-RealBounds $txtNewPC -X $dstX -Y (& $D 54) -Width $(if ($findDst) { $dstT - $findW - (& $D 4) } else { $dstT })
            if ($findDst) { Set-RealBounds $btnFindDst -X ($dstX + $dstT - $findW) -Y (& $D 54) -Width $findW -Height $btnH }
        }

        $lblRouteArrow.Visible        = $sideBySide
        $lblNewPC.Visible             = $showNew; $txtNewPC.Visible = $showNew
        $lblImportStore.Visible       = $showStore
        $txtImportStore.Visible       = $showStore
        $btnBrowseImportStore.Visible = $showStore
        $btnBrowseStoreList.Visible   = $showStore
        $lblUSBPath.Visible           = $showUSB
        $txtUSBPath.Visible           = $showUSB
        $btnBrowseUSB.Visible         = $showUSB
        $lblCentralPath.Visible       = $showCentral
        $txtCentralPath.Visible       = $showCentral
        $btnBrowseCentral.Visible     = $showCentral
        $lblSourcePC.Visible          = $showSrc
        $txtSourcePC.Visible          = $showSrc
        # The hint sits in the right-hand slot, so it has to yield to whatever
        # real control is using it - the drive path box was being drawn over it.


        # A cleanup names machines to tidy, not a migration route. One field,
        # labelled for what it is, instead of two boxes still calling themselves
        # "capture from" and "restore to".
        if ($isCleanup) {
            $lblSourcePC.Text = "Computer(s) to clean up (blank = this PC) - separate several with commas:"
            Set-RealBounds $txtSourcePC -Width ((& $D 585) + $extra)
        } else {
            # The hint moved into the label, freeing the slot to its right for
            # the destination box.
            # A comparison captures nothing. Its left-hand machine is the one
            # they carried on using after the move, and saying so is the whole
            # explanation of what this operation is for.
            $lblSourcePC.Text = if ($isSync) { "Old PC (the one still being used):" }
                                else { "Capture from (blank = this PC):" }
            # Matched to the destination box when they share the row; the full
            # 280 when the right-hand slot belongs to a path field instead.
            # This runs AFTER the block above, so it owns the source width.
            $srcT = if ($sideBySide) { (& $D $Script:PairBoxWidth) + $half } else { (& $D 280) + $half }
            $srcW = if ($findSrc) { $srcT - $findW - (& $D 4) } else { $srcT }
            Set-RealBounds $txtSourcePC -X (& $D 15) -Y (& $D 108) -Width $srcW
            if ($findSrc) { Set-RealBounds $btnFindSrc -X ((& $D 15) + $srcW + (& $D 4)) -Y (& $D 108) -Width $findW -Height $btnH }
        }

        # THE ARROW IS PLACED FROM THE REAL BOXES, and in every branch.
        #
        # It used to be positioned only inside the side-by-side branch, from a
        # design constant plus the current $half. Any operation that is not
        # side-by-side left it wherever an earlier, narrower pass had put it - so
        # it held a position computed with $half = 35 while the source box beside
        # it had been laid out with $half = 114, and the two overlapped by 79px.
        # It is hidden in those operations, so nothing showed; it was still wrong,
        # and it is the kind of wrong that surfaces the moment the DPI changes.
        #
        # Measuring off the controls either side cannot drift at any scale, which
        # is the same reason its HEIGHT is copied from the box rather than scaled.
        $srcEdge = if ($findSrc) { $btnFindSrc.Right } else { $txtSourcePC.Right }
        $gapA    = & $D 6
        $wanted  = if ($showNew -and $txtNewPC.Left -gt $srcEdge) {
                       [int]((($srcEdge + $txtNewPC.Left) / 2) - ($lblRouteArrow.Width / 2))
                   } else { $srcEdge + $gapA }
        $lblRouteArrow.Left = [Math]::Max(($srcEdge + $gapA), $wanted)
    }

    function Update-Fields {
        # Batched during the settings restore. Assigning a saved value to a
        # combo fires its SelectedIndexChanged, which lands back here - so
        # restoring the operation, the scope, the destination and eight check
        # boxes ran the whole of this function eight times over before the
        # window was even shown. The restore calls it once when it is finished.
        if ($Script:SuppressFields) { $Script:FieldsDirty = $true; return }
        $Script:FieldsDirty = $false
        $opText    = Get-OperationText
        $isExtract = $opText -match "Extract"
        $isImport  = ($opText -match "Import") -and -not ($opText -match "Export")
        $storeMode = Get-StoreMode
        $isCentral = $storeMode -eq "Central"
        $isDirect  = $storeMode -eq "Direct"
        # "Network" now covers both wire-based routes; only USB is the odd one out.
        $isNetwork = $storeMode -ne "USB"
        $isCombo   = $opText -match [regex]::Escape([char]0x21C4)
        $isExport  = ($opText -match "Export") -and -not $isImport
        $isAll     = $opText -match "All Profiles"
        $isSettingsOnly = $opText -match "Computer Settings"
        $isCleanup = $opText -match "Clean Up"
        $isSync    = $opText -match "Compare"

        # Extract mode
        $lblMigrationFile.Visible = $isExtract; $txtMigrationFile.Visible = $isExtract; $btnBrowseMig.Visible = $isExtract
        $lblExtractPath.Visible   = $isExtract; $txtExtractPath.Visible   = $isExtract; $btnBrowseExtract.Visible = $isExtract

        # Username: hidden for extract, All Profiles, Settings-Only and cleanup
        $showUser = (-not $isExtract) -and (-not $isCleanup) -and (-not $isAll) -and (-not $isSettingsOnly)
        $lblUsername.Visible = $showUser; $txtUsername.Visible = $showUser; $btnPickUser.Visible = $showUser

        # Domain field: visible for non-extract, non-settings-only operations
        $showDomain = (-not $isExtract) -and (-not $isCleanup) -and (-not $isSettingsOnly)
        $txtDomain.Visible = $showDomain; $lblDomainSlash.Visible = $showDomain
        $lblUsername.Visible = $showUser

        # All Profiles hint label (replaces username area)
        $showAllHint = (-not $isExtract) -and $isAll -and (-not $isSettingsOnly)
        $lblAllProfilesHint.Visible = $showAllHint

        # Settings-only hint label
        $lblSettingsHint.Visible = $isSettingsOnly

        # "Restore to" - the PC LoadState will run on. Not asked for when nothing
        # is going to run there: a plain export to a network share or a drive
        # ends at the store.
        # The drive is unavailable as a DESTINATION while Export + Import is the
        # operation - it cannot be plugged into both machines at once. Greying
        # the destination rather than the operation means choosing Export +
        # Import never changes the operation out from under the operator.
        #
        # $driveCombo therefore only survives a keystroke or a restored settings
        # file, and is kept so the fields stay sane during that instant.
        $Script:DriveOptionDisabled = $isCombo
        $cmbSaveTo.Invalidate()
        $driveCombo = $isCombo -and (-not $isNetwork)

        # The second machine, whatever its role in this operation. For an export
        # it is where the store is PARKED, not somewhere LoadState will run - the
        # label below says which, because calling it "Restore to" during an
        # export-only run promised something that never happens.
        # Work out every "is this field in play" flag FIRST, then place and show
        # the controls. The layout decision below depends on three of them, and
        # computing it earlier silently read nulls - the row never rearranged.

        # Store picker - imports only, and it replaces every other source field.
        $showStore = $isImport -and (-not $isExtract) -and (-not $isCleanup)
        # Drive path. Captures only - an import gets its path from the store picker.
        # A comparison has no store at all: it reads one profile folder and
        # writes into another, so every Save To field is meaningless to it and
        # showing one would imply a choice that changes nothing.
        $showUSB = (-not $isExtract) -and (-not $isCleanup) -and (-not $isSync) -and (-not $isNetwork) -and (-not $isImport)
        # Central store root - likewise captures only.
        $showCentral = (-not $isExtract) -and (-not $isCleanup) -and (-not $isSync) -and $isCentral -and (-not $isImport)
        # "Capture from" decides whether the work happens here or on another PC.
        # It applies to any capture on any store type - that is what unlocks a
        # remote export to the old machine's own USB drive.
        # COMPARE NEEDS BOTH MACHINES, and is neither an export nor an import.
        #
        # Every clause here was written as "which migration is this", so an
        # action that is not a migration fell through all of them and the two
        # computer fields simply did not appear - leaving an operation on screen
        # with nothing to fill in. It names both PCs by definition: that is the
        # whole operation.
        $showSrc = (-not $isExtract) -and ($isCleanup -or $isExport -or $isCombo -or $isSync)
        $showNew = (-not $isExtract) -and (-not $isCleanup) -and (-not $driveCombo) -and
                   ($isImport -or $isCombo -or $isSync -or ($isExport -and $isDirect))

        $lblNewPC.Text = if ($isSync) { "Compare against (new PC):" }
                         elseif ($isImport) { "Restore to (blank = this PC):" }
                         elseif ($isCombo) { "Restore to (new PC):" }
                         else { "Save the store on (new PC):" }

        # When both machines are in play and the right-hand slot is free, the
        # destination sits beside "Capture from" with an arrow between them, in
        # the space the "leave blank" hint used to occupy - that hint is now part
        # of the Capture from label, so nothing is displaced.
        # Boxes share y=108 so the pair and the arrow line up exactly.
        #
        # These are DESIGN pixels and must go through Set-DesignBounds - this
        # code runs long after the form was scaled, and assigning the raw
        # numbers put the box a fraction of the way across the group on any
        # display above 100%, on top of whatever was already there.
        # The row is split into equal halves so the two machines read as a pair
        # rather than as a big box and a small one:
        #
        #   15 .... 280   280 .. 335   335 .... 600     content spans 15..600
        #   [ source ]      [ -> ]      [  dest  ]      265 + 55 + 265 = 585
        #
        # The arrow is the whole 55px gap with its glyph centred, which puts it
        # on 307.5 - the exact midpoint of the row. Both boxes are 265 wide.
        # Each machine box gives up 30px to its find-in-AD button. Both boxes
        # give up the same amount so the pair stays symmetric.
        $sideBySide = $showSrc -and $showNew -and (-not $showUSB) -and (-not $showCentral)
        $findSrc = $showSrc -and (-not $isCleanup)
        $findDst = $showNew
        $btnFindSrc.Visible = $findSrc
        $btnFindDst.Visible = $findDst

        # ---- Geometry ----
        # The placement is a SEPARATE function driven from this cached flag set.
        #
        # Dragging a divider resizes the panels continuously, and every frame
        # used to run the whole of Update-Fields: twenty Visible assignments,
        # ten Set-Tip calls (each of which word-wraps a paragraph), the window
        # title, the summary pane and the command preview - all to move six
        # boxes. That is what made a drag feel heavy. A drag frame now runs
        # Update-DetailsGeometry alone, which is arithmetic and Set-RealBounds.
        # EVERY flag Update-DetailsGeometry reads has to be in here. It sets the
        # visibility of the source box, the store box, the drive path and the
        # UNC path as well as placing them, and four of those keys were missing
        # - so it read $null, took that as false, and hid them. That is how the
        # "Capture from" field vanished from Export and Export + Import, the
        # store picker vanished from Import, and Clean Up lost its computer list
        # entirely. The self-test now asserts the visible field set per
        # operation so it cannot happen quietly again.
        $Script:FieldLayout = @{
            SideBySide  = $sideBySide; FindSrc = $findSrc;     FindDst = $findDst
            ShowNew     = $showNew;    ShowSrc = $showSrc
            ShowStore   = $showStore;  ShowUSB = $showUSB;     ShowCentral = $showCentral
            IsCleanup   = $isCleanup
        }
        Update-DetailsGeometry

        # Record what this operation actually reads, so a name left over from a
        # different operation cannot leak into the run.
        $Script:FieldApplies = @{
            NewPC       = $showNew
            SourcePC    = $showSrc
            CentralPath = $showCentral
            USBPath     = $showUSB
            Username    = $showUser
            ImportStore = $showStore
        }

        # "Applies to" means nothing for an Extract or a cleanup, so it greys out
        # instead of offering choices that would be ignored.
        $noScope = $isExtract -or $isCleanup
        $cmbScope.Enabled = -not $noScope
        $lblScope.ForeColor = if ($noScope) { $Script:T.TextDim } else { $Script:T.Text }
        # "Save to" chooses where a capture WRITES its store. An import reads one
        # that already exists and is pointed straight at it, so the choice does
        # not apply - it used to sit there implying an import obeyed it.
        $noSaveTo = $isExtract -or $isCleanup -or $isImport
        $cmbSaveTo.Enabled    = -not $noSaveTo
        $lblSaveTo.ForeColor  = if ($noSaveTo) { $Script:T.TextDim } else { $Script:T.Text }

        # The hint names the machine the store actually lands on, resolved live,
        # because "a drive" means a different disk depending on what is captured.
        $workPC = if ($txtSourcePC.Text.Trim() -and $showSrc) { $txtSourcePC.Text.Trim() } else { "this PC" }
        $lblSaveToHint.Text =
            if     ($isExtract)   { "" }
            elseif ($isCleanup)   { "Removes staged USMT files only" }
            elseif ($isImport)    { "Not used - pick the store below" }
            else {
                # Kept short - the label is 300px and clips rather than wraps.
                switch ($storeMode) {
                    "Central" { "-> a file server share (UNC)" }
                    "USB"     { "-> a drive on $workPC" }
                    default   { "-> the new PC, as it captures" }
                }
            }
        $lblSaveToHint.ForeColor = $Script:AccentPurple
        $lblSaveToHint.Visible = -not $isExtract

        # ---- Option gating ----
        # Every option is now tied to the operations it can actually affect.
        # Previously five of these stayed enabled for Extract and Clean Up, where
        # they do nothing at all, which made the panel look arbitrary.
        $isMigration = (-not $isExtract) -and (-not $isCleanup)

        # /o applies to ScanState only - LoadState has no equivalent.
        $ovApplies = $isMigration -and ($isExport -or $isCombo)
        $chkOverwrite.Enabled = $ovApplies
        Set-Tip $chkOverwrite $(
            if ($ovApplies) { "Replace an existing store instead of failing (/o)." }
            else            { "Only applies when capturing." })

        # Deleting the store after import needs an import to have happened.
        $delApplies = $isMigration -and ($isImport -or $isCombo)
        $chkCleanup.Enabled = $delApplies
        Set-Tip $chkCleanup $(
            if ($delApplies) { "Delete the store after a successful import." }
            else             { "Import only." })

        # Checking the profile exists means checking the machine being captured.
        $vpApplies = $isMigration -and ($isExport -or $isCombo) -and (-not $isAll) -and (-not $isSettingsOnly)
        $chkVerifyProfile.Enabled = $vpApplies
        Set-Tip $chkVerifyProfile $(
            if ($vpApplies) { "Check the profile folder exists before starting." }
            else            { "Single-profile capture only." })

        $diskApplies = $isMigration
        $chkCheckDisk.Enabled = $diskApplies
        Set-Tip $chkCheckDisk $(
            if ($diskApplies) { "Check free space where the store lands. Warns under $($Script:PreflightMinFreeGB) GB." }
            else              { "Migrations only." })

        $inactApplies = $isMigration -and ($isExport -or $isCombo)
        $chkCheckInactive.Enabled = $inactApplies
        Set-Tip $chkCheckInactive $(
            if ($inactApplies) { "Flag profiles unused for $($Script:PreflightInactiveDays)+ days." }
            else               { "Capture only." })

        # Nothing to measure for a Computer Settings capture - there is no
        # profile involved - and nothing to measure on an import or extract.
        $estApplies = $isMigration -and (-not $isSettingsOnly) -and ($isExport -or $isCombo)
        $chkEstimateSize.Enabled = $estApplies
        Set-Tip $chkEstimateSize $(
            if ($estApplies)         { "Measure the profile and check it fits. Takes seconds." }
            elseif ($isSettingsOnly) { "No profile is captured, so nothing to measure." }
            else                     { "Capture only." })

        # Only a cleanup can remove old stores.
        $chkCleanStores.Enabled = $isCleanup
        Set-Tip $chkCleanStores $(
            if ($isCleanup) { "Also delete finished .mig stores. Each is listed with size and age first." }
            else            { "Clean up only." })

        # Applies to a CAPTURE as well as to Clean Up. A refresh is the moment
        # somebody is actually looking at the old machine and knows which
        # profile mattered; making them run a separate Clean Up afterwards is
        # why the tidying mostly never happened. On a capture it runs only
        # AFTER the store is safely written.
        $cpApplies = $isCleanup -or (($isExport -or $isCombo) -and (-not $isExtract))
        $chkCleanProfiles.Enabled = $cpApplies
        Set-Tip $chkCleanProfiles $(
            if ($isCleanup)     { "Also remove user profiles not used in $($Script:PreflightInactiveDays) days, the way the System Properties dialog does - folder and registry entry together. Signed-in, system and your own profiles are never offered." }
            elseif ($cpApplies) { "After the capture succeeds, offer to remove the OTHER profiles on the source machine that have not been used in $($Script:PreflightInactiveDays) days. The profile you just captured is never included, and nothing is deleted without you ticking it and confirming." }
            else                { "Capture and clean up only." })

        # Runs last: the title reads FieldApplies, which is only correct once
        # everything above has decided which fields this operation uses.
        Update-WindowTitle
        # Same reason - the summary reads FieldApplies too.
        Update-Plan
        # Same reason - the preview reads the same map.
        if ($Script:ExpertVisible) { Update-CommandPreview }

        # Exclude OneDrive only reaches a single-profile ScanState.
        $odApplies = $isMigration -and (-not $isAll) -and (-not $isSettingsOnly) -and ($isExport -or $isCombo)
        $chkExcludeOneDrive.Enabled = $odApplies
        Set-Tip $chkExcludeOneDrive $(
            if ($odApplies) { "Skip the user's OneDrive folders." }
            else            { "Single-profile capture only." })
    }

    $cmbScope.Add_SelectedIndexChanged({
        Update-Fields
        Update-RunButtonColor
    })
    $cmbAction.Add_SelectedIndexChanged({
        # Choosing Export + Import while a drive is selected moves the store to
        # the new PC. Silently - the drive option greys out in the same instant,
        # which shows why far better than a line of text, and the operation the
        # operator just asked for is left alone.
        if ($cmbAction.SelectedIndex -eq $Script:ActionComboIndex `
            -and $cmbSaveTo.SelectedIndex -eq $Script:SaveToDriveIndex) {
            $Script:FixingSaveTo = $true
            try { $cmbSaveTo.SelectedIndex = $Script:SaveToDirectIndex } finally { $Script:FixingSaveTo = $false }
        }
        Update-Fields
        Update-RunButtonColor
    })
    $cmbSaveTo.Add_SelectedIndexChanged({
        # A greyed item is still reachable by keyboard and a ComboBox has no way
        # to refuse a selection, so it is taken back here. This is the ONLY place
        # that explains itself, because it is the only one where the operator
        # asked for something and did not get it.
        if ((-not $Script:FixingSaveTo) -and $Script:DriveOptionDisabled `
            -and $cmbSaveTo.SelectedIndex -eq $Script:SaveToDriveIndex) {
            $Script:FixingSaveTo = $true
            try { $cmbSaveTo.SelectedIndex = $Script:SaveToDirectIndex } finally { $Script:FixingSaveTo = $false }
            # Cyan, not the warning orange. Nothing has gone wrong here - the
            # operator asked for a combination that does not exist and is being
            # told what to do instead. Orange is reserved for things that did
            # go wrong, and spending it on a reminder devalues it.
            Append-Output "You can't do Export + Import with an external drive - use Export, move the drive, then Import on the new PC." $Script:AccentCyan
        }
        Update-Fields
        Update-RunButtonColor
    })

    # ---- Expert mode wiring ----
    # Only the Expert radio needs a handler: the pair is mutually exclusive, so
    # selecting Simple fires this with Checked=$false and closes the panel.
    $Script:ModeSyncing = $false
    $rbExpert.Add_CheckedChanged({
        if ($Script:ModeSyncing) { return }
        # The radio is the state; the header button and the View menu are views
        # of it. Whichever of the three the operator used, they all end up here.
        Sync-ModeToggle
        if ($rbExpert.Checked) {
            Set-ExpertPanel $true
            Update-CommandPreview -Force
            return
        }

        # Leaving Expert with edits pending. Hiding the panel does NOT undo
        # them - the edited command would still be the one that runs, with
        # nothing on screen saying so. That is the worst of both modes, so the
        # choice is made here rather than left to be discovered later.
        if ($Script:CmdEdited) {
            $pick = Show-ChoiceDialog -Title "Switch to Simple" -Glyph $Script:WarningSign `
                -Heading "You have edited the command" `
                -Message "Simple mode hides the Command panel but does not undo your edits. Decide what the next run should use." `
                -Choices @(
                    @{ Key = "Discard"; Text = "Discard my edits, use the options"; Accent = $Script:AccentTeal
                       Hint = "The command goes back to whatever the options above produce. Any custom switches you added are dropped." }
                    @{ Key = "Keep";    Text = "Keep my edited command"
                       Hint = "The edited command still runs. The title bar will say 'custom command' so it is not invisible." }
                    @{ Key = "Stay";    Text = "Stay in Expert mode"; IsCancel = $true
                       Hint = "Go back to the panel without deciding." }
                )
            if ($pick -eq "Stay") {
                $Script:ModeSyncing = $true
                try { $rbExpert.Checked = $true } finally { $Script:ModeSyncing = $false }
                return
            }
            if ($pick -eq "Discard") {
                $Script:ExtraExport = @(); $Script:ExtraImport = @()
                $Script:CmdEdited = $false
                Update-CommandPreview -Force
                Append-Output "Command edits discarded - the options above decide the run again." $Script:T.TextDim
            } else {
                Append-Output "$($Script:WarningSign) Your edited command is still in use, even in Simple mode." $Script:T.Warning
            }
        }
        Set-ExpertPanel $false
        Update-WindowTitle
    })
    Set-Tip $rbSimple "The everyday view: choose an operation, fill in the machines, run it."
    Set-Tip $rbExpert "Adds a panel showing the exact USMT command about to run, which you can edit, plus the OneDrive detection settings."

    # Every edit re-reads the panel. TextChanged rather than Leave so the
    # checkboxes move as the text is typed, which is what makes the link between
    # the two visible rather than something you have to discover.
    $txtCommand.Add_TextChanged({ Read-CommandPanel })
    Set-Tip $txtCommand "The command that will run. Editing /o or the OneDrive XML moves the matching option above. Other USMT switches are kept as typed - see Microsoft's ScanState and LoadState reference for the full list."

    $btnCmdRevert.Add_Click({
        # Throws away edits AND the custom arguments, which is the only honest
        # meaning of "regenerate" - keeping them would leave the box showing
        # something that was neither generated nor typed.
        $Script:ExtraExport = @(); $Script:ExtraImport = @()
        $Script:CmdEdited = $false
        Update-CommandPreview -Force
    })
    Set-Tip $btnCmdRevert "Rebuild the command from the options above, discarding your edits."

    $btnCmdCopy.Add_Click({
        try { [System.Windows.Forms.Clipboard]::SetText($txtCommand.Text); $lblExpertState.Text = "copied to the clipboard" }
        catch { Write-CrashLog "Clipboard copy failed: $($_.Exception.Message)" }
    })
    Set-Tip $btnCmdCopy "Copy the command so you can run or keep it outside UTW."

    $btnCmdPaste.Add_Click({
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) {
                $lblExpertState.Text = "nothing on the clipboard to paste"
                $lblExpertState.ForeColor = $Script:T.Warning
                return
            }
            $txt = [System.Windows.Forms.Clipboard]::GetText()
            if ([string]::IsNullOrWhiteSpace($txt)) {
                $lblExpertState.Text = "the clipboard is empty"
                $lblExpertState.ForeColor = $Script:T.Warning
                return
            }
            # Replaces the whole panel rather than inserting at the caret: what
            # people paste here is a command they had somewhere else, not a
            # fragment. Ctrl+V still does the ordinary caret insert.
            $txtCommand.Text = $txt.TrimEnd()   # TextChanged re-parses it
            $txtCommand.Focus()
        } catch {
            Write-CrashLog "Clipboard paste failed: $($_.Exception.Message)"
            $lblExpertState.Text = "could not read the clipboard"
            $lblExpertState.ForeColor = $Script:T.Error
        }
    })
    Set-Tip $btnCmdPaste "Replace the panel with a command from the clipboard. The options above follow whatever you paste. Ctrl+V still inserts at the cursor."

    # There is no "Log folder..." button any more. It was an invisible control
    # in the stash panel with a live handler nothing could reach - File >
    # Settings > Log folder now has a Browse button and the same
    # proved-writable check, which is one home for it instead of two.
    $btnPickUser.Add_Click({
        # Whichever machine the capture will read - so the list is the list that
        # matters, not this workstation's.
        $pc = Get-ActiveText "SourcePC" $txtSourcePC
        if (-not $pc) { $pc = $env:COMPUTERNAME }
        if (-not (Test-ValidComputerName $pc)) {
            Show-ThemedMessage "'$pc' is not a valid computer name." "Choose a user" "OK" "Warning"; return
        }
        $lblStatus.Text = "Listing profiles on $pc..."; $lblStatus.ForeColor = $Script:AccentCyan
        [System.Windows.Forms.Application]::DoEvents()
        # Same threshold as everywhere else, so the picker agrees with the panel
        # behind it about which profiles are stale.
        $r = Get-RemoteUserProfiles -ComputerName $pc -InactiveDays $Script:PreflightInactiveDays
        $lblStatus.Text = "Ready"; $lblStatus.ForeColor = $Script:T.TextDim
        if (-not $r.Ok) {
            Write-UTWError -What "could not list the profiles on $pc" -Detail $r.Error `
                -Try "Check the machine is on and that you are an administrator on it."
            Show-ThemedMessage "Could not list profiles on ${pc}:`n`n$($r.Error)" "Choose a user" "OK" "Warning"
            return
        }
        $usable = @($r.Profiles | Where-Object { $_.Migratable })
        if ($usable.Count -eq 0) {
            Show-ThemedMessage "No user profiles found on $pc.`n`nOnly system profiles are present." "Choose a user" "OK" "Information"
            return
        }
        $picked = Show-UserPicker -Profiles $usable -ComputerName $pc -Multi -Preselect (Get-UsernameList)
        if ($picked -and @($picked).Count -gt 0) {
            $sel = @($picked)
            $txtUsername.Text = (($sel | ForEach-Object { $_.Leaf }) -join ", ")
            # The account name carries the domain when it resolved, which saves
            # the operator working out whether this is a domain or local user.
            # Only taken from the first - they are almost always the same domain,
            # and a mixed selection is better handled per name in the box.
            if ($sel[0].Account -match '^([^\\]+)\\') { $txtDomain.Text = $Matches[1] }
            foreach ($p in $sel) { Append-Output "Selected $($p.Account) on $pc (profile $($p.Path))" $Script:AccentCyan }
            Update-Fields
        }
    })
    Set-Tip $btnPickUser "List the profiles on the machine being captured and tick the ones to migrate. Several can be captured in one run."

    $btnFindSrc.Add_Click({
        $n = Show-ComputerSearch -Seed $txtSourcePC.Text.Trim()
        if ($n) { $txtSourcePC.Text = $n; Update-Fields }
    })
    # ---- The right-hand list ----
    $Script:BrowseMode = ""
    $btnListUsers.Add_Click({ Show-BrowseUsers })
    $btnListStores.Add_Click({ Show-BrowseStores })
    Set-Tip $btnListUsers  "Show the user profiles on the machine being captured."
    Set-Tip $btnListStores "Show the migration stores this operation would read or write."
    # Use-or-add, as two separate gestures.
    #
    # Double-click used to APPEND, so clicking three users in a row while trying
    # to correct a mistake silently built "bob, jane, pete" and captured all
    # three. Picking one user is the overwhelmingly common case and picking
    # several is the rare one, so the plain gesture now REPLACES and the rare
    # one has its own explicit menu entry that says "add".
    function Use-BrowsedUser {
        param($tag, [switch]$Add)
        if ($Add) {
            $have = @(Get-UsernameList)
            if ($have -notcontains $tag.Leaf) { $have += $tag.Leaf }
            $txtUsername.Text = ($have -join ", ")
            Append-Output "Added $($tag.Account) - capturing $(@(Get-UsernameList).Count) profile(s)." $Script:AccentCyan
        } else {
            $txtUsername.Text = $tag.Leaf
            Append-Output "Selected $($tag.Account)" $Script:AccentCyan
        }
        if ($tag.Account -match '^([^\\]+)\\') { $txtDomain.Text = $Matches[1] }
    }

    <#
        DELETING A PROFILE FROM THE LOOKUP LIST.

        Clean Up already deletes profiles, but only as part of tidying up after
        a migration, and only from a tick list built for that job. The list on
        screen is where somebody actually LOOKS at a machine and finds the
        profile of a person who left two years ago - and having to go somewhere
        else to act on it is how those profiles stay there.

        The rules are not re-implemented here. Remove-RemoteUserProfile re-reads
        the live object and refuses built-in, special and signed-in profiles by
        itself, which matters because the list on screen was built minutes ago
        and someone can sign in during the confirmation. This function's whole
        job is to make sure the operator meant it.
    #>
    $Script:BrowseDeleteProfile = {
        if ($Script:BrowseMode -ne "Users") { return }
        if ($lvBrowse.SelectedItems.Count -eq 0) { return }
        $p = $lvBrowse.SelectedItems[0].Tag
        if (-not $p) { return }

        # The dates are named for what they are. This dialog deletes somebody's
        # documents on the strength of them, so it does not get to call a hive
        # write time a last-used date.
        $age  = "$(Format-ProfileDate $p.LastUse)  ($(Format-ProfileAge $p.AgeDays))"
        $made = "$(Format-ProfileDate $p.Created)  ($(Format-ProfileAge $p.CreatedDays))"
        $who = if ($p.Orphan) {
            "$($p.Leaf) - the account for this profile could not be found, so it looks deleted."
        } else {
            "$($p.Account)"
        }
        $msg = @"
Delete this profile from $($p.PC)?

    Profile:        $who
    Folder:         $($p.Path)
    Last modified:  $age  (registry hive, not a sign-in record)
    First created:  $made

This deletes the whole profile - documents, desktop, favourites and
settings - and its registry entry. It cannot be undone, and there is no
copy unless one has already been captured.

If this person's files are still needed, close this and export the
profile first.
"@
        $answer = Show-ThemedMessage $msg "Delete Profile" "YesNo" "Warning"
        if ($answer -ne "Yes") { return }

        # A SECOND CONFIRMATION WHEN THE ACCOUNT IS STILL REAL.
        #
        # An orphan is an easy call - there is nobody left to sign in. A profile
        # whose account still exists is somebody's working machine, and a single
        # Yes is one slip away from deleting their desktop, so it is asked twice
        # and the second question is the blunt one.
        if (-not $p.Orphan) {
            $again = Show-ThemedMessage @"
$($p.Account) is a real account that still exists.

Deleting this profile does not delete the account - the person can still
sign in, and will get a brand new empty profile with none of their files,
shortcuts or settings.

Are you certain this is the right machine and the right person?
"@ "Delete Profile - Are You Sure" "YesNo" "Warning"
            if ($again -ne "Yes") {
                Append-Output "Profile deletion cancelled." $Script:T.TextDim
                return
            }
        }

        $lblBrowseHint.Text = "Deleting $($p.Leaf) on $($p.PC)..."
        [System.Windows.Forms.Application]::DoEvents()
        $r = Remove-RemoteUserProfile -ComputerName $p.PC -SID $p.SID
        if ($r.Ok) {
            Append-Output "Deleted profile $($p.PC)\$($p.Leaf)  ($($p.Path))" $Script:T.Success
        } else {
            Append-Output "Could not delete $($p.PC)\$($p.Leaf) - $($r.Error)" $Script:T.Error
            Show-ThemedMessage "The profile was not deleted.`r`n`r`n$($r.Error)" "Delete Profile" "OK" "Warning"
        }
        Show-BrowseUsers
    }

    $ctxBrowse = New-Object System.Windows.Forms.ContextMenuStrip
    $ctxBrowse.BackColor = $t.GroupBg; $ctxBrowse.ForeColor = $t.Text
    if ($Script:MenuRendererAvailable) {
        $ctxBrowse.RenderMode = "Professional"
        $ctxBrowse.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer (New-Object UTWMenuColors)
    }
    $miBrowseUse = New-Object System.Windows.Forms.ToolStripMenuItem("&Select")
    $miBrowseUse.Add_Click({ & $Script:BrowseActivate $false })
    $miBrowseAdd = New-Object System.Windows.Forms.ToolStripMenuItem("&Add to the list of users")
    $miBrowseAdd.Add_Click({ & $Script:BrowseActivate $true })
    $miBrowseRefresh = New-Object System.Windows.Forms.ToolStripMenuItem("&Refresh")
    $miBrowseRefresh.Add_Click({
        if     ($Script:BrowseMode -eq "Users")  { Show-BrowseUsers }
        elseif ($Script:BrowseMode -eq "Stores") { Show-BrowseStores }
    })
    $miBrowseDelete = New-Object System.Windows.Forms.ToolStripMenuItem("&Delete this profile...")
    $miBrowseDelete.Add_Click({ & $Script:BrowseDeleteProfile })
    foreach ($mi in @($miBrowseUse, $miBrowseAdd)) { $mi.BackColor = $t.GroupBg; $mi.ForeColor = $t.Text; [void]$ctxBrowse.Items.Add($mi) }
    [void]$ctxBrowse.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miBrowseRefresh.BackColor = $t.GroupBg; $miBrowseRefresh.ForeColor = $t.Text
    [void]$ctxBrowse.Items.Add($miBrowseRefresh)
    # Destructive, so it sits below a separator, away from the two items an
    # operator clicks all day, and it is the one red thing in the menu.
    [void]$ctxBrowse.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miBrowseDelete.BackColor = $t.GroupBg; $miBrowseDelete.ForeColor = $t.Error
    [void]$ctxBrowse.Items.Add($miBrowseDelete)
    # "Add to the list" only means anything for users - a store is one store.
    $ctxBrowse.Add_Opening({
        $has = ($lvBrowse.SelectedItems.Count -gt 0)
        $miBrowseUse.Text = if ($Script:BrowseMode -eq "Users") { "&Select profile" } else { "&Select store" }
        $miBrowseUse.Enabled = $has
        $miBrowseAdd.Visible = ($Script:BrowseMode -eq "Users")
        $miBrowseAdd.Enabled = $has -and ($Script:BrowseMode -eq "Users")
        $miBrowseRefresh.Enabled = [bool]$Script:BrowseMode
        # Only for users, and only for a row - there is nothing to delete
        # otherwise, and a live-looking Delete with no target is a trap.
        $miBrowseDelete.Visible = ($Script:BrowseMode -eq "Users")
        $miBrowseDelete.Enabled = $has -and ($Script:BrowseMode -eq "Users")
    })
    $lvBrowse.ContextMenuStrip = $ctxBrowse
    $Script:ThemedStrips = @($Script:ThemedStrips) + @($ctxBrowse)

    # Right-clicking a row does not select it in a ListView, so the menu is
    # pointed at whatever is under the pointer before it opens.
    $lvBrowse.Add_MouseDown({
        param($mdSender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $lvBrowse.GetItemAt($e.X, $e.Y)
        if ($hit) { $lvBrowse.SelectedItems.Clear(); $hit.Selected = $true }
    })

    $Script:BrowseActivate = {
        param([bool]$Add)
        if ($lvBrowse.SelectedItems.Count -eq 0) { return }
        $tag = $lvBrowse.SelectedItems[0].Tag
        if ($Script:BrowseMode -eq "Users") {
            Use-BrowsedUser -tag $tag -Add:$Add
        } elseif ($Script:BrowseMode -eq "Stores") {
            $txtImportStore.Text = $tag.Path
            if ($tag.Username -and $tag.Username -ne $tag.Name) { $txtUsername.Text = $tag.Username }
            Append-Output "Store selected: $($tag.Path)" $Script:AccentCyan
            if ($tag.ImportedOn) {
                Append-Output "$($Script:WarningSign) Already restored on $($tag.ImportedOn) onto $($tag.DestinationComputer)." $Script:T.Warning
            }
        }
        Update-Fields
    }
    # The plain gesture is "use this one", i.e. replace.
    $lvBrowse.Add_DoubleClick({ & $Script:BrowseActivate $false })

    # The summary quotes the machine names and the store path, so it has to
    # follow what is typed rather than only what is chosen from a list.
    foreach ($box in @($txtSourcePC, $txtNewPC, $txtUsername, $txtDomain, $txtCentralPath, $txtUSBPath, $txtImportStore)) {
        $box.Add_TextChanged({ try { Update-Plan } catch { } })
    }
    Set-Tip $btnFindSrc "Find the machine in Active Directory by name or description, instead of remembering it."
    $btnFindDst.Add_Click({
        $n = Show-ComputerSearch -Seed $txtNewPC.Text.Trim()
        if ($n) { $txtNewPC.Text = $n; Update-Fields }
    })
    Set-Tip $btnFindDst "Find the machine in Active Directory by name or description, instead of remembering it."

    $btnBrowseStoreList.Add_Click({
        # Where to look: whatever is already typed, else the network share if
        # one is configured, else this PC's own store folder.
        $seed = $txtImportStore.Text.Trim()
        $root = if ($seed -and (Test-Path $seed -ErrorAction SilentlyContinue)) { Split-Path $seed -Parent }
                elseif ($txtCentralPath.Text.Trim()) { $txtCentralPath.Text.Trim() }
                else { "C:\$($Script:AppConfig.DefaultStorePath)" }
        $fd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fd.Description = "Which folder holds the stores?"
        if (Test-Path $root -ErrorAction SilentlyContinue) { $fd.SelectedPath = $root }
        if ($fd.ShowDialog($Form) -ne "OK") { return }
        $picked = Show-StoreBrowser -Root $fd.SelectedPath
        if ($picked) {
            $txtImportStore.Text = $picked.Path
            $bits = @()
            if ($picked.Username)       { $bits += "user $($picked.Username)" }
            if ($picked.SourceComputer) { $bits += "from $($picked.SourceComputer)" }
            if ($picked.ExportedOn)     { $bits += "captured $($picked.ExportedOn)" }
            Append-Output "Store selected: $($picked.Path)$(if ($bits.Count) { '  (' + ($bits -join ', ') + ')' })" $Script:AccentCyan
            if ($picked.ImportedOn) {
                Append-Output "$($Script:WarningSign) This store was already restored on $($picked.ImportedOn) onto $($picked.DestinationComputer). Restoring it again will overwrite whatever is there now." $Script:T.Warning
            }
            # The store knows whose profile it holds - use it rather than making
            # the operator retype a name that is recorded right there.
            if ($picked.Username -and $picked.Username -ne $picked.Name) { $txtUsername.Text = $picked.Username }
            Update-Fields
        }
    })
    Set-Tip $btnBrowseStoreList "Browse the stores in a folder, with who each one belongs to and when it was captured."

    # ---- The two destructive options ----
    # Each explains itself at the moment it is ticked, not in a tooltip nobody
    # hovers. Ticking is the decision point; the run only confirms it.
    $chkRenameOnRestore.Add_CheckedChanged({
        $txtRenameTo.Enabled = $chkRenameOnRestore.Checked
        if (-not $chkRenameOnRestore.Checked) { return }
        $pick = Show-ChoiceDialog -Title "Restore under a different account" -Glyph $Script:WarningSign `
            -Heading "This restores the profile onto a DIFFERENT account" `
            -Message ("USMT will apply the captured profile to an account other than the one it came from (/mu).`n`n" +
                      "If that account already exists and is in use, its desktop, documents and settings are overwritten by the captured ones. There is no undo.`n`n" +
                      "Only do this when the user's account name has genuinely changed - a marriage, a rename, a rebuilt account.") `
            -Choices @(
                @{ Key = "Yes"; Text = "I understand - let me set the new name"; Accent = $Script:T.Error
                   Hint = "The box beside the tick becomes editable. Leave it blank and nothing is renamed." }
                @{ Key = "No";  Text = "Cancel"; IsCancel = $true
                   Hint = "Leaves the option off." }
            )
        if ($pick -ne "Yes") {
            $chkRenameOnRestore.Checked = $false
        } else {
            Append-Output "$($Script:WarningSign) Restore-as-different-account is ON. The target account's existing profile will be overwritten." $Script:T.Error
            $txtRenameTo.Focus()
        }
    })
    Set-Tip $chkRenameOnRestore "Restore the captured profile onto a different account name (USMT /mu). Overwrites whatever that account already has."
    Set-Tip $txtRenameTo "The account to restore AS. Blank means no rename."

    $chkDeleteSource.Add_CheckedChanged({
        if (-not $chkDeleteSource.Checked) { return }
        $pick = Show-ChoiceDialog -Title "Delete the profile after capture" -Glyph $Script:WarningSign `
            -Heading "This deletes the user's profile from the old PC" `
            -Message ("As soon as the capture finishes, the profile it captured is removed from the machine it came off - folder and registry entry together.`n`n" +
                      "The store becomes the ONLY copy. If it is later found to be incomplete, or the drive holding it fails, that profile is gone.`n`n" +
                      "UTW refuses the deletion if the store cannot be read back or is suspiciously small, and never touches a profile that is signed in. Those checks are not a substitute for having somewhere else to fall back to.") `
            -Choices @(
                @{ Key = "Yes"; Text = "I understand - delete after a successful capture"; Accent = $Script:T.Error
                   Hint = "You will still be asked to confirm on the run itself." }
                @{ Key = "No";  Text = "Cancel"; IsCancel = $true
                   Hint = "Leaves the option off. The old PC keeps its profile." }
            )
        if ($pick -ne "Yes") {
            $chkDeleteSource.Checked = $false
        } else {
            Append-Output "$($Script:WarningSign) Delete-after-capture is ON. The old PC will lose the profile once the capture succeeds." $Script:T.Error
        }
    })
    Set-Tip $chkDeleteSource "After a successful capture, remove that profile from the machine it came from. The store becomes the only copy."

    Set-Tip $chkODDetect "Look for OneDrive in the profile before a capture and offer to exclude it. Turn off to never be asked."
    Set-Tip $txtODPattern "Which folders count as OneDrive, as a wildcard. Default OneDrive* matches the tenant folder and a personal one. Use <user> for the profile's own name, e.g. `"OneDrive - <user>`"."
    Set-Tip $txtODMin "Only ask when this much OneDrive data is actually held on disk. Cloud-only files count as nothing, so a fully synced-to-cloud profile never prompts. 0 asks whenever a OneDrive folder exists."
    # Retyping the pattern changes what the next check looks for, so say so.
    $txtODPattern.Add_TextChanged({
        $Script:OneDriveFolderPattern = Get-ODPattern
    })
    # The route line and the save-to hint both name machines from these boxes,
    # so they have to be rebuilt as the names are typed, not just when the
    # operation changes.
    $txtSourcePC.Add_TextChanged({ Update-Fields })
    $txtNewPC.Add_TextChanged({ Update-Fields })

    # ---- Tooltips + tab order ----
    # Tab order follows the order you fill the form in, not the order the
    # controls happened to be added to the tree.
    $tips = @(
        @($txtUSMTPath,    "Folder holding scanstate.exe and loadstate.exe."),
        @($btnBrowseUSMT,  "Browse for the USMT folder."),
        @($cmbAction,      "What this run does."),
        @($cmbScope,       "Whose data: one profile, everyone, or machine settings only."),
        @($cmbSaveTo,      "Where the capture writes its .mig store."),
        @($txtCentralPath, "UNC path only. Needs Domain Computers granted Modify."),
        @($txtDomain,      "Domain of the account. * matches any."),
        @($txtUsername,    "User name, without the domain."),
        @($txtNewPC,       "The other machine in this run."),
        @($txtSourcePC,    "PC to capture. Blank = this one."),
        @($txtImportStore, "Type or paste a path, or Browse. Copied to the target PC first if it is not already there."),
        @($btnBrowseImportStore, "Pick the store folder, the USMT folder, or the .MIG itself."),
        @($txtUSBPath,     "Drive on the PC being captured. Type a path or Browse."),
        @($chkOverwrite,   "Replace an existing store instead of failing (/o)."),
        @($chkCleanup,     "Delete the store after a successful import."),
        @($chkCleanStores, "Also delete finished .mig stores. Listed before anything goes."),
        @($chkVerifyProfile,  "Check the profile folder exists first."),
        @($chkCheckDisk,      "Check free space where the store lands."),
        @($chkCheckInactive,  "Flag profiles unused for $($Script:PreflightInactiveDays)+ days."),
        @($btnRun,         "Start."),
        @($btnStop,        "Cancel and tidy up."),
        @($btnOpenLogs,    "Open the log folder in Explorer."),
        @($btnOpenLogs,    "Open the log folder in Explorer.")
    )
    foreach ($pair in $tips) { try { Set-Tip $pair[0] $pair[1] } catch { } }

    $tabOrder = @(
        $txtUSMTPath, $btnBrowseUSMT, $cmbAction, $cmbScope, $cmbSaveTo,
        $txtDomain, $txtUsername, $txtSourcePC, $txtNewPC,
        $txtImportStore, $btnBrowseImportStore,
        $txtCentralPath, $btnBrowseCentral,
        $txtUSBPath, $btnBrowseUSB, $txtMigrationFile, $btnBrowseMig, $txtExtractPath, $btnBrowseExtract,
        $chkOverwrite, $chkCleanup, $chkExcludeOneDrive, $chkCleanStores,
        $chkVerifyProfile, $chkCheckDisk, $chkCheckInactive, $chkEstimateSize,
        $btnRun, $btnStop, $btnOpenLogs
    )
    for ($i = 0; $i -lt $tabOrder.Count; $i++) { try { $tabOrder[$i].TabIndex = $i } catch { } }

    # Update-Stretch calls Update-Fields so Migration Details can re-place
    # itself at the new width. It runs during layout finalisation, before this
    # point, so the flag says when that call is safe to make.
    $Script:FieldsReady = $true
    $Script:PlanReady   = $true
    Update-Fields

    # ---- Runtime state ----
    $Script:CurrentProcess    = $null   # local System.Diagnostics.Process
    $Script:CurrentLogFile    = $null   # detail log path for current local operation
    $Script:CurrentProgressLog = $null  # progress log path for current local operation
    $Script:RemoteSession     = $null   # @{ Task; ProgressUNC; LogFileUNC; StdoutUNC; LocalStoreUNC }
    $Script:RemotePhase       = 0      # 1 = waiting for task, 2 = robocopy in progress
    $Script:RoboProcess       = $null  # robocopy process
    # Log tailing is offset-based and its state lives inside Read-FileTail;
    # Reset-FileTail is called wherever the old per-file line counters were
    # zeroed. Nothing here counts lines any more.
    $Script:PendingImport     = $null  # @{ StorePath; ... } queued after export in combo mode
    # What the CURRENT local run is doing, captured at launch. The fields can be
    # edited while USMT runs, so the completion handler must not read them.
    $Script:LastCapture       = $null  # @{ StorePath; SourcePC; DestPC; Users }
    $Script:LastRestore       = $null  # @{ StorePath; DestPC; RestoredAs }
    $Script:CancelRequested   = $false
    $Script:DirectShare       = $null  # temporary share on the dest PC, torn down when scanstate ends
    $Script:ExportPlan        = $null  # launch parameters, held across the sizing pass
    $Script:OpStartTime       = $null  # wall clock for the whole operation, for the elapsed report

    # How long a remote task may sit without USMT ever writing its detail log
    # before the operator is told something is wrong. scanstate/loadstate open
    # that log within seconds of starting, every time, before any real work - so
    # this cannot false-positive on a slow migration, only catch one that never
    # began (blocked exe, killed by policy, action failed to start).
    $Script:RemoteStartGraceMin = 5

    function Test-RemoteUsmtStarted {
        <#
            Called each tick while a remote task is pending. Returns nothing;
            its job is the one-time "USMT has not started" note. Once the detail
            log exists it records the fact and never speaks again.
        #>
        param($Session, $Status)
        if (-not $Session) { return }
        if ($Session.UsmtStarted) { return }
        # A run that just finished (detected by log markers) is not "not started".
        if ($Status -and $Status.Finished) { $Session.UsmtStarted = $true; return }
        $dUNC = $Session.LogFileUNC
        if ($dUNC -and (Test-Path $dUNC -ErrorAction SilentlyContinue)) {
            $Session.UsmtStarted = $true
            return
        }
        if ($Session.StartWarned) { return }
        $started = $null
        if ($Session.Task) { $started = $Session.Task.Started }
        if (-not $started) { return }
        $mins = ((Get-Date) - $started).TotalMinutes
        if ($mins -lt $Script:RemoteStartGraceMin) { return }
        # Either the task never ran, or it ran and died before opening a log.
        $neverRan = ($Status -and $Status.NotYetRun)
        $Session.StartWarned = $true
        Append-Output ("$($Script:WarningSign) USMT has not started after $([int]$mins) min on $($Session.Task.PC) - " +
            $(if ($neverRan) { "the scheduled task is not running." } else { "no detail log has appeared." })) $Script:T.Warning
        Append-Output ("On $($Session.Task.PC), open C:\Windows\Temp\USMT_Temp - if Logs\ is empty and the stdout log " +
            "shows only the [RunScan]/[RunLoad] banner, scanstate/loadstate launched but stalled (store path, AV, or policy). " +
            "If the stdout log is 0 bytes, the task never executed the batch. Task Scheduler > History on that PC has the reason.") $Script:T.TextDim
        Write-CrashLog "Watchdog: USMT not started after $([int]$mins) min on $($Session.Task.PC) (neverRan=$neverRan)"
    }

    # ---- Timer (polls process/task every 750 ms) ----
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 750

    $timer.Add_Tick({
        # ========================================================
        #  PHASE 5  -  copying a chosen store onto the destination
        #  before LoadState can be run there.
        # ========================================================
        if ($Script:RoboProcess -and $Script:RemotePhase -eq 5) {
            if (-not $Script:RoboProcess.HasExited) { return }
            $rc = $Script:RoboProcess.ExitCode
            $Script:RoboProcess.Dispose(); $Script:RoboProcess = $null
            $Script:RemotePhase = 0
            # robocopy: 0 = nothing to do, 1..7 = copied, 8+ = a real failure
            if ($rc -ge 8) {
                $timer.Stop(); Set-UIRunning $false
                $lblStatus.ForeColor = $Script:T.Error; $lblStatus.Text = "Store copy failed (exit $rc)"
                Append-Output "Could not copy the store to the destination (robocopy exit $rc). Import cancelled." $Script:T.Error
                $Script:PendingImport = $null
                return
            }
            Append-Output "Store copied to the destination." $Script:T.Success
            Start-PendingRemoteImport
            return
        }

        # ========================================================
        #  LOCAL PROCESS  -  standard export/import/extract
        # ========================================================
        if ($Script:CurrentProcess -and -not $Script:CurrentProcess.HasExited) {
            # Tail the PROGRESS log (sparse CSV - phase transitions only)
            # The detail log at /v:13 has 10,000+ lines and would choke the RichTextBox.
            if ($Script:CurrentProgressLog -and (Test-Path $Script:CurrentProgressLog -ErrorAction SilentlyContinue)) {
                $tail = Read-FileTail -FilePath $Script:CurrentProgressLog
                foreach ($line in $tail.Lines) {
                    $friendly = Format-ProgressLine $line
                    if ($friendly) { Append-Output $friendly $Script:T.Text }
                }
            }
            return
        }
        if ($Script:CurrentProcess -and $Script:CurrentProcess.HasExited) {
            $ec = $Script:CurrentProcess.ExitCode
            $Script:CurrentProcess.Dispose(); $Script:CurrentProcess = $null
            Reset-FileTail
            Complete-Operation -ExitCode $ec
            return
        }

        # ========================================================
        #  REMOTE PHASE 1  -  wait for schtasks task to finish
        # ========================================================
        if ($Script:RemoteSession -and $Script:RemotePhase -eq 1) {
            $task = $Script:RemoteSession.Task
            # Tail remote progress log via UNC
            $pUNC = $Script:RemoteSession.ProgressUNC
            if ($pUNC -and (Test-Path $pUNC -ErrorAction SilentlyContinue)) {
                $tail = Read-FileTail -FilePath $pUNC
                foreach ($line in $tail.Lines) {
                    $friendly = Format-ProgressLine $line
                    if ($friendly) { Append-Output $friendly $Script:T.Text }
                }
            }
            # Poll task - pass both progress log AND detail log for triple-method detection
            $status = Get-RemoteTaskStatus -PC $task.PC -TaskName $task.TaskName `
                          -ProgressLogUNC $Script:RemoteSession.ProgressUNC `
                          -DetailLogUNC   $Script:RemoteSession.LogFileUNC
            Test-RemoteUsmtStarted -Session $Script:RemoteSession -Status $status
            if ($status.Finished) {
                $Script:RemotePhase = 0
                Remove-RemoteTask -PC $task.PC -TaskName $task.TaskName
                if ($status.ExitCode -ne 0) {
                    # Dump stdout then the tail of the detail log for full error context
                    Append-Output "--- ScanState stdout ---" $Script:T.Warning
                    $sUNC = $Script:RemoteSession.StdoutUNC
                    if ($sUNC -and (Test-Path $sUNC -ErrorAction SilentlyContinue)) {
                        $lines = Read-SharedFile $sUNC
                        foreach ($l in $lines) { if ($l.Trim()) { Append-Output $l $Script:T.Warning } }
                    }
                    Append-Output "--- Detail log (last 30 lines) ---" $Script:T.Warning
                    $dUNC = $Script:RemoteSession.LogFileUNC
                    if ($dUNC -and (Test-Path $dUNC -ErrorAction SilentlyContinue)) {
                        # Seeks to the end rather than pulling a multi-megabyte
                        # /v:13 log across the wire to show thirty lines of it.
                        foreach ($l in (Read-FileEndLines -FilePath $dUNC -Count 30)) { Append-Output $l.Trim() $Script:T.Warning }
                    }
                    Remove-DestStoreShare $Script:DirectShare; $Script:DirectShare = $null
                    $timer.Stop(); Set-UIRunning $false
                    $lblStatus.ForeColor = $Script:T.Error; $lblStatus.Text = "Remote export failed (exit $($status.ExitCode))"
                    Append-Output "Remote ScanState failed. Full log: $($Script:RemoteSession.LogFileUNC)" $Script:T.Error
                    if ($status.ExitCode -eq 267014) {
                        Append-Output "The scheduled task was terminated - killed manually, or it hit a Task Scheduler time limit. It did not exit on its own." $Script:T.Warning
                    } elseif ($status.ExitCode -eq 267011) {
                        Append-Output "The scheduled task never executed its action. Check Task Scheduler > History on $($task.PC) - AppLocker / WDAC, blocked script execution, or a bad path to the batch file." $Script:T.Warning
                    } else {
                        Write-USMTExit -Code $status.ExitCode -LogPath "$($Script:RemoteSession.LogFileUNC)"
                    }
                    $Script:RemoteSession = $null
                    return
                }
                # ScanState is finished, so the source no longer needs a way in.
                Remove-DestStoreShare $Script:DirectShare; $Script:DirectShare = $null

                if ($Script:RemoteSession.DirectStore) {
                    # The store was written where it belongs as it was captured -
                    # there is nothing on the source to copy anywhere.
                    Append-Output "Store written directly to $($Script:RemoteSession.StorePathUsed) - no transfer step needed." $Script:T.Success
                    Complete-StoreTransfer
                } else {
                    Start-RobocopyPhase
                }
            }
            return
        }

        # ========================================================
        #  REMOTE PHASE 3  -  loadstate running on dest PC
        # ========================================================
        if ($Script:RemoteSession -and $Script:RemotePhase -eq 3) {
            $task = $Script:RemoteSession.Task
            # Tail remote import progress log
            $pUNC = $Script:RemoteSession.ProgressUNC
            if ($pUNC -and (Test-Path $pUNC -ErrorAction SilentlyContinue)) {
                $tail = Read-FileTail -FilePath $pUNC
                foreach ($line in $tail.Lines) {
                    $friendly = Format-ProgressLine $line
                    if ($friendly) { Append-Output $friendly $Script:T.Text }
                }
            }
            # Poll task - pass both progress AND detail log for triple-method detection
            $status = Get-RemoteTaskStatus -PC $task.PC -TaskName $task.TaskName `
                          -ProgressLogUNC $Script:RemoteSession.ProgressUNC `
                          -DetailLogUNC   $Script:RemoteSession.LogFileUNC
            Test-RemoteUsmtStarted -Session $Script:RemoteSession -Status $status
            if ($status.Finished) {
                $Script:RemotePhase = 0
                Remove-RemoteTask -PC $task.PC -TaskName $task.TaskName
                $destPC = $Script:RemoteSession.DestPC
                if ($status.ExitCode -ne 0) {
                    # Dump stdout then tail of detail log so the technician can see the exact failure
                    Append-Output "--- LoadState stdout ---" $Script:T.Warning
                    $sUNC = $Script:RemoteSession.StdoutUNC
                    if ($sUNC -and (Test-Path $sUNC -ErrorAction SilentlyContinue)) {
                        $lines = Read-SharedFile $sUNC
                        foreach ($l in $lines) { if ($l.Trim()) { Append-Output $l $Script:T.Warning } }
                    }
                    Append-Output "--- Detail log (last 40 lines) ---" $Script:T.Warning
                    $dUNC = $Script:RemoteSession.LogFileUNC
                    if ($dUNC -and (Test-Path $dUNC -ErrorAction SilentlyContinue)) {
                        foreach ($l in (Read-FileEndLines -FilePath $dUNC -Count 40)) { Append-Output $l.Trim() $Script:T.Warning }
                    }
                    $timer.Stop(); Set-UIRunning $false
                    $lblStatus.ForeColor = $Script:T.Error; $lblStatus.Text = "Remote import failed (exit $($status.ExitCode))"
                    Append-Output "Remote LoadState failed. Full log: $($Script:RemoteSession.LogFileUNC)" $Script:T.Error
                    if ($status.ExitCode -eq 267014) {
                        Append-Output "The scheduled task was terminated - killed manually, or it hit a Task Scheduler time limit. It did not exit on its own." $Script:T.Warning
                    } elseif ($status.ExitCode -eq 267011) {
                        Append-Output "The scheduled task never executed its action. Check Task Scheduler > History on $($task.PC) - AppLocker / WDAC, blocked script execution, or a bad path to the batch file." $Script:T.Warning
                    } else {
                        Write-USMTExit -Code $status.ExitCode -LogPath "$($Script:RemoteSession.LogFileUNC)"
                    }
                    $Script:RemoteSession = $null; return
                }
                # Success - clean up USMT_Temp and the profile store on dest PC
                $destPC      = $Script:RemoteSession.DestPC
                $destStoreUNC = $Script:RemoteSession.DestStoreUNC
                # Save remote import logs locally before cleanup
                if ($Script:AppConfig.LogFolder) {
                    $remoteLogsUNC = Join-Path (Get-RemoteTempUNC $destPC) "Logs"
                    if (Test-Path $remoteLogsUNC -ErrorAction SilentlyContinue) {
                        try {
                            Copy-Item -Path "$remoteLogsUNC\*" -Destination $Script:AppConfig.LogFolder -Force -ErrorAction SilentlyContinue
                            Append-Output "Remote import logs saved to $($Script:AppConfig.LogFolder)" $Script:T.Text
                        } catch { Append-Output "Could not copy remote logs: $($_.Exception.Message)" $Script:T.Warning }
                    }
                }
                Append-Output "Remote import complete. Cleaning up dest PC ($destPC)..." $Script:AccentCyan
                Remove-RemoteTempFolder -SourcePC $destPC
                # Remove the profile store from dest PC only if "Delete store" is checked
                if ($chkCleanup.Checked -and -not [string]::IsNullOrWhiteSpace($destStoreUNC) -and (Test-Path $destStoreUNC -ErrorAction SilentlyContinue)) {
                    try {
                        # THROUGH THE GUARDED DELETE, not a bare Remove-Item.
                        #
                        # This was a recursive force-delete behind nothing but a
                        # not-blank-and-exists check, while Remove-StoredMigration
                        # - written for this exact target class - re-proves the
                        # path sits inside its store root and still looks like a
                        # USMT store. That matters because the folder name comes
                        # from DefaultStorePath in an operator-editable JSON: set
                        # that to "Users" and this line deleted the profile
                        # LoadState had just finished restoring.
                        #
                        # No -ExpectedRoot: there is no root here that was not
                        # derived from this very path, and passing the path's own
                        # parent makes the containment test vacuously true. What
                        # guards this delete is the location check and the
                        # still-a-USMT-store check inside the function.
                        $delRes = Remove-StoredMigration -Path $destStoreUNC
                        if (-not $delRes.Ok) { throw $delRes.Error }
                        Append-Output "Deleted store from $destPC ($destStoreUNC)" $Script:T.TextDim
                        Write-CrashLog "Deleted dest store: $destStoreUNC"
                        # And the store FOLDER, if that was the last one in it -
                        # through the helper, which proves the leaf is the
                        # configured store folder and that it sits on a drive or
                        # share root, rather than force-deleting whatever the
                        # parent happens to be.
                        $rootRes = Remove-EmptyStoreRoot -Root (Split-Path $destStoreUNC -Parent) `
                                                         -FolderName $Script:AppConfig.DefaultStorePath
                        if ($rootRes.Removed) { Append-Output "Removed empty folder: $(Split-Path $destStoreUNC -Parent)" $Script:T.TextDim }
                    } catch {
                        Append-Output "Store cleanup skipped on $destPC`: $($_.Exception.Message)" $Script:T.Warning
                        Write-CrashLog "Dest store cleanup failed: $($_.Exception.Message)"
                    }
                } elseif (-not $chkCleanup.Checked) {
                    Append-Output "Store kept on $destPC ($destStoreUNC)" $Script:T.TextDim
                }
                $Script:RemoteSession = $null
                $timer.Stop()
                Append-Output "Migration complete! Profile restored on $destPC." $Script:T.Success
                # Store size only if it was kept - cleanup may just have removed it.
                Write-CompletionSummary -StorePath $(if ($chkCleanup.Checked) { "" } else { $destStoreUNC })
                Set-UIRunning $false
                $progressBar.Style = "Continuous"; $progressBar.Value = 100
                $clown = Get-ClownVerdict $true
                $lblProgress.Text = if ($clown) { $clown } else { "100%" }
                $lblStatus.ForeColor = $Script:T.Success; $lblStatus.Text = "$($Script:CheckMark) Migration complete"
            }
            # The one that matters most: a migration is the job somebody walks
            # away from. Flashed whether it succeeded or not - "it finished" is
            # the news, and the log says which.
            Invoke-TaskbarFlash -Form $Form
            return
        }

        # ========================================================
        # ========================================================
        if ($Script:RoboProcess -and $Script:RemotePhase -eq 2) {
            if (-not $Script:RoboProcess.HasExited) { return }
            $rc = $Script:RoboProcess.ExitCode
            $Script:RoboProcess.Dispose(); $Script:RoboProcess = $null
            $Script:RemotePhase = 0
            # robocopy exit codes: 0 = no files copied (ok), 1 = files copied ok, anything 8+ = error
            if ($rc -ge 8) {
                $timer.Stop(); Set-UIRunning $false
                $lblStatus.ForeColor = $Script:T.Error; $lblStatus.Text = "Robocopy failed (exit $rc)"
                Append-Output "Robocopy exited with code $rc  -  store transfer may be incomplete." $Script:T.Error
                $Script:RemoteSession = $null
                $Script:PendingImport = $null   # discard import Ã¢â‚¬â€ store may be corrupt/partial
                return
            }
            Append-Output "Store transferred successfully (robocopy exit $rc)." $Script:T.Success
            Complete-StoreTransfer
        }
    })

    # ---- Closing summary: how long it took, and how big the store is ----
    # Must run BEFORE Set-UIRunning $false, which clears the start time.
    function Write-CompletionSummary {
        param([string]$StorePath = "")
        if ($Script:OpStartTime) {
            Append-Output "Elapsed: $(Format-Duration ((Get-Date) - $Script:OpStartTime))" $Script:AccentCyan
        }
        if ($StorePath) {
            $st = Get-StoreSizeOnDisk -StorePath $StorePath
            if ($st) {
                # USMT never reports the finished store size, so this is the only
                # place the technician can see what the migration actually produced.
                Append-Output "Store size: $($st.Text) in $($st.Files) file(s)" $Script:AccentCyan
            }
        }
    }

    function Complete-CaptureSideEffects {
        <#
            The two things that happen after a capture SUCCEEDS: the store
            records what it holds, and - only if explicitly asked - the profile
            is removed from the machine it came off.

            Order matters. The metadata is written first, so that if the
            deletion then runs, the store already carries the record of what it
            is now the only copy of.
        #>
        param(
            [string]$StorePath,
            [string]$SourcePC,
            [string]$DestPC = "",
            [string[]]$Users = @(),
            # ScanState's log, so each user's deletion can be proved on evidence
            # about THAT user rather than on store-wide evidence that may belong
            # entirely to somebody else in the same run.
            [string]$CaptureLog = ""
        )
        if (-not $StorePath) { return }
        $ok = Write-StoreMetadata -StorePath $StorePath -Facts @{
            Username            = ($Users -join ", ")
            Domain              = $txtDomain.Text.Trim()
            SourceComputer      = $SourcePC
            DestinationComputer = $DestPC
            ExportedBy          = "$env:USERDOMAIN\$env:USERNAME"
            ExportedOn          = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        if ($ok) { Append-Output "Store details recorded." $Script:T.TextDim }

        if (-not $chkDeleteSource.Checked) { return }
        # Confirmed again here, not only when the box was ticked: it may have
        # been ticked before anyone knew which machine or user this run would
        # touch, and by now both are decided.
        $who = ($Users -join ", ")
        $pick = Show-ChoiceDialog -Title "Delete the source profile" -Glyph $Script:WarningSign `
            -Heading "Delete $who from $SourcePC now?" `
            -Message ("The capture succeeded and the store is at:`n  $StorePath`n`n" +
                      "Deleting the profile makes that store the only copy of it.") `
            -Choices @(
                @{ Key = "Do";   Text = "Delete the profile from $SourcePC"; Accent = $Script:T.Error
                   Hint = "Folder and registry entry together. Refused automatically if the store does not read back." }
                @{ Key = "Keep"; Text = "Keep it for now"; IsCancel = $true
                   Hint = "The old PC keeps the profile. You can clean it up later." }
            )
        if ($pick -ne "Do") { Append-Output "Source profile kept on $SourcePC." $Script:T.TextDim; return }

        foreach ($u in $Users) {
            $r = Remove-SourceProfileAfterCapture -ComputerName $SourcePC -Username $u -StorePath $StorePath -CaptureLog $CaptureLog
            if ($r.Ok)          { Append-Output "Deleted $u from $SourcePC ($($r.Path))" $Script:T.Success }
            elseif ($r.Skipped) { Append-Output "$($Script:WarningSign) Did not delete $u from ${SourcePC}: $($r.Error)" $Script:T.Warning }
            else                { Append-Output "Could not delete $u from ${SourcePC}: $($r.Error)" $Script:T.Error }
        }
    }

    function Complete-CapturePost {
        <#
            Everything that happens after a capture, in one place, so the local
            route and the remote route cannot drift apart: record the store,
            optionally delete the captured profile, then optionally offer to
            tidy up the stale profiles left on the same machine.

            Order is deliberate - the store is written and recorded BEFORE
            anything is deleted from the source.
        #>
        param([string]$StorePath, [string]$SourcePC, [string]$DestPC = "", [string[]]$Users = @(), [string]$CaptureLog = "")
        Complete-CaptureSideEffects -StorePath $StorePath -SourcePC $SourcePC -DestPC $DestPC -Users $Users -CaptureLog $CaptureLog
        try { Invoke-StaleProfileSweep -ComputerName $SourcePC -JustCaptured $Users -StorePath $StorePath }
        catch { Write-CrashLog "Stale profile sweep failed: $($_.Exception.Message)" }
    }

    function Invoke-StaleProfileSweep {
        <#
            Offers to remove stale profiles from a machine after a capture.

            This used to be reachable only from Clean Up, which had the tidying
            in the wrong place: a refresh IS the moment somebody is looking at
            the old machine, and it is the moment they know which profile
            mattered. Making them run a second, separate operation afterwards
            meant it mostly never happened.

            Same two-step confirmation as Clean Up - the picker chooses, the
            dialog after it reads back exactly what was ticked - and the same
            refusals: signed-in, system and just-captured profiles are never
            offered. Nothing here can run without the operator ticking the
            option AND choosing rows AND confirming.
        #>
        param([string]$ComputerName, [string[]]$JustCaptured = @(), [string]$StorePath = "")
        if (-not $chkCleanProfiles.Checked) { return }
        $pc = if ($ComputerName) { $ComputerName } else { $env:COMPUTERNAME }
        $lblStatus.Text = "Looking for stale user profiles on $pc..."; $lblStatus.ForeColor = $Script:AccentCyan
        [System.Windows.Forms.Application]::DoEvents()

        $pr = Get-RemoteUserProfiles -ComputerName $pc -InactiveDays $Script:PreflightInactiveDays
        if (-not $pr.Ok) {
            Append-Output "$pc : could not read user profiles - $($pr.Error)" $Script:T.Warning
            return
        }
        # The profile this run just captured is deliberately excluded. Removing
        # it here is a different decision with its own option and its own
        # confirmation ("Delete the profile from the old PC after a successful
        # capture"), and it must not arrive as a side effect of tidying up.
        $skip = @($JustCaptured | ForEach-Object { "$_".Trim().ToLower() } | Where-Object { $_ })
        $canGo = @($pr.Profiles | Where-Object { $_.Removable -and ($skip -notcontains $_.Leaf.ToLower()) })
        $kept  = @($pr.Profiles | Where-Object { -not $_.Removable })
        if ($canGo.Count -eq 0) {
            Append-Output "$pc : no profiles unused for $($Script:PreflightInactiveDays)+ days to remove." $Script:T.TextDim
            return
        }
        Append-Output "$pc : $($canGo.Count) profile(s) unused for $($Script:PreflightInactiveDays)+ days." $Script:AccentCyan
        foreach ($c in $canGo) {
            Append-Output ("  {0}  last modified {1}{2}" -f $c.Leaf, "$(Format-ProfileDate $c.LastUse) ($(Format-ProfileAge $c.AgeDays))", $(if ($c.Orphan) { "  - no account left" } else { "" })) $Script:T.Text
        }

        $chosen = Show-ProfilePicker -Removable $canGo -Blocked $kept
        if ($null -eq $chosen -or $chosen.Count -eq 0) {
            Append-Output "No profiles removed from $pc." $Script:T.TextDim
            return
        }
        $body = $(if ($StorePath) { "The capture finished and its store is at:`n  $StorePath`n`n" } else { "" }) +
                "About to permanently delete $($chosen.Count) OTHER user profile$(if ($chosen.Count -ne 1) { 's' }) from $pc - documents, desktop and settings - and the registry entry for each:`n`n" +
                (($chosen | ForEach-Object { "  $($_.Leaf)   last modified $(Format-ProfileDate $_.LastUse) ($(Format-ProfileAge $_.AgeDays))$(if ($_.Orphan) { `"   NO ACCOUNT LEFT`" } else { `"`" })   $($_.Path)" }) -join "`n") +
                "`n`nThese were NOT captured by this run. Nothing here is backed up anywhere."
        $pick = Show-ChoiceDialog -Title "Remove stale profiles" -Glyph $Script:WarningSign `
                    -Heading "Delete these $($chosen.Count) stale profile$(if ($chosen.Count -ne 1) { 's' }) from $pc?" `
                    -Message $body -Choices @(
            @{ Key = "Do";   Text = "Yes, delete them"; Accent = $Script:T.Error
               Hint = "Folder and registry entry together, the way System Properties does it." }
            @{ Key = "Back"; Text = "No, leave them alone"; IsCancel = $true
               Hint = "The machine keeps every profile. The capture is unaffected either way." }
        )
        if ($pick -ne "Do") { Append-Output "Stale profiles kept on $pc." $Script:T.TextDim; return }

        foreach ($prof in $chosen) {
            $lblStatus.Text = "Deleting profile $($prof.Leaf) on $pc..."
            [System.Windows.Forms.Application]::DoEvents()
            $r = Remove-RemoteUserProfile -ComputerName $pc -SID $prof.SID
            if ($r.Ok) { Append-Output "Deleted profile $pc\$($prof.Leaf)  ($($prof.Path))" $Script:T.Success }
            else       { Append-Output "Could not delete $pc\$($prof.Leaf) - $($r.Error)" $Script:T.Error }
        }
    }

    # ---- Everything that happens once the store is where it needs to be ----
    # Shared by both routes: the direct write reaches this straight from the
    # ScanState task, the staged one after robocopy.
    function Complete-StoreTransfer {
            $dStorePath = $Script:RemoteSession.DestStorePath
            Drop-CompletionFlag -StorePath $dStorePath -Username $Script:RemoteSession.Username `
                -SourceComputer $Script:RemoteSession.Task.PC -TargetComputer $Script:RemoteSession.DestPC | Out-Null
            Complete-CapturePost -StorePath $dStorePath -SourcePC $Script:RemoteSession.Task.PC `
                -DestPC "$($Script:RemoteSession.DestPC)" `
                -Users $(if ($Script:ExportPlan -and $Script:ExportPlan.MultiUser) { $Script:ExportPlan.Usernames }
                         else { @($Script:RemoteSession.Username) }) `
                -CaptureLog "$($Script:RemoteSession.LogFileUNC)"
            # Clean up source PC temp folder (contains the store that was just copied)
            # First, save the remote logs locally so they survive the cleanup
            if ($Script:AppConfig.LogFolder) {
                $remoteLogsUNC = Join-Path (Get-RemoteTempUNC $Script:RemoteSession.Task.PC) "Logs"
                if (Test-Path $remoteLogsUNC -ErrorAction SilentlyContinue) {
                    try {
                        Copy-Item -Path "$remoteLogsUNC\*" -Destination $Script:AppConfig.LogFolder -Force -ErrorAction SilentlyContinue
                        Append-Output "Remote logs saved to $($Script:AppConfig.LogFolder)" $Script:T.Text
                    } catch { Append-Output "Could not copy remote logs: $($_.Exception.Message)" $Script:T.Warning }
                }
            }
            Append-Output "Cleaning up source PC ($($Script:RemoteSession.Task.PC))..." $Script:AccentCyan
            $lblStatus.Text = "Cleaning up $($Script:RemoteSession.Task.PC)..."; $lblStatus.ForeColor = $Script:T.Primary
            [System.Windows.Forms.Application]::DoEvents()
            Remove-RemoteTempFolder -SourcePC $Script:RemoteSession.Task.PC
            Append-Output "Source PC clean." $Script:T.Success
            $sess = $Script:RemoteSession; $Script:RemoteSession = $null
            # Queue import if combo
            if ($Script:PendingImport) {
                $imp = $Script:PendingImport; $Script:PendingImport = $null
                if ($imp.IsRemote) {
                    # Remote import: run loadstate via schtasks on dest PC
                    Append-Output "Staging USMT tools on $($imp.DestPC) for import..." $Script:AccentCyan
                    $lblStatus.Text = "Staging tools on $($imp.DestPC)..."; $lblStatus.ForeColor = $Script:T.Primary
                    [System.Windows.Forms.Application]::DoEvents()
                    try {
                        $importSess = Invoke-RemoteImport -DestPC $imp.DestPC -LocalUSMTPath $imp.USMTPath `
                            -RemoteStorePath $imp.StorePath -DestStoreUNC $imp.StoreUNC `
                            -Username $imp.Username `
                            -AllProfiles $imp.AllProfiles -Verbosity $imp.Verbosity `
                            -SettingsOnly $(if ($imp.SettingsOnly) { $true } else { $false }) `
                            -Extra $Script:ExtraImport -ArgOverride (Get-CommandOverride "Import") -Usernames @($imp.Usernames) `
                            -RenameFrom "$($imp.RenameFrom)" -RenameTo "$($imp.RenameTo)"
                        $Script:RemoteSession     = $importSess
                        $Script:RemotePhase       = 3
                        Reset-FileTail
                        $lblStatus.Text = "Remote LoadState running on $($imp.DestPC)..."; $lblStatus.ForeColor = $Script:T.Primary
                        Append-Output "Scheduled import task started on $($imp.DestPC). Monitoring..." $Script:T.Success
                        Append-Output "Tailing: $($importSess.ProgressUNC)" $Script:T.TextDim
                    } catch {
                        $timer.Stop(); Set-UIRunning $false
                        $lblStatus.ForeColor = $Script:T.Error; $lblStatus.Text = "Remote import setup failed"
                        Append-Output "Remote import setup error: $($_.Exception.Message)" $Script:T.Error
                    }
                } else {
                    # Local import
                    Append-Output "Starting import phase..." $Script:T.Primary
                    Start-LocalOperation $imp
                }
            } else {
                $timer.Stop()
                Append-Output "All done. Store is at $($sess.DestStorePath)" $Script:T.Success
                Write-CompletionSummary -StorePath $sess.DestStorePath
                Set-UIRunning $false
                $lblStatus.ForeColor = $Script:T.Success; $lblStatus.Text = "$($Script:CheckMark) Remote export complete"
            }
    }

    # ---- Import: get the store onto the destination, then run LoadState ----
    function Start-ImportCopyPhase {
        param([string]$SourceStore, [string]$DestUNC)
        Append-Output "Copying store to $DestUNC ..." $Script:AccentCyan
        $lblStatus.Text = "Copying store to the destination..."; $lblStatus.ForeColor = $Script:AccentCyan
        [System.Windows.Forms.Application]::DoEvents()
        try {
            if (-not (Test-Path $DestUNC)) { New-Item -Path $DestUNC -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        } catch {
            Set-UIRunning $false; $Script:PendingImport = $null
            Show-ThemedMessage "Could not create the store folder on the destination:`n$DestUNC`n`n$($_.Exception.Message)" "Remote Error" "OK" "Error"
            return
        }
        $rp = New-Object System.Diagnostics.ProcessStartInfo
        $rp.FileName               = "robocopy.exe"
        $rp.Arguments              = "`"$SourceStore`" `"$DestUNC`" /E /R:2 /W:3 /NP"
        $rp.UseShellExecute        = $false
        $rp.CreateNoWindow         = $true
        $rp.RedirectStandardOutput = $false
        $rp.RedirectStandardError  = $false
        try {
            $Script:RoboProcess = [System.Diagnostics.Process]::Start($rp)
            $Script:RemotePhase = 5
            $timer.Start()
        } catch {
            Set-UIRunning $false; $Script:PendingImport = $null; $Script:RemotePhase = 0
            Append-Output "Could not start the copy: $($_.Exception.Message)" $Script:T.Error
        }
    }

    # Shared by "already on the destination" and "copied there just now".
    function Start-PendingRemoteImport {
        $imp = $Script:PendingImport; $Script:PendingImport = $null
        if (-not $imp) { return }
        Append-Output "Staging USMT tools on $($imp.DestPC) for import..." $Script:AccentCyan
        $lblStatus.Text = "Staging tools on $($imp.DestPC)..."; $lblStatus.ForeColor = $Script:T.Primary
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $importSess = Invoke-RemoteImport -DestPC $imp.DestPC -LocalUSMTPath $imp.USMTPath `
                -RemoteStorePath $imp.StorePath -DestStoreUNC $imp.StoreUNC `
                -Username $imp.Username -AllProfiles $imp.AllProfiles -Verbosity $imp.Verbosity `
                -SettingsOnly $(if ($imp.SettingsOnly) { $true } else { $false }) `
                -Extra $Script:ExtraImport -ArgOverride (Get-CommandOverride "Import") -Usernames @($imp.Usernames) `
                -RenameFrom "$($imp.RenameFrom)" -RenameTo "$($imp.RenameTo)"
            $Script:RemoteSession     = $importSess
            $Script:RemotePhase       = 3
            Reset-FileTail
            $lblStatus.Text = "Remote LoadState running on $($imp.DestPC)..."; $lblStatus.ForeColor = $Script:T.Primary
            Append-Output "Scheduled import task started on $($imp.DestPC). Monitoring..." $Script:T.Success
            Append-Output "Tailing: $($importSess.ProgressUNC)" $Script:T.TextDim
            $timer.Start()
        } catch {
            $timer.Stop(); Set-UIRunning $false; $Script:RemotePhase = 0
            $lblStatus.ForeColor = $Script:T.Error; $lblStatus.Text = "Remote import setup failed"
            Append-Output "Remote import setup error: $($_.Exception.Message)" $Script:T.Error
        }
    }

    # ---- Start robocopy phase (called when schtasks task finishes) ----
    function Start-RobocopyPhase {
        $srcUNC  = $Script:RemoteSession.LocalStoreUNC   # \\SourcePC\C$\Windows\Temp\USMT_Temp\Store
        $destUNC = $Script:RemoteSession.DestStorePath    # \\DestPC\C$\USMT Profiles\user
        Append-Output "Transferring store from $srcUNC to $destUNC..." $Script:AccentCyan
        $lblStatus.Text = "Transferring store..."; $lblStatus.ForeColor = $Script:AccentCyan
        if (-not (Test-Path $destUNC)) { New-Item -Path $destUNC -ItemType Directory -Force | Out-Null }
        $rp = New-Object System.Diagnostics.ProcessStartInfo
        $rp.FileName               = "robocopy.exe"
        $rp.Arguments              = "`"$srcUNC`" `"$destUNC`" /E /R:3 /W:5 /NP"
        $rp.UseShellExecute        = $false
        $rp.CreateNoWindow         = $true
        $rp.RedirectStandardOutput = $false
        $rp.RedirectStandardError  = $false
        $Script:RoboProcess = [System.Diagnostics.Process]::Start($rp)
        $Script:RemotePhase = 2
    }

    # ---- Start a local process ----
    function Start-LocalOperation {
        param([hashtable]$OpInfo)
        # USMT from a pre-release / Insider ADK will not load on this machine -
        # it exits at the Windows loader (0xC0000139) before doing anything.
        try {
            $ub = Get-UsmtBuild -USMTPath (Split-Path -Parent $OpInfo.ToolPath)
            $ob = [int][Environment]::OSVersion.Version.Build
            if ($ub -gt 0 -and $ob -gt 0 -and $ub -gt $ob) {
                Write-CrashLog "USMT build $ub newer than this PC (build $ob) - warned before local run"
                $m = "The USMT binaries are build $ub - newer than this PC (build $ob)." + [Environment]::NewLine + [Environment]::NewLine +
                     "USMT from a pre-release / Insider Windows ADK exits at the loader without running. Point USMT Location " +
                     "at USMT from a released ADK (build 26100 / Windows 11 24H2 works across this fleet)." +
                     [Environment]::NewLine + [Environment]::NewLine + "Run anyway?"
                if ((Show-ThemedMessage $m "USMT version mismatch" "YesNo" "Warning") -ne [System.Windows.Forms.DialogResult]::Yes) {
                    Append-Output "Run cancelled - USMT binaries (build $ub) are newer than this PC." $Script:T.Warning
                    Set-UIRunning $false
                    return
                }
            }
        } catch { }
        Reset-FileTail
        $Script:CancelRequested     = $false
        $Script:CurrentLogFile      = $OpInfo.LogFile
        $Script:CurrentProgressLog  = $OpInfo.ProgressLog
        # Echo the full command to the output window so the tech can see what's running
        Append-Output "Command: $($OpInfo.FullCommand)" $Script:T.TextDim
        Append-Output "Log: $($OpInfo.LogFile)" $Script:T.TextDim
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $OpInfo.ToolPath
        $psi.Arguments              = $OpInfo.Arguments
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        # Do NOT redirect stdout/stderr - USMT writes to its own /l: and /progress: files.
        # Redirecting without async reading causes a pipe-buffer deadlock at /v:13.
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError  = $false
        $Script:CurrentProcess      = [System.Diagnostics.Process]::Start($psi)
        $timer.Start()
    }

    # ---- Complete-Operation  -  called when any local process exits ----
    function Complete-Operation {
        param([int]$ExitCode)

        # Flush whatever the last tick did not pick up. Incremental, so this is
        # a few bytes rather than the whole log again.
        if ($Script:CurrentProgressLog -and (Test-Path $Script:CurrentProgressLog -ErrorAction SilentlyContinue)) {
            $tail = Read-FileTail -FilePath $Script:CurrentProgressLog
            foreach ($line in $tail.Lines) {
                $friendly = Format-ProgressLine $line
                if ($friendly) { Append-Output $friendly $Script:T.Text }
            }
        }

        # The detail log gets read ONCE here, and only its last stretch.
        #
        # A successful run needs nothing from it beyond the closing totals; a
        # failed one needs the lines around the failure, which USMT writes at
        # the end before it exits. Reading the whole of a /v:13 log to show
        # twenty-five lines of it was most of the delay between a capture
        # finishing and this window admitting it had.
        if ($Script:CurrentLogFile -and (Test-Path $Script:CurrentLogFile -ErrorAction SilentlyContinue)) {
            $window   = if ($ExitCode -eq 0) { 120 } else { 400 }
            $logLines = Read-FileEndLines -FilePath $Script:CurrentLogFile -Count $window -MaxBytes 262144
            $summaryLines = @()
            foreach ($rawLine in $logLines) {
                $l = $rawLine.Trim()
                if ($l -match 'Total\s+\d+' -or $l -match 'objects migrated' -or $l -match 'Migration\s+(completed|failed)' `
                    -or $l -match 'USMT error code' -or $l -match 'Error\s+\[' -or $l -match 'Successful run' `
                    -or $l -match 'Bytes\s+Transferred' -or $l -match 'Objects\s+Transferred' `
                    -or $l -match 'Processing user:' -or $l -match 'USMT Completed' `
                    -or $l -match 'Unable to' -or $l -match 'fatal error' `
                    -or $l -match 'QuickParameterCheck' -or $l -match 'Invalid store path' `
                    -or $l -match 'Access is denied' -or $l -match 'Win32Exception' `
                    -or $l -match 'An error occurred') {
                    $summaryLines += $l
                }
            }
            # On a failure, always show the tail as well. The summary filter can
            # match a couple of harmless lines and then suppress the dump that
            # holds the actual cause - which is exactly what happened to a local
            # export to a share: two useless lines, no reason.
            if ($ExitCode -ne 0) {
                Append-Output "--- Detail log (last 25 lines) ---" $Script:T.Warning
                $start = [Math]::Max(0, $logLines.Count - 25)
                for ($i = $start; $i -lt $logLines.Count; $i++) {
                    $l = $logLines[$i].Trim(); if ($l) { Append-Output $l $Script:T.Warning }
                }
            }
            if ($summaryLines.Count -gt 0) {
                Append-Output "--- Detail log summary ---" $Script:T.TextDim
                $color = if ($ExitCode -eq 0) { $Script:T.Text } else { $Script:T.Warning }
                foreach ($sl in $summaryLines) { Append-Output $sl $color }
            }
        }

        # Exit code interpretation, from the built-in USMT return-code table.
        # The switch this replaced had 71 as "cancelled by the user" (that is 2),
        # 27 as "unable to load files" (it is an invalid store path) and 61 as
        # "could not create the store" (it is a non-fatal I/O stop) - three of
        # its six codes sent the technician after the wrong thing.
        Append-Output "---" $Script:T.TextDim
        Write-USMTExit $ExitCode
        if ($Script:CurrentLogFile) { Append-Output "Full log: $($Script:CurrentLogFile)" $Script:T.TextDim }
        $Script:CurrentLogFile     = $null
        $Script:CurrentProgressLog = $null

        if ($ExitCode -eq 0) {
            # If there is a pending import, queue it
            if ($Script:PendingImport) {
                Append-Output "Export complete. Starting import..." $Script:T.Primary
                $imp = $Script:PendingImport; $Script:PendingImport = $null
                Start-LocalOperation $imp; return
            }
            # Size the store while it is still there - the cleanup below may delete it.
            Write-CompletionSummary -StorePath $Script:CleanupPath
            # Local route: record what the store holds, and honour delete-after-
            # capture. $Script:LastCapture is set when the capture was launched,
            # because by now the fields may have been changed.
            if ($Script:LastCapture) {
                $lc = $Script:LastCapture; $Script:LastCapture = $null
                Complete-CapturePost -StorePath $lc.StorePath -SourcePC $lc.SourcePC `
                    -DestPC $lc.DestPC -Users $lc.Users -CaptureLog "$($lc.LogFile)"
            }
            # A restore records its half, so the store shows it has been used.
            if ($Script:LastRestore) {
                $lr = $Script:LastRestore; $Script:LastRestore = $null
                [void](Write-StoreMetadata -StorePath $lr.StorePath -Facts @{
                    DestinationComputer = $lr.DestPC
                    ImportedBy = "$env:USERDOMAIN\$env:USERNAME"
                    ImportedOn = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    RestoredAs = $lr.RestoredAs
                })
            }
            # Cleanup if requested
            if ($chkCleanup.Checked -and $Script:CleanupPath) {
                try {
                    # Same guarded delete as the remote path above. This twin was
                    # worse: -ErrorAction SilentlyContinue meant a wrong target
                    # was deleted quietly and a refused one said nothing either.
                    # No -ExpectedRoot, for the reason given at the remote twin:
                    # the only root available here comes out of this same path.
                    $delRes = Remove-StoredMigration -Path $Script:CleanupPath
                    if (-not $delRes.Ok) { Append-Output "Store cleanup skipped - $($delRes.Error)" $Script:T.Warning }
                    [void](Remove-EmptyStoreRoot -Root (Split-Path $Script:CleanupPath -Parent) `
                                                 -FolderName $Script:AppConfig.DefaultStorePath)
                }
                catch { Append-Output "Cleanup skipped: $_" $Script:T.Warning }
                $Script:CleanupPath = $null
            }
            $timer.Stop(); Set-UIRunning $false
            $progressBar.Style = "Continuous"; $progressBar.Value = 100
            $clown = Get-ClownVerdict $true
            $lblProgress.Text = if ($clown) { $clown } else { "100%" }
            $lblStatus.ForeColor = $Script:T.Success; $lblStatus.Text = "$($Script:CheckMark) Operation complete"
        } else {
            $timer.Stop(); Set-UIRunning $false
            $progressBar.Style = "Continuous"; $progressBar.Value = 100
            $clown = Get-ClownVerdict $false
            $lblProgress.Text = if ($clown) { $clown } else { "Failed" }
            $lblStatus.ForeColor = $Script:T.Error; $lblStatus.Text = "Operation failed (exit $ExitCode)"
        }
    }


    # ---- btnRun Click ----
    # The body lives in a function so the click handler can wrap it in a
    # re-entrancy guard without re-indenting 500 lines. Same scope either way:
    # a function and an event scriptblock both run in a child of the scope they
    # were defined in.
    function Invoke-RunClick {
        # Cleared at the top of every run. Only the per-run build check may set
        # it, and only after reading two different build numbers - so a stale
        # value from a previous migration can never carry /config into this one.
        $Script:ConfigXmlBuildMismatch = $false

        # Said once, at the top of every run, whichever mode the window is in.
        # A custom command changes what USMT actually does, and the panel that
        # shows it is not on screen in Simple mode.
        if ($Script:CmdEdited) {
            Append-Output "$($Script:WarningSign) Running YOUR EDITED command, not the one the options describe." $Script:T.Warning
        }

        $opText   = Get-OperationText
        $isExport  = ($opText -match "Export") -and -not ($opText -match [regex]::Escape([char]0x21C4)) -and -not ($opText -match "Import")
        $isImport  = ($opText -match "Import") -and -not ($opText -match [regex]::Escape([char]0x21C4)) -and -not ($opText -match "Export")
        $isCombo   = $opText -match [regex]::Escape([char]0x21C4)
        $isExtract = $opText -match "Extract"
        $isCleanup = $opText -match "Clean Up"
        $isSync    = $opText -match "Compare"

        # CATCH-UP RUNS ENTIRELY HERE and never reaches the USMT machinery
        # below. It stages nothing, needs no store and no USMT folder - it is
        # two robocopy passes and a dialog - so it returns before any of the
        # checks that exist for a migration can refuse it for lacking things it
        # does not use.
        if ($opText -match "Compare") { Invoke-CatchUpSync; return }

        $storeMode = Get-StoreMode
        $isDirect  = $storeMode -eq "Direct"
        $isCentral = $storeMode -eq "Central"
        $isNetwork = $storeMode -ne "USB"
        $isAll     = $opText -match "All Profiles"
        # Enabled is part of the test: a ticked-then-disabled box must not apply.
        $isExcOD   = $chkExcludeOneDrive.Checked -and $chkExcludeOneDrive.Enabled
        $isSettingsOnly = $opText -match "Computer Settings"

        # ---- CLEAN UP  -  housekeeping, needs no USMT folder and no username ----
        if ($isCleanup) {
            # One field, comma separated. The old form borrowed the migration
            # boxes, so a cleanup asked for a "capture from" and a "restore to"
            # and gave no clue which machine it was about to touch.
            $names = @(); $bad = @()
            foreach ($n in ($txtSourcePC.Text -split '[,;]')) {
                $n = $n.Trim()
                if (-not $n) { continue }
                # Every name here is interpolated into a UNC that a recursive
                # delete then runs against, so anything that could change the
                # shape of that path is refused rather than sanitised.
                if (-not (Test-ValidComputerName $n)) { $bad += $n; continue }
                if ($names -notcontains $n) { $names += $n }
            }
            if ($bad.Count -gt 0) {
                Show-ThemedMessage ("These are not valid computer names:`n`n  " + ($bad -join "`n  ") +
                    "`n`nUse plain machine names - no slashes, shares or drive letters.") "Clean Up" "OK" "Warning"
                $txtSourcePC.Focus(); return
            }
            # Blank means this PC, exactly as it does for a capture. The box
            # still takes a comma-separated list when other machines are meant.
            if ($names.Count -eq 0) { $names = @($env:COMPUTERNAME) }

            $lblStatus.Text = "Checking for leftover USMT files..."; $lblStatus.ForeColor = $Script:AccentCyan
            [System.Windows.Forms.Application]::DoEvents()

            $found = @(); $lines = @()
            foreach ($n in $names) {
                $info = Get-StagedToolsInfo -ComputerName $n
                # The reason matters here: "access is denied" and "the network
                # path was not found" call for completely different actions, and
                # a bare "not reachable" told the operator neither.
                if (-not $info.Reachable) {
                    $why = if ($info.Error) { $info.Error } else { "not reachable" }
                    $lines += "$n : $why"
                    continue
                }
                if (-not $info.Present)   { $lines += "$n : nothing staged"; continue }
                $found += $info
                $lines += "$n : $($info.MB) MB in $($info.Files) files"
            }
            foreach ($l in $lines) { Append-Output $l $Script:T.Text }

            # ---- Old migration stores (opt-in) ----
            # Captured user data, not tooling, so each one is listed with its
            # size and age and nothing is removed without seeing that list.
            $stores = @(); $storeRoots = @{}
            if ($chkCleanStores.Checked) {
                $lblStatus.Text = "Looking for old migration stores..."; $lblStatus.ForeColor = $Script:AccentCyan
                [System.Windows.Forms.Application]::DoEvents()
                foreach ($n in $names) {
                    $sm = Get-StoredMigrations -ComputerName $n
                    if (-not $sm.Ok) { Append-Output "$n : could not read $($sm.Root) - $($sm.Error)" $Script:T.Warning; continue }
                    # Folders that sit in the store area but are not stores are
                    # named and then left alone, so it is clear they were seen
                    # and deliberately not touched.
                    foreach ($ig in $sm.Ignored) {
                        Append-Output ("  {0}  {1}  left alone - {2}" -f $n, $ig.Name, $ig.Reason) $Script:T.TextDim
                    }
                    if ($sm.Stores.Count -eq 0) { Append-Output "$n : no migration stores in $($sm.Root)" $Script:T.Text; continue }
                    $storeRoots[$n] = $sm.Root
                    foreach ($s in $sm.Stores) {
                        $stores += ($s + @{ PC = $n })
                        Append-Output ("  {0}  {1}  {2} days old  ({3})" -f $n, $s.Name, $s.AgeDays, $s.Text) $Script:T.Text
                    }
                }
            }

            # ---- Stale user profiles (opt-in) ----
            # Whole accounts, so every one is listed with its age and the ones
            # that cannot go are listed too, with the reason - a profile quietly
            # missing from the list is worse than one shown as refused.
            $profiles = @(); $profilesBlocked = @()
            if ($chkCleanProfiles.Checked) {
                $lblStatus.Text = "Looking for stale user profiles..."; $lblStatus.ForeColor = $Script:AccentCyan
                [System.Windows.Forms.Application]::DoEvents()
                foreach ($n in $names) {
                    $pr = Get-RemoteUserProfiles -ComputerName $n -InactiveDays $Script:PreflightInactiveDays
                    if (-not $pr.Ok) {
                        Append-Output "$n : could not read user profiles - $($pr.Error)" $Script:T.Warning
                        continue
                    }
                    $canGo = @($pr.Profiles | Where-Object { $_.Removable })
                    $kept  = @($pr.Profiles | Where-Object { -not $_.Removable })
                    foreach ($k in $kept) {
                        $profilesBlocked += $k
                        Append-Output ("  {0}  {1}  keeping - {2}" -f $n, $k.Leaf, $k.Reason) $Script:T.TextDim
                    }
                    if ($canGo.Count -eq 0) {
                        Append-Output "$n : no profiles older than $($Script:PreflightInactiveDays) days to remove" $Script:T.Text
                        continue
                    }
                    foreach ($c in $canGo) {
                        $profiles += $c
                        # Where the date came from matters: Win32_UserProfile
                        # often leaves LastUseTime empty and the folder's own
                        # timestamp stands in, which is weaker evidence.
                        Append-Output ("  {0}  {1}  last modified {2}{3}" -f $n, $c.Leaf, "$(Format-ProfileDate $c.LastUse) ($(Format-ProfileAge $c.AgeDays))", $(if ($c.Orphan) { "  - no account left" } else { "" })) $Script:T.Text
                    }
                }
            }

            # Checked after all three scans, so a machine whose only leftover is
            # a stale profile is not told there is nothing to do.
            if ($found.Count -eq 0 -and $stores.Count -eq 0 -and $profiles.Count -eq 0) {
                $lblStatus.Text = "Nothing to clean up"; $lblStatus.ForeColor = $Script:T.TextDim
                Show-ThemedMessage ("Nothing to clean up.`n`n" + ($lines -join "`n")) "Clean Up" "OK" "Information"
                return
            }

            # Two confirmations, not one, and each only if there is something of
            # that kind to confirm. The two are not remotely equivalent: staged
            # tools are this tool's own copies and are replaceable, a migration
            # store is the only copy of somebody's captured profile. Bundling
            # them into a single Yes/No meant agreeing to delete user data in
            # order to tidy up a tools folder.
            $doTools  = $false
            $doStores = $false
            $cancelled = $false

            if ($found.Count -gt 0) {
                $toolsBody = "These are the USMT program files this tool copied out to run remotely. They can be staged again at any time.`n`n" +
                             (($found | ForEach-Object { "  $($_.PC)  -  $($_.MB) MB in $($_.Files) files" }) -join "`n") +
                             "`n`nAny logs still sitting there are copied into your log folder first."
                $pick = Show-ChoiceDialog -Title "Clean Up - USMT Tools" -Glyph $Script:WarningSign `
                            -Heading "Remove the staged USMT tools?" -Message $toolsBody -Choices @(
                    @{ Key = "Do";     Text = "Remove the USMT tools"; Accent = $Script:AccentStone
                       Hint = "Deletes the staged tools folder on the machines listed above." }
                    @{ Key = "Skip";   Text = "Leave the tools alone"
                       Hint = "Nothing is removed. $(if ($stores.Count -gt 0) { 'Carries on to the migration stores.' } else { 'Ends the clean up.' })" }
                    @{ Key = "Cancel"; Text = "Cancel"; IsCancel = $true
                       Hint = "Stops here. Nothing at all is removed." }
                )
                if     ($pick -eq "Do")   { $doTools = $true }
                elseif ($pick -eq "Skip") { Append-Output "Staged USMT tools left in place." $Script:T.TextDim }
                else                      { $cancelled = $true }
            }

            if (-not $cancelled -and $stores.Count -gt 0) {
                $totalBytes = 0
                foreach ($s in $stores) { $totalBytes += [double]$s.Bytes }
                $storeBody = "This is CAPTURED USER DATA. Once a store is deleted the profile it holds cannot be restored from it.`n`n" +
                             (($stores | ForEach-Object { "  $($_.PC)\$($_.Name)   $($_.Text)   $($_.AgeDays) days old" }) -join "`n") +
                             "`n`nDeleting these frees $(Format-Size $totalBytes). Make sure every one of them has already been imported onto its new PC.`n`nThe `"$($Script:AppConfig.DefaultStorePath)`" folder itself is removed too, if nothing else is left in it."
                $pick = Show-ChoiceDialog -Title "Clean Up - Migration Stores" -Glyph $Script:WarningSign `
                            -Heading "Delete these migration stores?" -Message $storeBody -Choices @(
                    @{ Key = "Do";     Text = "Delete the migration stores"; Accent = $Script:T.Error
                       Hint = "Permanently removes the $($stores.Count) store$(if ($stores.Count -ne 1) { 's' }) listed above." }
                    @{ Key = "Skip";   Text = "Keep the stores"
                       Hint = "The stores are left where they are. $(if ($doTools) { 'The USMT tools are still removed.' } else { 'Nothing is removed.' })" }
                    @{ Key = "Cancel"; Text = "Cancel"; IsCancel = $true
                       Hint = "Stops here. Nothing at all is removed$(if ($doTools) { ', including the USMT tools you just agreed to' } else { '' })." }
                )
                if     ($pick -eq "Do")   { $doStores = $true }
                elseif ($pick -eq "Skip") { Append-Output "Migration stores kept." $Script:T.TextDim }
                else                      { $cancelled = $true }
            }

            # Two steps on purpose. The picker is where the choice is made, one
            # account at a time; the dialog after it is the last chance to read
            # back exactly what was chosen. Deleting somebody's profile deserves
            # both, and the second one only ever lists what was actually ticked.
            $doProfiles = $false
            $chosen = @()
            if (-not $cancelled -and $profiles.Count -gt 0) {
                $chosen = Show-ProfilePicker -Removable $profiles -Blocked $profilesBlocked
                if ($null -eq $chosen) {
                    $cancelled = $true
                } elseif ($chosen.Count -eq 0) {
                    Append-Output "No profiles ticked - none removed." $Script:T.TextDim
                } else {
                    $body = "About to permanently delete $($chosen.Count) user profile$(if ($chosen.Count -ne 1) { 's' }) - documents, desktop and settings - and the registry entry for each:`n`n" +
                            (($chosen | ForEach-Object { "  $($_.PC)\$($_.Leaf)   last modified $(Format-ProfileDate $_.LastUse) ($(Format-ProfileAge $_.AgeDays))$(if ($_.Orphan) { `"   NO ACCOUNT LEFT`" } else { `"`" })   $($_.Path)" }) -join "`n") +
                            "`n`nA migration store is not a backup of a profile. Anything captured should already have been imported onto its new PC."
                    $pick = Show-ChoiceDialog -Title "Clean Up - Confirm Profile Deletion" -Glyph $Script:WarningSign `
                                -Heading "Delete these $($chosen.Count) profile$(if ($chosen.Count -ne 1) { 's' })?" -Message $body -Choices @(
                        @{ Key = "Do";     Text = "Yes, delete them"; Accent = $Script:T.Error
                           Hint = "Folder and registry entry together, the way System Properties does it." }
                        @{ Key = "Back";   Text = "No, leave them alone"; IsCancel = $true
                           Hint = "Nothing is removed from the accounts. Anything else you agreed to still happens." }
                    )
                    if ($pick -eq "Do") { $doProfiles = $true }
                    else { Append-Output "User profiles kept." $Script:T.TextDim; $chosen = @() }
                }
            }

            if ($cancelled) {
                $lblStatus.Text = "Ready"; $lblStatus.ForeColor = $Script:T.TextDim
                Append-Output "Clean up cancelled - nothing was removed." $Script:T.Warning
                return
            }
            if (-not $doTools -and -not $doStores -and -not $doProfiles) {
                $lblStatus.Text = "Nothing removed"; $lblStatus.ForeColor = $Script:T.TextDim
                Append-Output "Clean up finished - everything was left in place." $Script:T.TextDim
                return
            }

            $lblStatus.Text = "Cleaning up..."; $lblStatus.ForeColor = $Script:AccentCyan
            [System.Windows.Forms.Application]::DoEvents()
            foreach ($info in $(if ($doTools) { $found } else { @() })) {
                $r = Remove-StagedTools -ComputerName $info.PC -LogFolder $Script:AppConfig.LogFolder
                if ($r.Ok -and $r.Removed) {
                    $extra = if ($r.SavedLogs -gt 0) { " ($($r.SavedLogs) log file(s) saved first)" } else { "" }
                    Append-Output "Removed USMT tools from $($r.PC)$extra" $Script:T.Success
                } elseif ($r.Ok) {
                    Append-Output "$($r.PC): nothing to remove" $Script:T.TextDim
                } else {
                    Append-Output "$($r.PC): could not remove - $($r.Error)" $Script:T.Error
                }
            }
            $freed = 0
            foreach ($s in $(if ($doStores) { $stores } else { @() })) {
                $r = Remove-StoredMigration -Path $s.Path -ExpectedRoot $s.Root
                if ($r.Ok) {
                    $freed += [double]$s.Bytes
                    Append-Output "Deleted store $($s.PC)\$($s.Name) ($($s.Text))" $Script:T.Success
                } else {
                    Append-Output "Could not delete $($s.Path) - $($r.Error)" $Script:T.Error
                }
            }
            # $chosen, not $profiles: only what was ticked.
            foreach ($pr in $(if ($doProfiles) { $chosen } else { @() })) {
                $lblStatus.Text = "Deleting profile $($pr.Leaf) on $($pr.PC)..."
                [System.Windows.Forms.Application]::DoEvents()
                $r = Remove-RemoteUserProfile -ComputerName $pr.PC -SID $pr.SID
                if ($r.Ok) {
                    Append-Output "Deleted profile $($pr.PC)\$($pr.Leaf)  ($($pr.Path))" $Script:T.Success
                } else {
                    Append-Output "Could not delete $($pr.PC)\$($pr.Leaf) - $($r.Error)" $Script:T.Error
                }
            }
            # The store FOLDER goes too once it is empty. Leaving "USMT
            # Profiles" behind on the root of C: on every machine the tool has
            # touched looks like the clean up did not finish.
            if ($doStores) {
                foreach ($n in $storeRoots.Keys) {
                    $rr = Remove-EmptyStoreRoot -Root $storeRoots[$n] -FolderName $Script:AppConfig.DefaultStorePath
                    if ($rr.Removed)      { Append-Output "Removed the empty store folder $($storeRoots[$n])" $Script:T.Success }
                    elseif ($rr.Ok -and $rr.Error) { Append-Output "Kept $($storeRoots[$n]) - $($rr.Error)" $Script:T.TextDim }
                    elseif (-not $rr.Ok)  { Append-Output "Could not remove $($storeRoots[$n]) - $($rr.Error)" $Script:T.Warning }
                }
            }
            if ($freed -gt 0) { Append-Output "Freed $(Format-Size $freed)." $Script:AccentCyan }
            $lblStatus.Text = "$($Script:CheckMark) Clean up complete"; $lblStatus.ForeColor = $Script:T.Success
            Invoke-TaskbarFlash -Form $Form
            return
        }

        $usmtPath  = $txtUSMTPath.Text.Trim()
        if (-not (Test-USMTPath $usmtPath)) { Show-ThemedMessage "Please select a valid USMT folder first." "USMT Path" "OK" "Warning"; return }

        if (-not $isExtract -and -not $isAll -and -not $isSettingsOnly -and [string]::IsNullOrWhiteSpace($txtUsername.Text.Trim())) {
            Show-ThemedMessage "Please enter a username." "Missing Field" "OK" "Warning"; return
        }

        # One name or several. $username stays the FIRST for everything that
        # needs a single label - log file names, the store folder, the OneDrive
        # check - while $usernames carries the whole set to USMT.
        $usernames = Get-UsernameList
        $username  = if ($usernames.Count -gt 0) { $usernames[0] } else { "" }
        $multiUser = $usernames.Count -gt 1
        $verbosity = $Script:AppConfig.Verbosity

        # REFUSED HERE, BEFORE ANYTHING RUNS.
        #
        # A remote run does not hand USMT an argument array: it builds one string
        # and gives it to "schtasks /tr", which the task scheduler re-parses when
        # the task runs elevated on the far machine. A name carrying command-line
        # punctuation is therefore syntax, not a name.
        #
        # This is the entry point rather than Build-USMTArgs because a refusal
        # has to be something the operator can see and fix. Down there it would
        # either throw from inside a command builder or, worse, quietly build
        # something different from what was asked for.
        $badNames = @($usernames | Where-Object { -not (Test-ValidUsername $_) })
        if ($badNames.Count) {
            Show-ThemedMessage ("These are not usable profile names:`r`n`r`n  " +
                ($badNames -join "`r`n  ") +
                "`r`n`r`nA name can contain letters, numbers, spaces, dots, hyphens and one DOMAIN\ prefix. Quotes and punctuation such as & | ; < > % are not allowed - they would be read as part of the command rather than as a name.") `
                "Check the profile name" "OK" "Warning"
            Append-Output "Refused to run - $($badNames.Count) profile name(s) contain characters that are not allowed." $Script:T.Error
            return
        }

        # Read every computer name / path through the applies-to map, so a value
        # left behind by a different operation cannot drive this one. The boxes
        # keep their text either way - it comes back when you switch back.
        $fNewPC       = Get-ActiveText "NewPC"       $txtNewPC
        $fSourcePC    = Get-ActiveText "SourcePC"    $txtSourcePC

        # THE ARCHITECTURE PICKER NOW ACTUALLY PICKS SOMETHING.
        #
        # $usmtPath was read straight off the text box, so the Auto / 64-bit /
        # 32-bit choice was saved to settings, restored from settings, and read
        # by nothing - a dropdown that remembered your answer and ignored it.
        # Every run used whatever folder was typed: correct on an all-x64
        # estate, and quietly wrong the first time a 32-bit machine appears.
        #
        # RESOLVED HERE, not at the top, because it needs to know the machine
        # the command will RUN ON - the source for a capture, the destination
        # for a restore - and those are only worked out a few lines above. The
        # validated path stays as the fallback, so a missing x86 build cannot
        # stop an x64 migration.
        $archTarget = if ($isImport) { $fNewPC } else { $fSourcePC }
        try {
            $archPath = Get-USMTPathForRun -TargetPC $archTarget
            if ($archPath -and (Test-USMTPath $archPath)) {
                if ($archPath -ne $usmtPath) {
                    Append-Output "USMT: using $archPath for $(if ($archTarget) { $archTarget } else { 'this PC' })." $Script:T.TextDim
                }
                $usmtPath = $archPath
            }
        } catch { Write-CrashLog "Architecture selection failed, keeping $usmtPath : $($_.Exception.Message)" }
        $fCentralPath = Get-ActiveText "CentralPath" $txtCentralPath
        $fUSBPath     = Get-ActiveText "USBPath"     $txtUSBPath

        # Apply the domain from the GUI field so all command builders pick it up
        if (-not $isSettingsOnly) { $Script:AppConfig.Domain = $txtDomain.Text.Trim() }

        # ---- EXTRACT ----
        if ($isExtract) {
            if ([string]::IsNullOrWhiteSpace($txtMigrationFile.Text) -or -not (Test-Path $txtMigrationFile.Text)) { Show-ThemedMessage "Select a valid .MIG file." "Missing Field" "OK" "Warning"; return }
            if ([string]::IsNullOrWhiteSpace($txtExtractPath.Text)) { Show-ThemedMessage "Select an extract destination folder." "Missing Field" "OK" "Warning"; return }
            $cmd = Build-USMTCommand -USMTPath $usmtPath -Operation "Extract" -StorePath $txtMigrationFile.Text -Username "extracted" -AllProfiles $false -ExcludeOneDrive $false -Verbosity $verbosity -Overwrite $true
            Append-Output "Extracting $($txtMigrationFile.Text) to $($txtExtractPath.Text)..." $Script:T.Primary
            $lblStatus.Text = "Extracting..."; $lblStatus.ForeColor = $Script:T.Primary
            Set-UIRunning $true; Start-LocalOperation $cmd; return
        }

        # ---- IMPORT ----
        # An import is now pointed at a store rather than guessing one from a
        # naming convention, so it needs exactly two facts: which store, and
        # which machine to restore onto.
        if ($isImport) {
            $newPC = $fNewPC
            $picked = Get-ActiveText "ImportStore" $txtImportStore
            if ([string]::IsNullOrWhiteSpace($picked)) {
                Show-ThemedMessage "Choose the store to restore.`n`nBrowse to the folder holding USMT\USMT.MIG - on this PC, a USB drive, or a network share." "Missing Store" "OK" "Warning"
                $txtImportStore.Focus(); return
            }
            $chk = Test-StoreReadable $picked
            if (-not $chk.Ok) {
                Show-ThemedMessage "That does not look like a USMT store:`n$picked`n`n$($chk.Error)" "Missing Store" "OK" "Warning"
                $txtImportStore.Focus(); return
            }
            $storeRoot = $chk.Root
            $isRemoteImport = -not [string]::IsNullOrWhiteSpace($newPC) -and ($newPC -ne $env:COMPUTERNAME)

            # ---- restore onto this PC ----
            if (-not $isRemoteImport) {
                $Script:LastRestore = @{
                StorePath  = $storeRoot
                DestPC     = $(if ($newPC) { $newPC } else { $env:COMPUTERNAME })
                RestoredAs = (Get-RenameTo)
            }
            $cmd = Build-USMTCommand -USMTPath $usmtPath -Operation "Import" -StorePath $storeRoot -Username $username -AllProfiles $isAll -ExcludeOneDrive $false -Verbosity $verbosity -SettingsOnly $isSettingsOnly `
                            -Extra $Script:ExtraImport -ArgOverride (Get-CommandOverride "Import") -Usernames $(if ($multiUser) { $usernames } else { @() }) `
                            -RenameFrom (Get-RenameFrom) -RenameTo (Get-RenameTo)
                Append-Output "Importing $(if ($isSettingsOnly) {'computer settings'} else {'profile'}) from $storeRoot" $Script:T.Primary
                $lblStatus.Text = "Importing..."; $lblStatus.ForeColor = $Script:T.Primary
                $Script:CleanupPath = if ($chkCleanup.Checked) { $storeRoot } else { $null }
                Set-UIRunning $true; Start-LocalOperation $cmd; return
            }

            # ---- restore onto another PC ----
            Append-Output "Remote import selected. Restore to: $newPC" $Script:AccentCyan
            Append-Output "Checking connectivity to $newPC..." $Script:AccentCyan
            $lblStatus.Text = "Validating connectivity..."; $lblStatus.ForeColor = $Script:AccentCyan
            [System.Windows.Forms.Application]::DoEvents()
            if (-not (Test-ComputerReachable $newPC)) { Show-ThemedMessage "$newPC is not reachable (ping failed)." "Connectivity" "OK" "Warning"; return }
            if (-not (Test-AdminShare $newPC))         { Show-ThemedMessage "Cannot access \\$newPC\C$`nEnsure you have admin rights on $newPC." "Admin Share" "OK" "Warning"; return }

            # loadstate must load on $newPC - USMT from a pre-release/Insider ADK
            # will not, and exits at the loader with a blank log.
            $ub = Get-UsmtBuild -USMTPath $usmtPath
            $nb = Get-RemoteOSBuild -ComputerName $newPC
            if ($ub -gt 0 -and $nb.Ok -and $ub -gt $nb.Build) {
                $m = "USMT here is build $ub - newer than $newPC ($($nb.Display))." + [Environment]::NewLine + [Environment]::NewLine +
                     "USMT from a pre-release / Insider ADK does not run on released Windows: loadstate exits immediately " +
                     "with a loader error and nothing is restored." + [Environment]::NewLine + [Environment]::NewLine +
                     "Point USMT Location at USMT from a released ADK (build 26100 works across this fleet). Run anyway?"
                if ((Show-ThemedMessage $m "USMT version mismatch" "YesNo" "Warning") -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }

            # LoadState runs on the destination as SYSTEM, which reaches the
            # network as that machine's computer account - so it cannot read a
            # store sitting on this workstation or on a share it has no rights
            # to. Anything not already on the destination is copied there first.
            $destLocal = "C:\$($Script:AppConfig.DefaultStorePath)\$(Split-Path $storeRoot -Leaf)"
            $destUNC   = "\\$newPC\C$\$($Script:AppConfig.DefaultStorePath)\$(Split-Path $storeRoot -Leaf)"
            $alreadyThere = $storeRoot -ieq $destUNC -or $storeRoot -imatch "^\\\\$([regex]::Escape($newPC))\\"

            $Script:PendingImport = @{
                IsRemote     = $true
                DestPC       = $newPC
                StorePath    = $(if ($alreadyThere) { $storeRoot } else { $destLocal })
                StoreUNC     = $(if ($alreadyThere) { $storeRoot } else { $destUNC })
                Username     = $username
                AllProfiles  = $isAll
                USMTPath     = $usmtPath
                Verbosity    = $verbosity
                SettingsOnly = $isSettingsOnly
                # Same three the local branch above passes to Build-USMTCommand.
                # Remote restores were dropping them silently.
                Usernames    = $(if ($multiUser) { $usernames } else { @() })
                RenameFrom   = (Get-RenameFrom)
                RenameTo     = (Get-RenameTo)
            }
            Set-UIRunning $true

            if ($alreadyThere) {
                Append-Output "Store is already on $newPC - importing in place." $Script:T.Text
                Start-PendingRemoteImport
            } else {
                Start-ImportCopyPhase -SourceStore $storeRoot -DestUNC $destUNC
            }
            return
        }

        # ---- EXPORT / COMBO ----
        if ($isExport -or $isCombo) {
            $newPC     = if ($isNetwork) { $fNewPC } else { "" }
            $sourcePC  = if ($isNetwork) { $fSourcePC } else { "" }
            # No longer tied to network store types. ScanState running as SYSTEM
            # on the captured machine can write to that machine's own drives, so
            # a remote export to the old PC's USB disk is just a local write from
            # ScanState's point of view - which is the answer when the old PC is
            # full but has an external drive plugged in.
            $isRemote  = -not [string]::IsNullOrWhiteSpace($sourcePC) -and ($sourcePC -ne $env:COMPUTERNAME)

            # The drive has to be physically moved between the two machines, so
            # the two legs cannot run back to back the way they can over a wire.
            # Catches the local case too - capturing this PC to a drive and then
            # restoring it straight back onto the same PC achieves nothing.
            #
            # Unreachable from the GUI now: the pairing greys out in the Action
            # list and both dropdowns fall back to Export. Kept as a backstop
            # because a hand-edited settings file can still restore the pair,
            # and a dialog beats a capture nobody can restore.
            if ((-not $isNetwork) -and $isCombo) {
                $whereFrom = if ($isRemote) { $sourcePC } else { "this PC" }
                Show-ThemedMessage ("Export + Import cannot run in one go when the store is on a drive.`n`n" +
                    "ScanState writes the store to $fUSBPath on $whereFrom. Nothing on the new PC can read it until the drive is physically moved.`n`n" +
                    "Run Export now, move the drive to the new PC, then run Import there and browse to the store.") "Drive Store" "OK" "Warning"
                return
            }

            # A Central-mode plain export has no destination to name; everything
            # else writes to, or later runs on, the new PC.
            # Same rule Update-Fields uses to show the box, so the check can
            # never demand a field the panel has hidden.
            $needsDestPC = $isCombo -or ($isExport -and $isDirect)
            if ($needsDestPC -and [string]::IsNullOrWhiteSpace($newPC)) { Show-ThemedMessage "Enter the PC to restore to." "Missing Field" "OK" "Warning"; return }
            if ($isCentral) {
                $rootCheck = Test-CentralStoreRoot $fCentralPath
                if (-not $rootCheck.Ok) {
                    Show-ThemedMessage $rootCheck.Reason "Central Store Root" "OK" "Warning"
                    $txtCentralPath.Focus(); return
                }
            }

            # The machine the capture is actually read from. Store folders are
            # named after it, not after this workstation - a remote all-profiles
            # export used to label the store with the technician's PC name while
            # the import side looked it up under the old PC's name.
            $storePCName    = if ($isRemote) { $sourcePC } else { $env:COMPUTERNAME }
            $settingsFolder = "Settings_$storePCName"

            # ---- Pre-flight profile check (skip for All Profiles and Settings-Only) ----
            if (-not $isAll -and -not $isSettingsOnly -and $chkVerifyProfile.Checked) {
                $checkPC = if ($isRemote) { $sourcePC } else { $env:COMPUTERNAME }
                $isRemoteCheck = ($checkPC -ne $env:COMPUTERNAME)
                $profileExists = Test-ProfileExists -Username $username -ComputerName $checkPC -IsRemote $isRemoteCheck
                if (-not $profileExists) {
                    $warnMsg = "Profile folder for '$username' was NOT found on $checkPC.`n`n" +
                               "C:\Users\$username does not exist.`n`n" +
                               "USMT may run for hours scanning system data without capturing any user files.`n`n" +
                               "Continue anyway?"
                    $answer = Show-ThemedMessage $warnMsg "Profile Not Found" "YesNo" "Warning"
                    if ($answer -eq "No") {
                        Append-Output "$($Script:WarningSign) Aborted: profile folder for '$username' not found on $checkPC." $Script:T.Warning
                        return
                    }
                    Append-Output "$($Script:WarningSign) Warning: proceeding without profile folder for '$username' on $checkPC." $Script:T.Warning
                }
            }

            # ---- OneDrive detection ----
            # A synced profile is the single biggest reason a capture takes
            # hours and overruns the destination: every cloud file that happens
            # to be downloaded gets copied into the store, having already been
            # backed up by the sync client. The operator gets told before the
            # run rather than discovering it from the store size afterwards.
            #
            # Only asked when the option would actually reach ScanState (same
            # rule Update-Fields uses to enable the checkbox) and only when it
            # is not already ticked - there is nothing to decide if the answer
            # is already "exclude".
            $odApplies = (-not $isAll) -and (-not $isSettingsOnly) -and $chkODDetect.Checked
            if ($odApplies -and -not $isExcOD) {
                $odPC = if ($isRemote) { $sourcePC } else { $env:COMPUTERNAME }
                $lblStatus.Text = "Checking for OneDrive..."; $lblStatus.ForeColor = $Script:AccentCyan
                [System.Windows.Forms.Application]::DoEvents()
                # Measuring the OneDrive folders can take a moment on a big
                # profile, so the status line counts along with it rather than
                # leaving the window looking hung.
                $odTick = {
                    param($dirs, $files)
                    $lblStatus.Text = "Checking OneDrive... ($files files)"
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $od = Get-OneDriveUsage -Username $username -ComputerName $odPC -IsRemote $isRemote -AllProfiles $isAll `
                        -FolderPattern (Get-ODPattern) -MinLocalBytes (Get-ODMinBytes) -OnProgress $odTick
                $lblStatus.Text = "Ready"; $lblStatus.ForeColor = $Script:T.TextDim

                if ($od.Detected) {
                    Append-Output "OneDrive detected on $odPC" $Script:AccentCyan
                    foreach ($l in $od.Lines) { Append-Output $l $Script:T.TextDim }

                    # The exclusion is an XML file that ships beside the tools.
                    # If it is not there the choice cannot be honoured, so it is
                    # not offered - the old behaviour logged a warning and ran
                    # the full capture anyway, which looks identical to success.
                    $exXml = Join-Path $usmtPath "ExcludeOneDriveFolders.xml"
                    $haveXml = Test-Path $exXml

                    $why = @()
                    if ($od.Folders.Count -gt 0) { $why += "$($od.Folders.Count) OneDrive folder$(if ($od.Folders.Count -ne 1) { 's' }) in the profile" }
                    if ($od.InGroup -eq $true)   { $why += "membership of $($od.GroupName)" }
                    $body = "$username on $odPC - found $($why -join ' and ').`n`n" +
                            (($od.Lines) -join "`n") + "`n`n" +
                            "OneDrive files are already backed up to the cloud, so capturing them copies data that does not need to move."

                    $choices = @(
                        @{ Key = "Exclude"; Text = "Exclude OneDrive folders"; Accent = $Script:AccentTeal
                           Hint = "Runs with ExcludeOneDriveFolders.xml. The files stay in the cloud and re-sync once the user signs in on the new PC - much smaller store, much faster capture." }
                        @{ Key = "Include"; Text = "Include everything (skip)"
                           Hint = "Runs with the regular XML. Downloaded copies of OneDrive files are captured into the store as well." }
                        @{ Key = "Cancel";  Text = "Cancel"; IsCancel = $true
                           Hint = "Go back without running anything." }
                    )
                    if (-not $haveXml) {
                        $body += "`n`nExcludeOneDriveFolders.xml is NOT in the USMT folder, so the exclusion cannot be applied here. Place it in $usmtPath to enable it."
                        $choices = $choices | Where-Object { $_.Key -ne "Exclude" }
                    }

                    $pick = Show-ChoiceDialog -Title "OneDrive Detected" -Glyph $Script:WarningSign `
                                -Heading "OneDrive is in use on this profile" -Message $body -Choices $choices
                    switch ($pick) {
                        "Exclude" {
                            # Tick the box as well, so the panel agrees with what
                            # is about to run and the setting is remembered.
                            $chkExcludeOneDrive.Checked = $true
                            $isExcOD = $true
                            Append-Output "OneDrive folders will be EXCLUDED from this capture." $Script:AccentTeal
                        }
                        "Include" {
                            Append-Output "OneDrive folders will be INCLUDED - capture may be considerably larger." $Script:T.Warning
                        }
                        default {
                            $lblStatus.Text = "Cancelled"; $lblStatus.ForeColor = $Script:T.TextDim
                            Append-Output "Cancelled at the OneDrive prompt." $Script:T.Warning
                            return
                        }
                    }
                } elseif ($od.BelowThreshold) {
                    # Found, measured, and not worth interrupting for. Reported
                    # so it is clear the check ran and made a decision, rather
                    # than looking like it never fired.
                    Append-Output "OneDrive present on $odPC but only $(Format-Size $od.LocalBytes) is held locally - not prompting." $Script:T.TextDim
                } elseif (-not $od.Checked) {
                    # Not the same as "no OneDrive": say so rather than staying
                    # silent and letting the absence read as an all-clear.
                    Append-Output "OneDrive check skipped - $($od.Error)" $Script:T.TextDim
                }
            } elseif ($odApplies -and $isExcOD) {
                Append-Output "OneDrive folders will be excluded (option is ticked)." $Script:T.TextDim
            }

            # ---- Disk space + inactive profile checks ----
            if ($chkCheckDisk.Checked -or $chkCheckInactive.Checked -or $chkEstimateSize.Checked) {
                $srcPCForChecks = if ($isRemote) { $sourcePC } else { $env:COMPUTERNAME }

                # Where the store will land. Only the legacy staged route puts a
                # copy on the source's own disk, so only that route needs the
                # source checked for room to hold one.
                # Short labels so the report lines up as a column; the machines
                # they refer to are named in the header line instead.
                $spacePaths = @()
                if     ($isCentral) { $spacePaths += "Central store|$($fCentralPath)" }
                elseif ($isNetwork) { $spacePaths += "Destination|\\$newPC\C`$\" }
                else                { $spacePaths += "Destination|$($fUSBPath)" }
                if (-not $isRemote) { $spacePaths += "This PC (C:)|C:\" }

                $where = if ($isRemote) { "source $sourcePC" } else { "this PC" }
                if     ($isCentral) { $where += " -> central store" }
                elseif ($isNetwork -and $newPC) { $where += " -> $newPC" }
                elseif (-not $isNetwork) { $where += " -> $fUSBPath" }

                $lblStatus.Text = "Running pre-checks..."; $lblStatus.ForeColor = $Script:AccentCyan
                Append-Output "Pre-check  ($where)" $Script:AccentCyan
                [System.Windows.Forms.Application]::DoEvents()

                $pf = Invoke-PreflightChecks `
                        -CheckDisk     $chkCheckDisk.Checked `
                        -CheckInactive $chkCheckInactive.Checked `
                        -SpacePaths    $spacePaths `
                        -ProfileHostPC $srcPCForChecks `
                        -OnlyUser      $(if ($isAll -or $isSettingsOnly) { "" } else { $username }) `
                        -AllProfiles   $isAll

                $pfInfo     = @($pf.Info)
                $pfWarnings = @($pf.Warnings)

                # ---- Optional: measure what is actually being carried ----
                # Reading the profile folder answers the size question directly.
                # The old route ran a second ScanState pass just to produce a
                # number, which meant walking every file twice per migration.
                if ($chkEstimateSize.Checked -and -not $isSettingsOnly) {
                    $lblStatus.Text = "Measuring profile size..."; $lblStatus.ForeColor = $Script:AccentCyan
                    [System.Windows.Forms.Application]::DoEvents()

                    # Keeps the window painting during a long walk without the
                    # whole async task machinery a ScanState pass needed.
                    $tick = {
                        param($dirs, $files)
                        $lblStatus.Text = "Measuring profile size... ($files files)"
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                    # $isExcOD carries whatever the OneDrive prompt just decided.
                    $size = Get-ProfileSizeInfo -ComputerName $srcPCForChecks `
                                -OnlyUser $(if ($isAll) { "" } else { $username }) `
                                -AllProfiles $isAll -OnProgress $tick `
                                -ExcludeOneDrive $isExcOD

                    $destLabel = if ($isCentral) { "Central store" } else { "Destination" }
                    $destPath  = if     ($isCentral) { $fCentralPath }
                                 elseif ($isNetwork) { "\\$newPC\C`$\" }
                                 else                { $fUSBPath }

                    # The disk check already printed free space for this same
                    # destination, so do not print it a second time.
                    $sz = Test-ProfileSizeAgainstSpace -Size $size -DestLabel $destLabel -DestPath $destPath `
                            -SkipFreeSpaceLine $chkCheckDisk.Checked
                    $pfInfo     += $sz.Info
                    $pfWarnings += $sz.Warnings
                }

                # Indentation carries the meaning here, and both formats are
                # produced by this tool rather than sniffed from arbitrary text:
                # a two-space prefix is a result row worth reading, anything
                # deeper is supporting detail for the row above it.
                foreach ($line in $pfInfo) {
                    $isDetail = $line -match '^\s{3,}'
                    Append-Output $line $(if ($isDetail) { $Script:T.TextDim } else { $Script:T.Text })
                }

                if ($pfWarnings.Count -gt 0) {
                    foreach ($w in $pfWarnings) { Append-Output "$($Script:WarningSign) $w" $Script:T.Warning }
                    $msg = "The pre-check raised the following:" + "`n`n" +
                           (($pfWarnings | ForEach-Object { "  $($Script:WarningSign)  $_" }) -join "`n") +
                           "`n`nContinue anyway?"
                    $answer = Show-ThemedMessage $msg "Pre-check" "YesNo" "Warning"
                    if ($answer -eq "No") {
                        $lblStatus.Text = "Cancelled at pre-check"; $lblStatus.ForeColor = $Script:T.Warning
                        Append-Output "Aborted at the pre-check." $Script:T.Warning
                        return
                    }
                    Append-Output "Proceeding despite pre-check warnings." $Script:T.Warning
                }
                $lblStatus.Text = "Ready"; $lblStatus.ForeColor = $Script:T.TextDim
            }

            # ---- Store paths, per mode ----
            # $sub names the store folder; $destStorePath is how THIS machine
            # reaches it; $importStorePath is how the DESTINATION reaches it.
            # Direct and USB differ on those two, Central makes them the same
            # string because a UNC reads identically from everywhere.
            # Several users share one store, named after the machine they came
            # off - "bob, jane" is not a folder name anyone wants to type into
            # an import later.
            $sub = if ($isSettingsOnly) { $settingsFolder }
                   elseif ($isAll)      { $storePCName }
                   elseif ($multiUser)  { "${storePCName}_$($usernames.Count)users" }
                   else                 { $username }
            $centralRoot = $fCentralPath

            if ($isCentral) {
                $destStorePath   = Join-Path $centralRoot "${storePCName}_$sub"
                $importStorePath = $destStorePath
            } elseif ($isNetwork) {
                $destStorePath   = "\\$newPC\C$\$($Script:AppConfig.DefaultStorePath)\$sub"
                $importStorePath = "C:\$($Script:AppConfig.DefaultStorePath)\$sub"
            } else {
                $destStorePath = if ($isSettingsOnly) {
                    Join-Path $fUSBPath "$($Script:AppConfig.DefaultStorePath)\$settingsFolder"
                } else {
                    Get-StorePath -Operation "Export" -DestType "USB" -Username $username -ComputerName "" -USBPath $fUSBPath -AllProfiles $isAll
                }
                $importStorePath = $destStorePath
            }

            # Import command queued for combo (runs after export regardless of local/remote)
            if ($isCombo) {
                $importCmd = Build-USMTCommand -USMTPath $usmtPath -Operation "Import" -StorePath $importStorePath -Username $username -AllProfiles $isAll -ExcludeOneDrive $false -Verbosity $verbosity -SettingsOnly $isSettingsOnly `
                                    -Extra $Script:ExtraImport -ArgOverride (Get-CommandOverride "Import") -Usernames $(if ($multiUser) { $usernames } else { @() }) `
                            -RenameFrom (Get-RenameFrom) -RenameTo (Get-RenameTo)
                $Script:PendingImport   = $importCmd
                $Script:CleanupPath     = if ($chkCleanup.Checked) { $importStorePath } else { $null }
            }

            # Claim the destination before anything is launched. Two windows
            # aiming at the same store is the one way the second-window feature
            # can corrupt a migration, and neither process can see the other's
            # UI - so the claim is a file, and it is checked here.
            $lock = Lock-StorePath $destStorePath
            if (-not $lock.Ok) {
                $o = $lock.Owner
                Show-ThemedMessage ("Another window is already migrating to this store:`n`n  $destStorePath`n`n" +
                    "Started $($o.Started) by $($o.User) (process $($o.OwnerPid)).`n`n" +
                    "Running two captures into one store corrupts it. Finish or stop that one first, or point this window at a different machine.") `
                    "Store In Use" "OK" "Warning"
                Write-UTWError -What "the destination store is in use by another window" `
                    -Detail "$destStorePath is claimed by process $($o.OwnerPid)" `
                    -Try "Finish or stop that window's migration, or point this one at a different machine."
                return
            }
            $Script:StoreLock = $lock.File

            # Everything the launch needs, stashed so the estimate pass can hand
            # control back to Start-ExportNow when it finishes.
            $Script:ExportPlan = @{
                IsRemote = $isRemote; IsCombo = $isCombo; IsCentral = $isCentral; IsNetwork = $isNetwork
                IsAll = $isAll; IsSettingsOnly = $isSettingsOnly; IsExcOD = $isExcOD
                Usernames = $usernames; MultiUser = $multiUser
                SourcePC = $sourcePC; NewPC = $newPC; StorePCName = $storePCName
                Username = $username; USMTPath = $usmtPath; Verbosity = $verbosity
                Overwrite = $chkOverwrite.Checked
                Sub = $sub; DestStorePath = $destStorePath; ImportStorePath = $importStorePath
                # Read from the form HERE, while it is still on screen. The
                # estimate pass hands control back later, by which time the
                # checkbox and the box beside it may say something else.
                RenameFrom = (Get-RenameFrom); RenameTo = (Get-RenameTo)
            }

            Set-UIRunning $true
            Start-ExportNow
            return
        }
    }

    # One operation per window. Two separate things have to hold for that:
    #
    #   * while an operation RUNS, Set-UIRunning disables the button
    #   * while the click handler is still WORKING - pre-checks, dialogs, the
    #     profile walk - it repeatedly calls DoEvents to keep the window
    #     painting, and DoEvents dispatches any click that has queued up in the
    #     meantime. Without this flag a double-click on Run entered the handler
    #     twice and launched two captures against the same store.
    #
    # Anyone wanting a second migration at the same time opens a second window.
    $Script:RunClickBusy = $false
    $btnRun.Add_Click({
        if ($Script:RunClickBusy) {
            Write-CrashLog "Run click ignored - the previous one is still being processed"
            return
        }
        $Script:RunClickBusy = $true
        $btnRun.Enabled = $false
        try {
            Invoke-RunClick
        } catch {
            # A crash in here used to leave the button dead and the window
            # looking hung, with the reason only in the crash log.
            Write-CrashLog "Run failed: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
            # A throw before USMT ever started is by definition a UTW-level
            # failure, so it is referred to the UTW notes and not to Microsoft.
            Write-UTWError -What "the operation could not be started" `
                -Detail $_.Exception.Message `
                -Try "Check the USMT folder, the machine names, and that the destination is reachable. Full stack trace is in the crash log."
            Show-ThemedMessage "The operation could not be started.`n`n$($_.Exception.Message)`n`nSee the crash log for details." "Error" "OK" "Error"
            try { Set-UIRunning $false } catch { }
        } finally {
            $Script:RunClickBusy = $false
            # Set-UIRunning owns the button once something is actually running;
            # otherwise the handler returned without starting anything and the
            # button has to come back.
            if (-not $Script:OperationRunning) { $btnRun.Enabled = $true }
        }
    })

    # ---- Launch the export once any sizing pass has cleared ----
    # Split out of btnRun so the estimate phase has something to hand back to.
    function Start-ExportNow {
        $p = $Script:ExportPlan
        if (-not $p) { return }
        $isRemote = $p.IsRemote; $isCombo = $p.IsCombo; $isCentral = $p.IsCentral
        $sourcePC = $p.SourcePC; $newPC = $p.NewPC
        $usmtPath = $p.USMTPath; $username = $p.Username
        $destStorePath = $p.DestStorePath; $importStorePath = $p.ImportStorePath
        $isSettingsOnly = $p.IsSettingsOnly

        # ---- REMOTE export path ----
        if ($isRemote) {
            $opLabel = if ($isSettingsOnly) { "settings" } else { "profile" }
            Append-Output "Remote $opLabel export selected. Source: $sourcePC  Dest: $newPC" $Script:AccentCyan
            Append-Output "Checking connectivity..." $Script:AccentCyan
            $lblStatus.Text = "Validating connectivity..."; $lblStatus.ForeColor = $Script:AccentCyan
            [System.Windows.Forms.Application]::DoEvents()

            # Validate source PC
            if (-not (Test-ComputerReachable $sourcePC)) { Show-ThemedMessage "$sourcePC is not reachable (ping failed)." "Connectivity" "OK" "Warning"; Set-UIRunning $false; $Script:PendingImport = $null; return }
            if (-not (Test-AdminShare $sourcePC))         { Show-ThemedMessage "Cannot access \\$sourcePC\C$`nEnsure you have admin rights on $sourcePC." "Admin Share" "OK" "Warning"; Set-UIRunning $false; $Script:PendingImport = $null; return }
            # Validate dest PC - not needed for a Central-mode plain export, which never touches it
            if ($newPC) {
                if (-not (Test-ComputerReachable $newPC)) { Show-ThemedMessage "$newPC is not reachable (ping failed)." "Connectivity" "OK" "Warning"; Set-UIRunning $false; $Script:PendingImport = $null; return }
                if (-not (Test-AdminShare $newPC))         { Show-ThemedMessage "Cannot access \\$newPC\C$`nEnsure you have admin rights on $newPC." "Admin Share" "OK" "Warning"; Set-UIRunning $false; $Script:PendingImport = $null; return }
            }

            # ---- Read both Windows builds once ----
            # Feeds two checks: the Config.xml cross-build decision, and the
            # USMT-binary-vs-OS sanity check below it.
            $sb = @{ Ok = $false; Build = 0; Display = "" }
            $db = @{ Ok = $false; Build = 0; Display = "" }
            if ($sourcePC) { $sb = Get-RemoteOSBuild -ComputerName $sourcePC }
            if ($newPC)    { $db = Get-RemoteOSBuild -ComputerName $newPC }

            # ---- USMT binaries vs the machines' Windows builds ----
            # scanstate must load on the source, loadstate on the dest. USMT from
            # a RELEASED ADK is never newer than the newest released Windows in
            # play; USMT from a pre-release / Insider ADK is newer than every
            # real machine and dies at the Windows loader (0xC0000139) the
            # instant it starts - producing exactly the blank-log failure that
            # keeps coming back. Catch it before the run, not after.
            $usmtBuild = Get-UsmtBuild -USMTPath $usmtPath
            $machineMax = [Math]::Max([int]$sb.Build, [int]$db.Build)
            if ($usmtBuild -gt 0 -and $machineMax -gt 0 -and $usmtBuild -gt $machineMax) {
                Write-CrashLog "USMT build $usmtBuild is newer than both machines (source $($sb.Build), dest $($db.Build)) - warned before run"
                $msg = "The USMT binaries at" + [Environment]::NewLine + $usmtPath + [Environment]::NewLine +
                       "are build $usmtBuild - newer than both machines (source $($sb.Build), destination $($db.Build))." +
                       [Environment]::NewLine + [Environment]::NewLine +
                       "USMT from a pre-release / Insider Windows ADK does not run on released Windows. scanstate exits " +
                       "immediately with a loader error and nothing is captured - a blank log." +
                       [Environment]::NewLine + [Environment]::NewLine +
                       "Fix: point USMT Location at USMT from a released ADK. Build 26100 (Windows 11 24H2) works across " +
                       "this fleet. Keep the tuned XML; swap only Microsoft's binaries." +
                       [Environment]::NewLine + [Environment]::NewLine + "Run anyway?"
                if ((Show-ThemedMessage $msg "USMT version mismatch" "YesNo" "Warning") -ne [System.Windows.Forms.DialogResult]::Yes) {
                    Append-Output "Run cancelled - USMT binaries (build $usmtBuild) are newer than the machines involved." $Script:T.Warning
                    Set-UIRunning $false; $Script:PendingImport = $null; return
                }
                Append-Output "$($Script:WarningSign) Proceeding with USMT build $usmtBuild against older machines - expect a loader failure." $Script:T.Warning
            }

            # ---- Config.xml (cross-build error-72 fix) ----
            # The 'auto' policy applies /config only when source and destination
            # run different Windows builds. Decide that here, once both are known
            # reachable, and say it plainly - the alternative is an opaque
            # error 72 several minutes into loadstate. 'no' skips the check,
            # 'yes' applies regardless.
            if ($newPC -and "$($Script:ConfigXmlMode)".Trim().ToLower() -ne "no") {
                if ($sb.Ok -and $db.Ok) {
                    if ($sb.Build -ne $db.Build) {
                        $Script:ConfigXmlBuildMismatch = $true
                        Append-Output "Windows builds differ - source $($sb.Display), destination $($db.Display)." $Script:AccentCyan
                        if (Should-ApplyConfigXml) {
                            Append-Output "Config.xml will be applied (/config) to exclude the components that abort loadstate with error 72." $Script:AccentCyan
                        } else {
                            Append-Output "$($Script:WarningSign) Config.xml policy is 'no', so /config is NOT applied despite the build mismatch. Set it to 'auto' or 'yes' in Settings if loadstate fails with error 72." $Script:T.Warning
                        }
                    } else {
                        Append-Output "Source and destination are the same Windows build ($($sb.Build)) - Config.xml not needed." $Script:T.TextDim
                    }
                } else {
                    Append-Output "Could not read the Windows build from both machines - Config.xml left as policy '$($Script:ConfigXmlMode)' ($(if (Should-ApplyConfigXml) { 'applied' } else { 'not applied' }))." $Script:T.TextDim
                }
            }

            # ---- Where the remote ScanState writes ----
            # Direct: a temporary share on the destination, so the store streams
            # off the source instead of filling its C: drive. If the share cannot
            # be created the run still goes ahead the old way rather than failing.
            $storeOverride = ""
            $Script:DirectShare = $null
            if (-not $p.IsNetwork) {
                # A drive letter on the machine being captured. ScanState writes
                # to it locally, so nothing is staged and nothing crosses the wire.
                $storeOverride = $destStorePath
                Append-Output "Store target: $destStorePath on $sourcePC (its own drive)" $Script:AccentCyan
            } elseif ($isCentral) {
                $storeOverride = $destStorePath
                Append-Output "Store target: $destStorePath (central)" $Script:T.TextDim
                # Worth saying plainly, because the failure mode is an opaque
                # access-denied several minutes into the capture.
                Append-Output "$sourcePC writes there as $(Get-MachineAccountName -ComputerName $sourcePC), so that share must grant Domain Computers write." $Script:T.TextDim
            } elseif ($p.IsNetwork) {
                try {
                    $Script:DirectShare = New-DestStoreShare -DestPC $newPC -SourcePC $sourcePC `
                        -LocalPath "C:\$($Script:AppConfig.DefaultStorePath)"
                    $storeOverride = Join-Path $Script:DirectShare.ShareUNC $p.Sub
                    Append-Output "Store target: $storeOverride (direct - nothing staged on $sourcePC)" $Script:AccentCyan
                } catch {
                    Append-Output "$($Script:WarningSign) Could not open a direct write path on $newPC`: $($_.Exception.Message)" $Script:T.Warning
                    Append-Output "Falling back to staging on $sourcePC, then copying across." $Script:T.Warning
                    Write-CrashLog "Direct share failed, falling back to staged copy: $($_.Exception.Message)"
                    $storeOverride = ""
                }
            }

            Append-Output "Staging USMT tools on $sourcePC..." $Script:AccentCyan
            $lblStatus.Text = "Staging tools on $sourcePC..."; $lblStatus.ForeColor = $Script:T.Primary
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $sessInfo = Invoke-RemoteExport -SourcePC $sourcePC -LocalUSMTPath $usmtPath `
                    -Username $username -AllProfiles $p.IsAll -ExcludeOneDrive $p.IsExcOD `
                    -Verbosity $p.Verbosity -Overwrite $p.Overwrite `
                    -SettingsOnly $isSettingsOnly `
                    -StorePathOverride $storeOverride `
                    -Extra $Script:ExtraExport -ArgOverride (Get-CommandOverride "Export") -Usernames $(if ($p.MultiUser) { $p.Usernames } else { @() })

                # Attach extra info the timer needs
                $sessInfo["DestStorePath"] = $destStorePath
                $sessInfo["DestPC"]        = $newPC
                $sessInfo["Username"]      = $username

                # For remote combo: replace the local-command PendingImport with remote params
                if ($isCombo) {
                    $Script:PendingImport = @{
                        IsRemote      = $true
                        DestPC        = $newPC
                        StorePath     = $importStorePath   # how the dest PC reaches the store
                        StoreUNC      = $destStorePath     # how this PC reaches it, for cleanup
                        Username      = $username
                        AllProfiles   = $p.IsAll
                        USMTPath      = $usmtPath
                        Verbosity     = $p.Verbosity
                        SettingsOnly  = $isSettingsOnly
                        # The import call reads all three. They were absent, and
                        # a missing hashtable key is $null rather than an error,
                        # so a remote combo restored one user and never renamed.
                        Usernames     = $(if ($p.MultiUser) { $p.Usernames } else { @() })
                        RenameFrom    = "$($p.RenameFrom)"
                        RenameTo      = "$($p.RenameTo)"
                    }
                }

                $Script:RemoteSession     = $sessInfo
                $Script:RemotePhase       = 1
                Reset-FileTail
                Append-Output "Scheduled task started on $sourcePC. Monitoring..." $Script:T.Success
                Append-Output "Tailing: $($sessInfo.ProgressUNC)" $Script:T.TextDim
                $lblStatus.Text = "Remote ScanState running on $sourcePC..."; $lblStatus.ForeColor = $Script:T.Primary
                $timer.Start()
            } catch {
                Remove-DestStoreShare $Script:DirectShare; $Script:DirectShare = $null
                Set-UIRunning $false; $Script:PendingImport = $null; $Script:RemotePhase = 0
                Show-ThemedMessage "Remote export setup failed:`n$($_.Exception.Message)" "Remote Error" "OK" "Error"
                Append-Output "Remote setup error: $($_.Exception.Message)" $Script:T.Error
            }
            return
        }

        # ---- LOCAL export path ----
        # No share needed here: ScanState runs as the technician, who already has
        # admin rights on the destination's C$.
        $localStorePath = $destStorePath
        # ScanState will not create missing PARENT folders - it fails with
        # "Invalid store path" and a path-not-found. This used to be attempted
        # with -ErrorAction SilentlyContinue, so a share we could not write to
        # produced a bare error 27 with no clue why.
        if (-not (Test-Path $localStorePath)) {
            try {
                New-Item -Path $localStorePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Append-Output "Created store folder $localStorePath" $Script:T.TextDim
            } catch {
                Set-UIRunning $false; $Script:PendingImport = $null
                Append-Output "Could not create the store folder: $($_.Exception.Message)" $Script:T.Error
                Show-ThemedMessage ("Could not create the store folder:`n$localStorePath`n`n$($_.Exception.Message)`n`n" +
                    "Check you have write access to that location.") "Store Folder" "OK" "Error"
                return
            }
        }
        $Script:LastCapture = @{
            StorePath = $localStorePath
            SourcePC  = $(if ($p.SourcePC) { $p.SourcePC } else { $env:COMPUTERNAME })
            DestPC    = "$($p.NewPC)"
            Users     = $(if ($p.MultiUser) { $p.Usernames } else { @($username) })
        }
        $exportCmd = Build-USMTCommand -USMTPath $usmtPath -Operation "Export" -StorePath $localStorePath -Username $username -AllProfiles $p.IsAll -ExcludeOneDrive $p.IsExcOD -Verbosity $p.Verbosity -Overwrite $p.Overwrite -SettingsOnly $isSettingsOnly `
                        -Extra $Script:ExtraExport -ArgOverride (Get-CommandOverride "Export") -Usernames $(if ($p.MultiUser) { $p.Usernames } else { @() })
        # The log that will prove, per user, what was actually captured. Without
        # it the post-capture deletion has only store-wide evidence to go on.
        $Script:LastCapture.LogFile = "$($exportCmd.LogFile)"
        $opLabel = if ($isSettingsOnly) { "computer settings" } else { "profile" }
        Append-Output "Exporting $opLabel to $localStorePath..." $Script:T.Primary
        $lblStatus.Text = "Exporting..."; $lblStatus.ForeColor = $Script:T.Primary
        Start-LocalOperation $exportCmd
    }

    # ---- Stop button ----
    $btnStop.Add_Click({
        $Script:CancelRequested = $true
        if ($Script:CurrentProcess -and -not $Script:CurrentProcess.HasExited) {
            try { $Script:CurrentProcess.Kill() } catch { }
        }
        if ($Script:RemotePhase -eq 1 -and $Script:RemoteSession) {
            $task = $Script:RemoteSession.Task
            try { & schtasks /end /s $task.PC /tn $task.TaskName 2>$null | Out-Null } catch { }
            Remove-RemoteTask -PC $task.PC -TaskName $task.TaskName
            # Save logs before wiping temp folder
            if ($Script:AppConfig.LogFolder) {
                $remoteLogsUNC = Join-Path (Get-RemoteTempUNC $task.PC) "Logs"
                if (Test-Path $remoteLogsUNC -ErrorAction SilentlyContinue) {
                    try { Copy-Item -Path "$remoteLogsUNC\*" -Destination $Script:AppConfig.LogFolder -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
            Remove-RemoteTempFolder -SourcePC $task.PC
        }
        if ($Script:RoboProcess -and -not $Script:RoboProcess.HasExited) {
            try { $Script:RoboProcess.Kill() } catch { }
        }
        Remove-DestStoreShare $Script:DirectShare; $Script:DirectShare = $null
        $timer.Stop(); Set-UIRunning $false
        $Script:RemoteSession = $null; $Script:RemotePhase = 0; $Script:PendingImport = $null
        $Script:CurrentLogFile = $null; $Script:CurrentProgressLog = $null
        $Script:ExportPlan = $null
        $lblStatus.ForeColor = $Script:T.Warning; $lblStatus.Text = "Cancelled"
        Append-Output "Operation cancelled by user." $Script:T.Warning
    })


    # =====================================================================
    #  Menu bar contents
    # =====================================================================
    # Built here, at the end, because every handler needs controls and
    # functions that are defined throughout the layout above.

    function Save-OutputLog {
        <#
            Writes the output pane to a file. The log folder is offered first
            because that is where the USMT logs already are, and keeping a
            run's narrative beside its detail logs is the point.
        #>
        param([string]$Path = "")
        if (-not $Path) {
            $sd = New-Object System.Windows.Forms.SaveFileDialog
            $sd.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
            $sd.FileName = "UTW_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            if ($Script:AppConfig.LogFolder -and (Test-Path $Script:AppConfig.LogFolder)) {
                $sd.InitialDirectory = $Script:AppConfig.LogFolder
            }
            if ($sd.ShowDialog($Form) -ne "OK") { return $false }
            $Path = $sd.FileName
        }
        try {
            $header = @(
                "User Transfer Wizard log",
                "Saved    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
                "By       : $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME",
                "Operation: $(Get-OperationText)",
                ("-" * 70), ""
            )
            ($header + ($txtOutput.Text -split "`r?`n")) | Out-File -FilePath $Path -Encoding UTF8 -Force
            Append-Output "Log saved to $Path" $Script:T.Success
            return $true
        } catch {
            Write-CrashLog "Could not save log: $($_.Exception.Message)"
            Show-ThemedMessage "Could not save the log:`n`n$($_.Exception.Message)" "Save log" "OK" "Warning"
            return $false
        }
    }

    function Show-SettingsEditor {
        <#
            The settings that live in UTW_Settings.json, editable without a text
            editor. Only the ones worth changing by hand are listed - the rest
            are remembered from the form and would be confusing to see twice.
        #>
        $t = $Script:T
        $d = New-ListDialog -Title "UTW Settings" -Width 780 -ListHeight 330 `
                -Heading "UTW settings" `
                -Subtitle "Set once for your site and remembered. Double-click a row to change it. The file in use is named at the bottom."
        $lv = $d.List
        [void]$lv.Columns.Add("Setting", 210)
        [void]$lv.Columns.Add("Value", 250)
        [void]$lv.Columns.Add("What it does", 288)
        # Sections are ROWS, not ListViewGroups.
        #
        # A ListViewGroup header is drawn by the OS in the system colours - dark
        # blue-grey text - and there is no property to change it short of taking
        # over drawing the whole control. On the dark list background those
        # headers were unreadable, which is the "settings headers too dark to
        # read". A section row is an ordinary item, so it takes the theme like
        # everything else; it carries no Tag, which is how the rest of the
        # dialog knows it is not a setting.
        $lv.ShowGroups = $false
        $gAcc = "Accounts and folders"
        $gRun = "How USMT is run"
        $gOD  = "OneDrive detection"
        $gChk = "Pre-flight thresholds"

        # name -> @{ Get; Set; Help; Group }
        $defs = [ordered]@{
            "Domain" = @{ Get = { $Script:AppConfig.Domain }
                          Set = { param($v) $Script:AppConfig.Domain = $v; $txtDomain.Text = $v }
                          Help = "Domain put in front of a username that has none"; Group = $gAcc }
            "Store folder name" = @{ Get = { $Script:AppConfig.DefaultStorePath }
                          Set = { param($v) $Script:AppConfig.DefaultStorePath = $v }
                          Help = "Folder under C:\ that holds captured stores"; Group = $gAcc }
            "Log folder" = @{ Get = { $Script:AppConfig.LogFolder }
                          Set = { param($v) $Script:AppConfig.LogFolder = $v; Set-LogPathDisplay $v }
                          Help = "Where USMT writes scanstate.log and progress.log"; Group = $gAcc
                          # Marks it as a path: the editor offers a folder
                          # picker and proves the folder is writable.
                          Folder = $true }
            "USMT verbosity" = @{ Get = { "$($Script:AppConfig.Verbosity)" }
                          Set = { param($v) $n=0; if ([int]::TryParse($v,[ref]$n) -and $n -ge 0) { $Script:AppConfig.Verbosity = $n } }
                          Help = "The /v: level. 13 is the useful default"; Group = $gRun }
            "Cross-build fix (Config.xml)" = @{ Get = { "$($Script:ConfigXmlMode)" }
                          Set = { param($v) $x = "$v".Trim().ToLower(); if ($x -in @('auto','yes','no')) { $Script:ConfigXmlMode = $x } }
                          Help = "auto / yes / no. Adds /config to scanstate and loadstate. 'auto' applies it only when the source and destination Windows builds differ - the case that hits error 72"; Group = $gRun }
            # These two were ALSO on the Expert panel. One home each, and this is
            # it - reachable without turning Expert mode on, beside every other
            # value you set once for the site.
            "Check OneDrive before a capture" = @{ Get = { if ($chkODDetect.Checked) { "yes" } else { "no" } }
                          Set = { param($v) $chkODDetect.Checked = ($v -match '^(y|yes|true|on|1)$') }
                          Help = "Look for OneDrive and offer to exclude it. yes / no"; Group = $gOD }
            "OneDrive group" = @{ Get = { $Script:OneDriveGroupName }
                          Set = { param($v) $Script:OneDriveGroupName = $v }
                          Help = "AD group whose members are treated as OneDrive users"; Group = $gOD }
            "OneDrive folders" = @{ Get = { $Script:OneDriveFolderPattern }
                          Set = { param($v) $Script:OneDriveFolderPattern = $v; $txtODPattern.Text = $v }
                          Help = "Wildcard for the folders. <user> means the profile name"; Group = $gOD }
            "Ask about OneDrive above (MB)" = @{ Get = { $txtODMin.Text.Trim() }
                          Set = { param($v) $n=0; if ([int]::TryParse($v,[ref]$n) -and $n -ge 0) { $txtODMin.Text = "$n" } }
                          Help = "Only prompt above this much data held on disk. 0 = always"; Group = $gOD }
            "Stale profile age (days)" = @{ Get = { "$($Script:PreflightInactiveDays)" }
                          Set = { param($v) $n=0; if ([int]::TryParse($v,[ref]$n) -and $n -gt 0) { $Script:PreflightInactiveDays = $n } }
                          Help = "Unused for this long before a profile is offered for deletion"; Group = $gChk }
            # Off by default, and the help says what turning it on costs. The
            # first real comparison spent half an hour and returned 5,000
            # differences, nearly all of them AppData rewriting its own caches.
            "Compare & Sync: include AppData" = @{ Get = { if ($Script:SyncIncludeAppData) { "yes" } else { "no" } }
                          Set = { param($v) $Script:SyncIncludeAppData = ("$v".Trim() -match '^(y|yes|true|1|on)$') }
                          Help = "yes/no. Adds AppData\Roaming to a comparison - much slower, and mostly program noise. Documents, Desktop and Downloads are always compared"; Group = $gChk }
            "Low disk warning (GB)" = @{ Get = { "$($Script:PreflightMinFreeGB)" }
                          Set = { param($v) $n=0; if ([int]::TryParse($v,[ref]$n) -and $n -gt 0) { $Script:PreflightMinFreeGB = $n } }
                          Help = "Warn when the destination has less free space than this"; Group = $gChk }
        }
        $fill = {
            $keep = if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Tag } else { $null }
            $lv.Items.Clear()
            $section = ""
            foreach ($k in $defs.Keys) {
                if ($defs[$k].Group -ne $section) {
                    $section = $defs[$k].Group
                    $hdr = New-Object System.Windows.Forms.ListViewItem($section)
                    $hdr.ForeColor = $Script:T.Primary
                    $hdr.Font = New-Object System.Drawing.Font($lv.Font, [System.Drawing.FontStyle]::Bold)
                    $hdr.Tag = $null                     # no Tag = not a setting
                    [void]$lv.Items.Add($hdr)
                }
                # Indented, so a section header and the settings under it read
                # as a group without needing a second column to say so.
                $it = New-Object System.Windows.Forms.ListViewItem("    $k")
                $val = "$(& $defs[$k].Get)"
                [void]$it.SubItems.Add($val)
                [void]$it.SubItems.Add($defs[$k].Help)
                # An unset value should look unset rather than like a blank one.
                # UseItemStyleForSubItems has to be off first or a sub-item's
                # own colour is ignored and the whole row is painted one shade.
                if (-not $val) {
                    $it.UseItemStyleForSubItems = $false
                    $it.SubItems[1].Text = "(not set)"
                    $it.SubItems[1].ForeColor = $Script:T.TextDim
                }
                $it.Tag = $k
                [void]$lv.Items.Add($it)
                if ($keep -eq $k) { $it.Selected = $true }
            }
        }
        & $fill
        $d.Status.Text = "$($defs.Count) settings - changes are saved when this window closes"

        $edit = {
            if ($lv.SelectedItems.Count -eq 0) { return }
            $k = $lv.SelectedItems[0].Tag
            # Section headers are rows too, and they carry no Tag.
            if (-not $k -or -not $defs.Contains($k)) { return }
            $cur = "$(& $defs[$k].Get)"
            $v = Show-InputDialog -Title "Change setting" -Prompt $k -Detail $defs[$k].Help -Value $cur `
                                  -BrowseFolder:([bool]$defs[$k].Folder)
            # A folder is proved WRITABLE before it is accepted. A log folder
            # that cannot be written is not discovered until USMT exits 13
            # several minutes into a capture, by which point the run is wasted.
            if ($null -ne $v -and $defs[$k].Folder -and $v.Trim()) {
                if (-not (Test-FolderWritable $v.Trim())) {
                    Show-ThemedMessage "That folder cannot be written to:`n$($v.Trim())`n`nPick another, or check your rights on it." "Log folder" "OK" "Warning"
                    return
                }
            }
            if ($null -ne $v) {
                & $defs[$k].Set $v
                & $fill
                $d.Status.Text = "$k changed - saved when the window closes"
            }
        }
        $btnEdit  = Add-DialogButton -Dialog $d -Text "Change..." -Right 132 -ButtonWidth 110 -Accent $t.Primary -Primary
        $btnClose = Add-DialogButton -Dialog $d -Text "Done" -Right 16 -ButtonWidth 108
        # WHOSE settings these are, and how to make them your own.
        #
        # The tool is deployed to a share, so the file beside the script is one
        # file for everybody - the last window closed decides what the next
        # person opens. These make that visible and give a way out of it that
        # does not involve editing JSON by hand.
        # ORDER, LEFT TO RIGHT: Reset | Save as... | Load... | Done.
        #
        # Done stays hard right. It is pressed every single time this dialog is
        # opened, and bottom-right is where every Windows dialog puts the button
        # that dismisses it - moving it inward would make the most-used control
        # the hardest to find and leave something else under the muscle memory.
        #
        # Reset stays hard left, behind the widest gap on the row. It is the only
        # button here that throws work away and the one pressed least, so it
        # wants to be nowhere near the one pressed by reflex.
        #
        # Save as and Load swap places: writing a file reads before reading one
        # back, and the two file actions sit together between the two extremes.
        $btnMine   = Add-DialogButton -Dialog $d -Text "Save as..." -Right 363 -ButtonWidth 105
        $btnImport = Add-DialogButton -Dialog $d -Text "Load..." -Right 250 -ButtonWidth 105
        $btnReset  = Add-DialogButton -Dialog $d -Text "Reset" -Right 476 -ButtonWidth 100
        $btnEdit.Enabled = $false

        # Hover tips. Two buttons that both move settings around need to say
        # which one does what without the operator having to try them: one
        # changes WHICH file is used, the other changes WHAT IS IN it.
        $tips = New-Object System.Windows.Forms.ToolTip
        $tips.AutoPopDelay = 12000; $tips.InitialDelay = 400; $tips.ReshowDelay = 200
        $tips.SetToolTip($btnMine,  "Save a copy of these settings to a file. Your settings are already saved automatically as you change them; this is for keeping a copy or giving one to someone else.")
        $tips.SetToolTip($btnImport,"Load settings from a file, replacing yours.")
        $tips.SetToolTip($btnReset, "Go back to the factory settings in UTW_Settings.json.")
        $tips.SetToolTip($btnEdit,  "Change the selected setting.")
        $tips.SetToolTip($btnClose, "Close this window. Every change here is already saved and already in force - there is nothing waiting to be applied.")

        $refreshOwner = {
            # Short, because this line sits in a fixed-width status bar and the
            # long version was cut off. The file name is the useful part; the
            # explanation lives on the buttons' hover tips.
            $d.Status.Text = "Settings: $(Split-Path (Get-CachePath) -Leaf)"
            $btnReset.Enabled = (Test-Path (Get-FactoryCachePath))
        }
        & $refreshOwner

        # ASK BEFORE REPLACING, instead of leaving files behind.
        #
        # Both Load and Reset overwrite what the operator has built up. This
        # offers to save it first and lets them name it - which is the same
        # safety the automatic _previous.json gave, without filling the
        # deployment folder with files nobody asked for. Returns $true to carry
        # on, $false to abandon.
        $keepFirst = {
            param([string]$What)
            $ans = Show-ThemedMessage -Title $What -Icon Question -Buttons YesNoCancel -Message @"
$What will replace the settings you are using now.

Yes     - save your current settings to a file first
No      - replace them without saving
Cancel  - do nothing
"@
            if ($ans -eq "Cancel") { return $false }
            if ($ans -eq "Yes") {
                [void](Save-SettingsCache)
                $sfd = New-Object System.Windows.Forms.SaveFileDialog
                $sfd.Title    = "Save your current settings"
                $sfd.Filter   = "UTW settings (*.json)|*.json"
                $sfd.FileName = "UTW_Settings_$(Get-SettingsUserName)_saved.json"
                try { $sfd.InitialDirectory = $Script:ScriptDir } catch { }
                if ($sfd.ShowDialog($d.Form) -ne "OK") { return $false }   # backed out of saving = backed out
                $e2 = Save-SettingsCopy -Path $sfd.FileName
                if ($e2) { [void](Show-ThemedMessage -Title $What -Icon Warning -Message $e2); return $false }
            }
            return $true
        }

        $btnMine.Add_Click({
            # Written first, so the copy holds what this window is set to right
            # now rather than whatever was last flushed to disk.
            [void](Save-SettingsCache)
            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Title    = "Save a copy of your settings"
            $sfd.Filter   = "UTW settings (*.json)|*.json"
            $sfd.FileName = Split-Path (Get-CachePath) -Leaf
            try { $sfd.InitialDirectory = $Script:ScriptDir } catch { }
            if ($sfd.ShowDialog($d.Form) -ne "OK") { return }
            $err = Save-SettingsCopy -Path $sfd.FileName
            if ($err) { [void](Show-ThemedMessage -Title "Save settings" -Icon Warning -Message $err); return }
            [void](Show-ThemedMessage -Title "Save settings" -Icon Information `
                -Message "Saved a copy to $(Split-Path $sfd.FileName -Leaf).`n`nThis window carries on using your own settings.")
        })

        $btnReset.Add_Click({
            if (-not (& $keepFirst "Reset to factory settings")) { return }
            $err = Reset-ToFactorySettings
            if ($err) { [void](Show-ThemedMessage -Title "Reset" -Icon Warning -Message $err); return }
            # Applied to THIS window. The file underneath it has changed, so the
            # form is put back in step immediately rather than leaving the two
            # disagreeing until somebody opens a new window.
            try { Restore-SettingsToForm } catch { Write-CrashLog "Re-apply after reset failed: $($_.Exception.Message)" }
            # AND THIS LIST. Restoring puts the main window back in step, but the
            # rows here were read when the dialog opened and would sit there
            # showing the settings that have just been replaced - which reads as
            # the reset not having worked.
            & $fill
            # Not "Done" - that is the button behind this box, and the same word
            # twice on screen reads as the dialog answering itself.
            [void](Show-ThemedMessage -Title "Reset" -Icon Information -Message "Settings reset to factory defaults.")
            & $refreshOwner
        })

        $btnImport.Add_Click({
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Title  = "Load settings"
            # .json only, and it means it: whatever is picked still has to parse
            # as JSON and hold settings this tool knows, so a filter that offers
            # anything else only promises more than the load will accept.
            $ofd.Filter = "UTW settings (*.json)|*.json"
            try { $ofd.InitialDirectory = $Script:ScriptDir } catch { }
            if ($ofd.ShowDialog($d.Form) -ne "OK") { return }
            # The offer to keep what they have comes BEFORE anything is written.
            if (-not (& $keepFirst "Loading $(Split-Path $ofd.FileName -Leaf)")) { return }
            $err = Import-SettingsFile -Path $ofd.FileName
            if ($err) {
                [void](Show-ThemedMessage -Title "Load settings" -Icon Warning -Message $err)
                return
            }
            try { Restore-SettingsToForm } catch { Write-CrashLog "Re-apply after load failed: $($_.Exception.Message)" }
            & $fill          # the rows here, too - see the note under Reset
            & $refreshOwner
            [void](Show-ThemedMessage -Title "Load settings" -Icon Information -Message "Loaded.")
        })
        $lv.Add_SelectedIndexChanged({
            $btnEdit.Enabled = ($lv.SelectedItems.Count -gt 0) -and [bool]$lv.SelectedItems[0].Tag
        })
        $lv.Add_DoubleClick($edit)
        $btnEdit.Add_Click($edit)
        $frmS = $d.Form
        $btnClose.Add_Click({ $frmS.Close() })
        $d.Form.CancelButton = $btnClose
        [void](Show-ListDialog -Dialog $d)
        Update-CommandPreview -Force
    }

    $Script:ZoneNames = [ordered]@{
        "Left"        = "Left column"
        "RightTop"    = "Right column, top"
        "RightBottom" = "Right column, bottom"
    }

    function Reset-PanelLayout {
        # The shipped arrangement. Kept here rather than only in the Register-
        # Panel calls so "put it back" cannot drift away from "how it started".
        $defaults = @{
            Header = @("Left", 10, $true);  Tools   = @("Left", 20, $true)
            Operation = @("Left", 30, $true); Details = @("Left", 40, $true)
            Options = @("Left", 50, $true); Expert  = @("Left", 60, $Script:ExpertVisible)
            Actions = @("Left", 70, $true);  Plan    = @("Left", 80, $true)
            Lookup  = @("RightTop", 10, $true)
            Output  = @("RightBottom", 10, $true)
        }
        foreach ($p in $Script:Panels) {
            if ($defaults.ContainsKey($p.Key)) {
                $d = $defaults[$p.Key]
                $p.Zone = $d[0]; $p.Order = $d[1]; $p.Shown = [bool]$d[2]
            }
        }
        $Script:SetupColumnWidth = [int](($Script:SetupDesignWidth + 17) * $Script:UIScale)
        Update-Layout
        Set-SplitterLayout
    }

    function Show-LayoutEditor {
        <#
            Move a panel to another zone, reorder it, or put it away.

            Drag a row to move it - anywhere within its zone to reorder, or onto
            another zone's heading to send it there. Or click the "Where" cell
            and pick from a list. Both do the same thing; the drag is faster once
            you know it is there and the cell is discoverable if you do not.

            Not free-form docking - you cannot drop a panel anywhere on the
            window and split arbitrarily. It is zone placement plus ordering
            plus the two dividers, which is what fits in a WinForms app without
            carrying a docking framework.
        #>
        $t = $Script:T
        $d = New-ListDialog -Title "Customize layout" -Width 720 -ListHeight 340 `
                -Heading "Where each panel goes" `
                -Subtitle "Drag a row to move it, or click its Where cell to pick a zone. Drag the dividers in the window itself to size the zones. Remembered when you close the tool."
        $lv = $d.List
        [void]$lv.Columns.Add("Panel", 250)
        [void]$lv.Columns.Add("Where", 250)
        [void]$lv.Columns.Add("Position", 98)
        $lv.AllowDrop = $true
        $lv.HideSelection = $false

        # Rows are either a zone HEADING or a panel; the Tag says which. Zone
        # headings are what makes dragging between zones work - there is
        # somewhere to drop onto even when a zone is empty.
        $fill = {
            $keep = $null
            if ($lv.SelectedItems.Count -and $lv.SelectedItems[0].Tag -and $lv.SelectedItems[0].Tag.Kind -eq "panel") {
                $keep = $lv.SelectedItems[0].Tag.Key
            }
            $lv.BeginUpdate()
            try {
                $lv.Items.Clear()
                foreach ($zk in $Script:ZoneNames.Keys) {
                    $hdr = New-Object System.Windows.Forms.ListViewItem($Script:ZoneNames[$zk])
                    [void]$hdr.SubItems.Add(""); [void]$hdr.SubItems.Add("")
                    $hdr.ForeColor = $Script:T.Primary
                    $hdr.Font = New-Object System.Drawing.Font($lv.Font, [System.Drawing.FontStyle]::Bold)
                    $hdr.Tag = @{ Kind = "zone"; Zone = $zk }
                    [void]$lv.Items.Add($hdr)
                    $n = 1
                    foreach ($pp in @($Script:Panels | Where-Object { $_.Zone -eq $zk -and $_.Shown } | Sort-Object Order)) {
                        $it = New-Object System.Windows.Forms.ListViewItem("    $($pp.Title)")
                        [void]$it.SubItems.Add($Script:ZoneNames[$zk])
                        [void]$it.SubItems.Add("$n")
                        $it.Tag = @{ Kind = "panel"; Key = $pp.Key }
                        [void]$lv.Items.Add($it)
                        if ($keep -eq $pp.Key) { $it.Selected = $true }
                        $n++
                    }
                }
                $hidden = @($Script:Panels | Where-Object { -not $_.Shown })
                if ($hidden.Count -gt 0) {
                    $hdr = New-Object System.Windows.Forms.ListViewItem("Hidden")
                    [void]$hdr.SubItems.Add(""); [void]$hdr.SubItems.Add("")
                    $hdr.ForeColor = $Script:T.TextDim
                    $hdr.Font = New-Object System.Drawing.Font($lv.Font, [System.Drawing.FontStyle]::Bold)
                    $hdr.Tag = @{ Kind = "zone"; Zone = "Hidden" }
                    [void]$lv.Items.Add($hdr)
                    foreach ($pp in $hidden) {
                        $it = New-Object System.Windows.Forms.ListViewItem("    $($pp.Title)")
                        [void]$it.SubItems.Add("Hidden"); [void]$it.SubItems.Add("-")
                        $it.ForeColor = $Script:T.TextDim
                        $it.Tag = @{ Kind = "panel"; Key = $pp.Key }
                        [void]$lv.Items.Add($it)
                        if ($keep -eq $pp.Key) { $it.Selected = $true }
                    }
                }
            } finally { $lv.EndUpdate() }
            $d.Status.Text = "$(@($Script:Panels | Where-Object { $_.Shown }).Count) of $($Script:Panels.Count) panels shown"
        }

        # Renumbering in tens leaves room to slot a panel between two others
        # without touching the rest.
        $renumber = {
            param([string]$Zone)
            $n = 10
            foreach ($pp in @($Script:Panels | Where-Object { $_.Zone -eq $Zone } | Sort-Object Order)) { $pp.Order = $n; $n += 10 }
        }
        # Actions and the header can be moved but not removed: without them
        # there is no way to start a migration and no way back to Expert mode.
        $canHide = { param($Key) return ($Key -notin @("Actions", "Header")) }

        $place = {
            param([string]$Key, [string]$Zone, [int]$BeforeOrder = -1)
            $pp = $Script:Panels | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
            if (-not $pp) { return }
            if ($Zone -eq "Hidden") {
                if (-not (& $canHide $Key)) { return }
                $old = $pp.Zone; $pp.Shown = $false; & $renumber $old
            } else {
                $old = $pp.Zone
                $pp.Zone = $Zone; $pp.Shown = $true
                if ($BeforeOrder -ge 0) {
                    # Half a step in front of the row it was dropped on, then
                    # the whole zone is renumbered back into whole tens.
                    $pp.Order = $BeforeOrder - 5
                } else {
                    $mx = @($Script:Panels | Where-Object { $_.Zone -eq $Zone -and $_.Key -ne $Key } |
                            ForEach-Object { $_.Order } | Measure-Object -Maximum).Maximum
                    $pp.Order = [int]$mx + 10
                }
                if ($old -ne $Zone) { & $renumber $old }
                & $renumber $Zone
            }
            Update-Layout
            if ($pp.Shown -and $pp.Zone -like "Right*") { Set-RightSplitter -Reset }
            & $fill
        }

        # ---- clicking the Where cell ----
        # A ListView has no per-cell click, so the column is worked out from the
        # x of the click against the column widths.
        $pickZone = {
            param([string]$Key)
            $pp = $Script:Panels | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
            if (-not $pp) { return }
            $choices = @()
            foreach ($zk in $Script:ZoneNames.Keys) {
                $here = ($pp.Shown -and $pp.Zone -eq $zk)
                $choices += @{ Key = $zk; Text = $Script:ZoneNames[$zk]
                               Accent = $(if ($here) { $Script:T.Primary } else { $null })
                               Hint = $(if ($here) { "Where it is now." } else { "" }) }
            }
            if (& $canHide $Key) {
                $choices += @{ Key = "Hidden"; Text = "Hide it"; Accent = $Script:AccentStone
                               Hint = "Stays in this list - bring it back from here." }
            }
            $choices += @{ Key = "Cancel"; Text = "Cancel"; IsCancel = $true }
            $pick = Show-ChoiceDialog -Title "Move $($pp.Title)" -Glyph ([string][char]0x25A6) `
                        -Heading "Where should '$($pp.Title)' go?" `
                        -Message "The panel keeps everything it does; only where it sits changes." `
                        -Choices $choices
            if (-not $pick -or $pick -eq "Cancel") { return }
            & $place $Key $pick
        }

        $lv.Add_MouseClick({
            param($lvSender, $e)
            $hit = $lv.GetItemAt($e.X, $e.Y)
            if (-not $hit -or -not $hit.Tag -or $hit.Tag.Kind -ne "panel") { return }
            $x = 0
            for ($i = 0; $i -lt $lv.Columns.Count; $i++) {
                $x += $lv.Columns[$i].Width
                if ($e.X -lt $x) { if ($i -eq 1) { & $Script:LayoutPickZone $hit.Tag.Key }; break }
            }
        })
        $Script:LayoutPickZone = $pickZone

        # ---- drag to move ----
        $lv.Add_ItemDrag({
            param($lvSender, $e)
            if ($e.Item.Tag -and $e.Item.Tag.Kind -eq "panel") {
                [void]$lv.DoDragDrop($e.Item, [System.Windows.Forms.DragDropEffects]::Move)
            }
        })
        $lv.Add_DragEnter({
            param($lvSender, $e)
            if ($e.Data.GetDataPresent([System.Windows.Forms.ListViewItem])) {
                $e.Effect = [System.Windows.Forms.DragDropEffects]::Move
            }
        })
        $lv.Add_DragOver({
            param($lvSender, $e)
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Move
            # An insertion mark rather than a highlight: it says WHERE the row
            # will land, which is the whole question when reordering.
            $pt = $lv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
            $over = $lv.GetItemAt($pt.X, $pt.Y)
            if ($over) {
                $lv.InsertionMark.Index = $over.Index
                $lv.InsertionMark.AppearsAfterItem = ($pt.Y -gt ($over.Bounds.Top + ($over.Bounds.Height / 2)))
            } else { $lv.InsertionMark.Index = -1 }
        })
        $lv.Add_DragLeave({ $lv.InsertionMark.Index = -1 })
        $lv.Add_DragDrop({
            param($lvSender, $e)
            $lv.InsertionMark.Index = -1
            if (-not $e.Data.GetDataPresent([System.Windows.Forms.ListViewItem])) { return }
            $src = $e.Data.GetData([System.Windows.Forms.ListViewItem])
            if (-not $src -or -not $src.Tag -or $src.Tag.Kind -ne "panel") { return }
            $pt = $lv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
            $over = $lv.GetItemAt($pt.X, $pt.Y)
            if (-not $over) {
                # Dropped past the last row: send it to the end of the last zone
                # it can go to rather than doing nothing.
                if ($lv.Items.Count -gt 0) { $over = $lv.Items[$lv.Items.Count - 1] } else { return }
            }
            if ($over -eq $src) { return }

            if ($over.Tag.Kind -eq "zone") {
                # Onto a zone heading = the top of that zone.
                $first = @($Script:Panels | Where-Object { $_.Zone -eq $over.Tag.Zone -and $_.Shown } | Sort-Object Order | Select-Object -First 1)
                $before = if ($first) { $first[0].Order } else { -1 }
                & $Script:LayoutPlace $src.Tag.Key $over.Tag.Zone $before
                return
            }
            # Onto another panel = that panel's zone, in front of or behind it.
            $target = $Script:Panels | Where-Object { $_.Key -eq $over.Tag.Key } | Select-Object -First 1
            if (-not $target) { return }
            $zone = if ($target.Shown) { $target.Zone } else { "Hidden" }
            $after = ($pt.Y -gt ($over.Bounds.Top + ($over.Bounds.Height / 2)))
            $before = if ($zone -eq "Hidden") { -1 } elseif ($after) { $target.Order + 5 } else { $target.Order }
            & $Script:LayoutPlace $src.Tag.Key $zone $before
        })
        $Script:LayoutPlace = $place

        & $fill

        # Only two buttons left. "Move up", "Move down" and "Move to..." all did
        # what dragging a row and clicking the Where cell now do directly, and a
        # button that repeats a direct manipulation sitting right next to it is
        # exactly the redundancy worth removing.
        $btnRst  = Add-DialogButton -Dialog $d -Text "Reset" -Right 130 -ButtonWidth 112
        $btnDone = Add-DialogButton -Dialog $d -Text "Close" -Right 16  -ButtonWidth 108
        $btnRst.Add_Click({ Reset-PanelLayout; Set-RightSplitter -Reset; & $Script:LayoutFill })
        $Script:LayoutFill = $fill
        $frmL = $d.Form
        $btnDone.Add_Click({ $frmL.Close() })
        $d.Form.CancelButton = $btnDone
        [void](Show-ListDialog -Dialog $d)
    }

    function Get-LayoutString {
        # One flat string, so the settings file stays two levels deep and
        # ConvertTo-Json -Depth 2 does not silently truncate it to "System.Object[]".
        return (($Script:Panels | ForEach-Object { "$($_.Key)=$($_.Zone):$($_.Order):$(if ($_.Shown) { 1 } else { 0 })" }) -join ";")
    }
    function Set-LayoutString {
        param([string]$Text)
        if (-not $Text) { return }
        foreach ($chunk in ($Text -split ';')) {
            if ($chunk -notmatch '^([A-Za-z]+)=([A-Za-z]+):(-?\d+):([01])$') { continue }
            $p = $Script:Panels | Where-Object { $_.Key -eq $Matches[1] } | Select-Object -First 1
            if (-not $p) { continue }                       # a panel from a newer build
            if (-not $Script:ZoneNames.Contains($Matches[2])) { continue }
            $p.Zone = $Matches[2]; $p.Order = [int]$Matches[3]
            $p.Shown = ($Matches[4] -eq '1')
        }
        # Expert is owned by the mode, not by the saved layout: a window that
        # opens in Simple must not show the Expert panel because it was on
        # screen last time.
        $ex = $Script:Panels | Where-Object { $_.Key -eq "Expert" } | Select-Object -First 1
        if ($ex) { $ex.Shown = $Script:ExpertVisible }
        Update-Layout
    }

    function Show-AboutDialog {
        <#
            A real dialog rather than a MessageBox.

            The old one padded its labels with spaces to fake a column - "On
            :", "Elevated   :" - which only lines up in a monospace font, and a
            MessageBox is not one. The result was a ragged gap of four or five
            spaces before some colons and none before others. Two columns of
            actual controls line up in every font at every scale, and the box
            can carry the theme instead of the system grey.
        #>
        $t = $Script:T
        $W = 560
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "About User Transfer Wizard"
        $dlg.FormBorderStyle = "FixedDialog"
        $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
        $dlg.StartPosition = "CenterParent"; $dlg.ShowInTaskbar = $false
        $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
        $dlg.BackColor = $t.DarkBg; $dlg.ForeColor = $t.Text
        try { $dlg.Icon = New-AppIcon } catch { }

        $pad   = 24
        $inner = $W - (2 * $pad)
        $fH    = New-UTWFont "Display" ([System.Drawing.FontStyle]::Bold)
        $fB    = New-UTWFont 9
        $fS    = New-UTWFont "Small"

        # Heights are MEASURED, not guessed. The previous version gave the
        # description a flat 56px and the footer 34px, and at any font or scale
        # where those wrapped to one line more than expected the text was cut
        # off mid-sentence - which is what made the dialog look ragged. Every
        # block below asks GDI+ how tall it actually needs to be for the width
        # it has been given, and the dialog is sized from the running total.
        $g = $dlg.CreateGraphics()
        $measure = {
            param([string]$Text, $Font, [int]$Width)
            $sz = [System.Windows.Forms.TextRenderer]::MeasureText(
                    $g, $Text, $Font,
                    (New-Object System.Drawing.Size($Width, 2000)),
                    ([System.Windows.Forms.TextFormatFlags]::WordBreak))
            return ([int]$sz.Height + 2)
        }
        $addLabel = {
            param([string]$Text, $Font, $Colour, [int]$X, [int]$Y, [int]$Width, [switch]$Right)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Colour
            $l.AutoSize = $false
            $l.TextAlign = if ($Right) { "TopRight" } else { "TopLeft" }
            $l.Location = New-Object System.Drawing.Point($X, $Y)
            $l.Size = New-Object System.Drawing.Size($Width, (& $measure $Text $Font $Width))
            $dlg.Controls.Add($l)
            return $l
        }

        $y = 22
        $y += (& $addLabel "User Transfer Wizard" $fH $t.Primary $pad $y $inner).Height + 8
        # No organisation name. The sanitisation pass swapped the old one for the
        # theme name and left this reading "migrations at Neo", which is not a
        # place - and naming any single site is wrong for a tool other people
        # will run anyway.
        $blurb = "A front end for Microsoft's User State Migration Tool, built for desktop services teams doing PC-refresh migrations. It drives ScanState and LoadState, locally or on another machine, and keeps the record of what it did."
        $y += (& $addLabel $blurb $fB $t.TextDim $pad $y $inner).Height + 14

        $rule = New-Object System.Windows.Forms.Panel
        $rule.Location = New-Object System.Drawing.Point($pad, $y)
        $rule.Size = New-Object System.Drawing.Size($inner, 1)
        $rule.BackColor = (Get-DividerColor)
        $dlg.Controls.Add($rule)
        $y += 14

        # Two real columns. The label column is a fixed gutter with the text
        # right-aligned in it, so every colon lands on the same x - which is
        # what the old space-padded "On         :" was trying and failing to do,
        # because a proportional font gives a space no fixed width.
        # An ORDERED DICTIONARY, not an array of pairs.
        #
        # This was written as nested @(...) arrays one per LINE, and nested
        # arrays laid out that way do not stay nested: each inner array is its
        # own statement, its output unrolls onto the pipeline, and the result is
        # one flat list of twelve strings. $row was then a string like
        # "Running as", so $row[0] was the CHARACTER 'R' - and the dialog drew
        # twelve rows reading "R:" / "u", "O:" / "n". That is exactly the
        # "random letters everywhere". (Comma-separated it would have stayed
        # nested; a dictionary cannot flatten at all, so it cannot come back.)
        $rows = [ordered]@{
            "Running as"  = "$env:USERDOMAIN\$env:USERNAME"
            "On"          = $env:COMPUTERNAME
            "Elevated"    = $(if ($Script:IsElevated) { "yes" } else { "no - some remote operations will fail" })
            "This window" = "#$($Script:InstanceNumber)   (PID $PID)"
            "USMT folder" = $(if ($txtUSMTPath.Text.Trim() -and $txtUSMTPath.Text -notmatch '^\(') { $txtUSMTPath.Text.Trim() } else { "not set" })
            "Log folder"  = $(if ($Script:AppConfig.LogFolder) { $Script:AppConfig.LogFolder } else { "not set" })
        }
        # The gutter is measured from the longest key, so it fits whatever the
        # theme's font does rather than assuming 96px is enough.
        # $keyW, NOT $w. PowerShell variable names are case-INSENSITIVE, so a
        # loop counter called $w silently overwrote $W - the dialog's width.
        $gutter = 0
        foreach ($key in $rows.Keys) {
            $keyW = [System.Windows.Forms.TextRenderer]::MeasureText($g, "${key}:", $fB).Width
            if ($keyW -gt $gutter) { $gutter = $keyW }
        }
        $gutter += 6
        $valX = $pad + $gutter + 10
        $valW = $W - $pad - $valX
        foreach ($key in $rows.Keys) {
            $val  = "$($rows[$key])"
            $rowH = [Math]::Max((& $measure "${key}:" $fB $gutter), (& $measure $val $fB $valW))
            $k = & $addLabel "${key}:" $fB $t.TextDim $pad $y $gutter -Right
            $k.Height = $rowH
            $v = & $addLabel $val $fB $t.Text $valX $y $valW
            $v.Height = $rowH
            $v.AutoEllipsis = $true
            try { $Script:PathTip.SetToolTip($v, $val) } catch { }
            $y += $rowH + 6
        }
        $g.Dispose()

        $y += 10
        $btnOK = New-Object System.Windows.Forms.Button
        $btnOK.Text = "Close"
        $btnOK.Font = New-UTWFont "Base" ([System.Drawing.FontStyle]::Bold)
        $btnOK.Size = New-Object System.Drawing.Size(108, 30)
        $btnOK.Location = New-Object System.Drawing.Point(($W - $pad - 108), $y)
        $btnOK.FlatStyle = "Flat"; $btnOK.FlatAppearance.BorderSize = 0
        $btnOK.BackColor = $t.Primary; $btnOK.ForeColor = (Get-ContrastingText $t.Primary)
        $dlg.Controls.Add($btnOK)
        $btnOK.Add_Click({ $dlg.Close() })
        $dlg.AcceptButton = $btnOK; $dlg.CancelButton = $btnOK

        $lblL = New-Object System.Windows.Forms.Label
        $lblL.Text = "Help > UTW notes explains how remote captures work and what each failure means."
        $lblL.Font = $fS; $lblL.ForeColor = $t.TextDim; $lblL.AutoSize = $false
        $lblL.TextAlign = "MiddleLeft"
        $lblL.Location = New-Object System.Drawing.Point($pad, $y)
        $lblL.Size = New-Object System.Drawing.Size(($W - $pad - $pad - 120), 30)
        $dlg.Controls.Add($lblL)

        $dlg.ClientSize = New-Object System.Drawing.Size($W, ($y + 30 + $pad))
        Set-FormScale -Form $dlg -Factor $Script:UIScale
    Set-DoubleBuffered -Control $dlg
        if ($Script:DwmAvailable) {
            $dlg.Add_HandleCreated({ try { [DwmHelper]::SetDarkTitleBar($dlg.Handle, $Script:T.DarkTitle) } catch { } })
        }
        [void]$dlg.ShowDialog($Form)
        $dlg.Dispose()
    }

    # ---- File ----
    [void]$miFile.DropDownItems.Add((New-MenuItem "&New window" { Invoke-NewWindow } "Control, N"))
    [void]$miFile.DropDownItems.Add((New-MenuSeparator))
    # Named for the pane it saves, to match the group box and the context menu.
    [void]$miFile.DropDownItems.Add((New-MenuItem "&Save output log..." { [void](Save-OutputLog) } "Control, S"))
    # "Open log folder" is NOT here. It was the third way to reach the same
    # folder: the Actions bar has a permanently visible button for it, and the
    # log path in the Status bar opens it on a click. Two is a convenience;
    # three was the menu repeating what the window was already showing.
    # Reads the two computer boxes the rest of the window already uses, so it
    # needs no fields of its own.
    [void]$miFile.DropDownItems.Add((New-MenuItem "Compare installed &programs..." { Invoke-ProgramCompare }))
    [void]$miFile.DropDownItems.Add((New-MenuSeparator))
    [void]$miFile.DropDownItems.Add((New-MenuItem "Se&ttings..." { Show-SettingsEditor }))
    [void]$miFile.DropDownItems.Add((New-MenuSeparator))
    [void]$miFile.DropDownItems.Add((New-MenuItem "E&xit" { $Form.Close() }))

    # ---- View ----
    # There is deliberately no Simple/Expert pair in this menu.
    #
    # Expert mode does exactly one thing - it shows the Expert panel - and it
    # had grown three controls: the header button, two menu items here, and its
    # entry in View > Panels. Three ways to set one boolean, which is what made
    # it feel untidy. It is now the header toggle plus its entry in Panels, the
    # same two places every other panel has, and both mean the same thing.

    # Theme lives here now rather than as a third picker in the header. One
    # item per theme, ticked to show the current one - which also reads better
    # than a dropdown for something changed once and then forgotten.
    $miTheme = New-MenuItem "&Theme"
    $Script:ThemeMenuItems = @{}
    foreach ($name in (Get-ThemeNames)) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($name)
        $item.Tag = $name
        $item.Add_Click({
            $cmbTheme.SelectedItem = $this.Tag    # the combo still owns the change
        })
        # Built with New-Object, so it does NOT get the colours New-MenuItem
        # applies - and a ToolStripMenuItem defaults to black text, which on the
        # dark panel the renderer paints behind it was unreadable. This was the
        # "theme selector text is odd and dark".
        Set-StripItemColors $item
        $Script:ThemeMenuItems[$name] = $item
        [void]$miTheme.DropDownItems.Add($item)
    }
    # Background graphics, per theme, off by default.
    [void]$miTheme.DropDownItems.Add((New-MenuSeparator))
    $miOverlay = New-MenuItem "Background &graphics" {
        Set-OverlayEnabled (-not $Script:OverlayEnabled)
    }
    Set-StripItemColors $miOverlay
    [void]$miTheme.DropDownItems.Add($miOverlay)
    # Motion is its own switch. Some people want the artwork and not the
    # movement, and over a remote session the movement is the expensive half.
    # "Animate the background" described only the banner. The backdrop drifts
    # too, and the splash and the dialog headers are still pictures - so the
    # switch turns MOTION on and off across the tool, and says so.
    $miAnimate = New-MenuItem "Enable &animations" {
        Set-OverlayAnimate (-not $Script:OverlayAnimate)
    }
    Set-StripItemColors $miAnimate
    [void]$miTheme.DropDownItems.Add($miAnimate)
    # A mode, not a style. XAML mode puts ONE continuous backdrop behind the
    # whole window; turning it off gives every surface its own copy of the
    # artwork. Both are drawn by the GDI+ painters - a per-theme <theme>.xaml
    # in xaml\ overrides the header render when one is present, but none ship,
    # so the difference the switch makes is the layout, not the picture.
    $miXaml = New-MenuItem "&XAML mode" {
        $Script:UseXamlArt = -not $Script:UseXamlArt
        Set-OverlayEnabled $Script:OverlayEnabled
    }
    Set-StripItemColors $miXaml
    [void]$miTheme.DropDownItems.Add($miXaml)
    $miTheme.Add_DropDownOpening({
        $cur = $cmbTheme.SelectedItem.ToString()
        foreach ($k in $Script:ThemeMenuItems.Keys) { $Script:ThemeMenuItems[$k].Checked = ($k -eq $cur) }
        $miOverlay.Checked = $Script:OverlayEnabled
        $miAnimate.Checked = $Script:OverlayAnimate
        $miXaml.Checked = $Script:UseXamlArt
        $miXaml.Enabled = $Script:OverlayEnabled
        # Nothing to animate unless the artwork is on and the theme has motion.
        $miAnimate.Enabled = $Script:OverlayEnabled -and ($Script:AnimatedThemes -contains $cmbTheme.SelectedItem.ToString())
    })
    [void]$miView.DropDownItems.Add($miTheme)
    [void]$miView.DropDownItems.Add((New-MenuSeparator))

    # ---- Panels ----
    # One checkable entry per panel, so any box in the window can be put away
    # or brought back in two clicks.
    #
    # The "narrow / normal / wide setup column" entries that used to be here are
    # gone. All they did was move the divider to one of three positions, which
    # is a worse version of dragging the divider - the thing they were sitting
    # next to. A menu entry has to do something the direct manipulation cannot.
    $miLayout = New-MenuItem "&Panels"
    $Script:PanelMenuItems = @{}
    foreach ($pd in $Script:Panels) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem($pd.Title)
        $it.Tag = $pd.Key
        $it.Add_Click({
            $key = "$($this.Tag)"
            # Expert visibility IS the mode, so that entry drives the mode
            # rather than the panel - otherwise the toggle in the header and
            # this menu entry would disagree with each other.
            if ($key -eq "Expert") {
                if ($rbExpert.Checked) { $rbSimple.Checked = $true } else { $rbExpert.Checked = $true }
                return
            }
            $pp = $Script:Panels | Where-Object { $_.Key -eq $key } | Select-Object -First 1
            if (-not $pp) { return }
            # Actions and the header stay: without them there is no way to start
            # a migration and no way to get back to Expert mode.
            if ($key -in @("Actions", "Header") -and $pp.Shown) { return }
            $pp.Shown = -not $pp.Shown
            Update-Layout
            if ($pp.Shown -and $pp.Zone -like "Right*") { Set-RightSplitter -Reset }
        })
        Set-StripItemColors $it
        $Script:PanelMenuItems[$pd.Key] = $it
        [void]$miLayout.DropDownItems.Add($it)
    }
    [void]$miLayout.DropDownItems.Add((New-MenuSeparator))
    [void]$miLayout.DropDownItems.Add((New-MenuItem "&Customize layout..." { Show-LayoutEditor }))
    [void]$miLayout.DropDownItems.Add((New-MenuItem "&Reset the layout" {
        # Everything back to the shipped positions, for when a panel or a
        # divider has been put somewhere unhelpful and undoing it is fiddly.
        try { Reset-PanelLayout; Set-RightSplitter -Reset } catch { }
    }))
    $miLayout.Add_DropDownOpening({
        try {
            foreach ($pd in $Script:Panels) {
                $it = $Script:PanelMenuItems[$pd.Key]
                if (-not $it) { continue }
                $it.Checked = $pd.Shown
                # Greyed rather than missing, so it is clear these two are
                # deliberately not removable rather than accidentally absent.
                $it.Enabled = ($pd.Key -notin @("Actions", "Header"))
            }
        } catch { }
    })
    [void]$miView.DropDownItems.Add($miLayout)

    function Set-TouchTargets {
        <#
            Bigger everything, for a screen being poked rather than clicked.

            The common case is this tool driven over RDP from a phone, where the
            buttons are a few millimetres across and a mis-tap can start a
            migration. 1.25 is enough to bring a 30px button up to roughly the
            9mm that a fingertip actually covers, without pushing the layout off
            a small screen.

            It goes through the same rescale the display watchdog uses, which is
            measured against a natively-built window - so touch mode is not a
            second layout with its own bugs, it is the layout at another factor.
        #>
        param([bool]$On)
        $Script:TouchBoost = if ($On) { 1.25 } else { 1.0 }
        try {
            $want = Get-TargetUiScale (Get-DisplayDpi $Form)
            [void](Invoke-DisplayRescale -Form $Form -NewScale $want)
            # SplitterWidth is a property, not a bound, so Form.Scale() does not
            # touch it - the one thing in the window that would have stayed
            # mouse-sized. It is the hardest thing on the form to hit already.
            if ($split) { $split.SplitterWidth = [Math]::Max(4, [int](6 * $Script:LayoutScale)) }
        } catch { Write-CrashLog "Touch targets failed: $($_.Exception.Message)" }
        Request-SettingsSave
    }

    function Set-StackedLayout {
        <#
            Side by side, or one above the other.

            Explicit rather than automatic. Switching on a width threshold would
            mean the window rearranged itself while somebody dragged the divider
            past it, and a layout that moves on its own while you are using it is
            worse than one that is occasionally the wrong shape. It is a setting,
            it is remembered, and it takes one tap.
        #>
        param([bool]$On)
        try {
            $split.Orientation = if ($On) {
                [System.Windows.Forms.Orientation]::Horizontal
            } else {
                [System.Windows.Forms.Orientation]::Vertical
            }
            # The divider position and both minimums are validated against the
            # dimension that just changed meaning, so they cannot carry over.
            Set-SplitterLayout
            Update-Layout
            Update-Stretch
        } catch { Write-CrashLog "Stacked layout failed: $($_.Exception.Message)" }
        Request-SettingsSave
    }

    # ---- Lookup columns: a checkable item per definition ----
    # SuperGrate has this and it is the one thing it offers that UTW did not.
    # A submenu rather than a dialog: there are six of them, the choice is
    # obvious, and a dialog for six checkboxes is a dialog too many.
    $miCols = New-MenuItem "Loo&kup columns"
    foreach ($def in $Script:BrowseColumnDefs) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($def.Text)
        $item.Tag = $def.Key
        $item.Enabled = -not $def.Fixed
        $item.Add_Click({
            param($sender, $e)
            $key = "$($sender.Tag)"
            $cur = @($Script:BrowseColumns)
            $Script:BrowseColumns = if ($cur -contains $key) { @($cur | Where-Object { $_ -ne $key }) }
                                    else { @($cur) + $key }
            # Rebuilt rather than patched: the list is cheap to refill and a
            # half-updated ListView is how columns and cells drift apart.
            if ($Script:BrowseMode -eq "Users") { Show-BrowseUsers }
            Request-SettingsSave
        })
        Set-StripItemColors $item
        [void]$miCols.DropDownItems.Add($item)
    }
    $miCols.Add_DropDownOpening({
        foreach ($it in $miCols.DropDownItems) {
            try { $it.Checked = ($Script:BrowseColumns -contains "$($it.Tag)") -or
                                (@($Script:BrowseColumnDefs | Where-Object { $_.Key -eq "$($it.Tag)" -and $_.Fixed }).Count -gt 0) } catch { }
        }
    })
    [void]$miView.DropDownItems.Add($miCols)
    $miStacked = New-MenuItem "S&tacked layout (narrow screens)" {
        Set-StackedLayout ($split.Orientation -ne [System.Windows.Forms.Orientation]::Horizontal)
    }
    $miStacked.ToolTipText = "Puts the setup column above the list and log instead of beside them, so a narrow screen scrolls down rather than panning sideways."
    [void]$miView.DropDownItems.Add($miStacked)

    $miTouch = New-MenuItem "&Larger touch targets" { Set-TouchTargets (-not ($Script:TouchBoost -gt 1.0)) }
    $miTouch.ToolTipText = "Scales the whole window up so buttons and rows can be hit with a finger. For running UTW over RDP from a phone or tablet."
    $miView.Add_DropDownOpening({
        try {
            $miTouch.Checked   = ($Script:TouchBoost -gt 1.0)
            $miStacked.Checked = ($split.Orientation -eq [System.Windows.Forms.Orientation]::Horizontal)
        } catch { }
    })
    [void]$miView.DropDownItems.Add($miTouch)

    [void]$miView.DropDownItems.Add((New-MenuSeparator))
    # Named for the pane it clears. There are three logs in this tool and
    # "Clear the log" did not say which one was about to go.
    [void]$miView.DropDownItems.Add((New-MenuItem "Clear the &output log..." { Clear-OutputLog }))

    # ---- Help ----
    [void]$miHelp.DropDownItems.Add((New-MenuItem "UTW &notes (README)" {
        $p = Get-UTWResource "README.md"
        if ($p) { Start-Process $p }
        else { Show-ThemedMessage "README.md was not found (looked beside the scripts and in Docs\)." "Notes" "OK" "Information" }
    }))
    [void]$miHelp.DropDownItems.Add((New-MenuItem "UTW &documentation" {
        $p = Get-UTWResource "DOCUMENTATION.md"
        if ($p) { Start-Process $p }
        else { Show-ThemedMessage "DOCUMENTATION.md was not found (looked beside the scripts and in Docs\)." "Documentation" "OK" "Information" }
    }))
    [void]$miHelp.DropDownItems.Add((New-MenuItem "Microsoft USMT &return codes" { Start-Process $Script:USMTDocsUrl }))
    [void]$miHelp.DropDownItems.Add((New-MenuItem "Microsoft &ScanState reference" { Start-Process $Script:ScanStateDocsUrl }))
    [void]$miHelp.DropDownItems.Add((New-MenuItem "Microsoft &LoadState reference" { Start-Process $Script:LoadStateDocsUrl }))
    [void]$miHelp.DropDownItems.Add((New-MenuSeparator))
    [void]$miHelp.DropDownItems.Add((New-MenuItem "&About UTW" { Show-AboutDialog }))

    # ---- Load saved settings ----
    # The layout is held still for the whole restore; see Update-Layout.
    # RE-APPLIED, not just applied once at startup.
    #
    # Loading someone else's settings or resetting to factory used to need a
    # new window, because this ran exactly once during construction. It is a
    # function now, so the same code that restores settings on start can put a
    # different set over a window that is already open - one path, so the form
    # and the file cannot end up disagreeing about what is in force.
    function Restore-SettingsToForm {
        $Script:LayoutSuspended = $true
    $cache = Load-SettingsCache
    if ($cache) {
        if ($cache.USMTPath -and (Test-USMTPath $cache.USMTPath)) {
            $txtUSMTPath.Text = $cache.USMTPath; $txtUSMTPath.ForeColor = $Script:T.Text
            $vi = Get-UsmtFolderInfo -USMTPath $cache.USMTPath
            $lblUSMTStatus.Text = "$($Script:CheckMark) USMT files found - $($vi.Summary)"
            $lblUSMTStatus.ForeColor = if ($vi.Released) { $Script:T.Success } else { $Script:T.Warning }
            $lblUSMTStatus.Tag = if ($vi.Released) { "status-ok" } else { "status-warning" }
            $logPath = Set-LogFolder $cache.USMTPath; Set-LogPathDisplay $logPath
        }
        if ($cache.Theme -and $cache.Theme -ne $Script:DefaultTheme -and $Script:Themes.ContainsKey($cache.Theme)) {
            $cmbTheme.SelectedItem = $cache.Theme
            Apply-Theme -Form $Form -ThemeName $cache.Theme
            $cmbTheme.BackColor = $Script:T.MedBg; $cmbTheme.ForeColor = $Script:T.Text
        }
        # Scope/Action are the current form. A settings file written before the
        # dropdown split only has the old 0-11 OperationIndex, so map it once -
        # the two OneDrive entries (1 and 9) become their plain equivalent with
        # the checkbox ticked, which is what they always meant.
        if ($null -ne $cache.ScopeIndex -and $null -ne $cache.ActionIndex `
            -and $cache.ScopeIndex -ge 0 -and $cache.ScopeIndex -lt $cmbScope.Items.Count `
            -and $cache.ActionIndex -ge 0 -and $cache.ActionIndex -lt $cmbAction.Items.Count) {
            $cmbScope.SelectedIndex  = $cache.ScopeIndex
            $cmbAction.SelectedIndex = $cache.ActionIndex
        } elseif ($cache.Operation -ge 0) {
            #                     scope, action, excludeOneDrive
            $legacyMap = @(
                @(0,0,$false), @(0,0,$true),  @(0,1,$false), @(1,0,$false),
                @(1,1,$false), @(2,0,$false), @(2,1,$false), @(0,3,$false),
                @(0,2,$false), @(0,2,$true),  @(1,2,$false), @(2,2,$false)
            )
            if ($cache.Operation -lt $legacyMap.Count) {
                $m = $legacyMap[$cache.Operation]
                $cmbScope.SelectedIndex     = $m[0]
                $cmbAction.SelectedIndex    = $m[1]
                $chkExcludeOneDrive.Checked = $m[2]
                Write-CrashLog "Mapped legacy OperationIndex $($cache.Operation) -> scope $($m[0]) / action $($m[1]) / excludeOneDrive $($m[2])"
            }
        }
        if ($null -ne $cache.ExcludeOneDrive) { $chkExcludeOneDrive.Checked = [bool]$cache.ExcludeOneDrive }
        # Pre-flight toggles default to on; only an explicit saved value turns one off.
        if ($null -ne $cache.VerifyProfile)   { $chkVerifyProfile.Checked   = [bool]$cache.VerifyProfile }
        if ($null -ne $cache.CheckDisk)       { $chkCheckDisk.Checked       = [bool]$cache.CheckDisk }
        if ($null -ne $cache.CheckInactive)   { $chkCheckInactive.Checked   = [bool]$cache.CheckInactive }
        if ($null -ne $cache.EstimateSize)    { $chkEstimateSize.Checked    = [bool]$cache.EstimateSize }
        $cmbSaveTo.SelectedIndex = switch ($cache.StoreMode) {
            "Central" { 1 }
            "USB"     { 2 }
            default   { 0 }
        }
        if ($cache.CentralPath) { $txtCentralPath.Text = $cache.CentralPath }
        if ($cache.LastUsername)    { $txtUsername.Text  = $cache.LastUsername }
        # Domain was loaded into AppConfig by Load-SettingsCache; sync to GUI
        $txtDomain.Text = $Script:AppConfig.Domain
        if ($cache.LastNewPC)       { $txtNewPC.Text     = $cache.LastNewPC }
        if ($cache.LastSourcePC)    { $txtSourcePC.Text  = $cache.LastSourcePC }
        if ($cache.USBPath)         { $txtUSBPath.Text   = $cache.USBPath }
        if ($cache.LastMigFile)     { $txtMigrationFile.Text  = $cache.LastMigFile }
        if ($cache.LastExtractPath) { $txtExtractPath.Text    = $cache.LastExtractPath }
        # OneDrive detection is site configuration, so it survives restarts.
        if ($null -ne $cache.ODDetect) { $chkODDetect.Checked = [bool]$cache.ODDetect }
        if ($cache.ODPattern) { $txtODPattern.Text = $cache.ODPattern; $Script:OneDriveFolderPattern = $cache.ODPattern }
        if ($cache.ODMinMB -ne "") { $txtODMin.Text = $cache.ODMinMB }
        if ($null -ne $cache.ArchIndex -and $cache.ArchIndex -ge 0 -and $cache.ArchIndex -lt $cmbArch.Items.Count) { $cmbArch.SelectedIndex = [int]$cache.ArchIndex }
        if ($null -ne $cache.LogOnExit) { $chkLogOnExit.Checked = [bool]$cache.LogOnExit }
        # The two destructive options are deliberately NOT restored. They are
        # per-migration decisions, and a tick remembered from last week is
        # exactly how somebody deletes a profile they did not mean to.

        # Where the dividers were left. This is what makes View > Layout worth
        # having: a preference that has to be re-set on every launch is not a
        # preference. Both are clamped by the same guards as any other move, so
        # a value saved on a 4K screen cannot wedge the window on a laptop.
        try {
            if ($null -ne $cache.SplitLeft -and [int]$cache.SplitLeft -gt 0) {
                $Script:SetupColumnWidth = [int]([int]$cache.SplitLeft * $Script:UIScale)
                Set-SplitterLayout
            }
            if ($null -ne $cache.SplitRight -and [int]$cache.SplitRight -gt 0) {
                $splitRight.SplitterDistance = [int]([int]$cache.SplitRight * $Script:UIScale)
                Set-RightSplitter          # clamp, do not reset
            }
            if ($null -ne $cache.OverlayAnimate) { $Script:OverlayAnimate = [bool]$cache.OverlayAnimate }
        # Applied by rescaling the built window rather than by scaling it
        # differently in the first place: settings are restored after the layout
        # pass, so this is the only moment the answer is known.
        if ($null -ne $cache.SyncAppData) { $Script:SyncIncludeAppData = [bool]$cache.SyncAppData }
        if ("$($cache.ConfigXmlMode)".Trim().ToLower() -in @('auto','yes','no')) { $Script:ConfigXmlMode = "$($cache.ConfigXmlMode)".Trim().ToLower() }
        # THESE TWO DECIDE WHAT GETS DELETED, and neither was ever saved.
        #
        # Both are editable in the Settings dialog, which promises the values are
        # remembered, and both drive real behaviour: the idle threshold decides
        # which profiles are offered for deletion, the disk figure decides
        # whether a run is warned off. They reverted to 90 and 20 on every
        # launch, so an operator who lowered the idle threshold to be careful
        # got the default back without being told.
        #
        # Range-checked on the way in, because a value from a hand-edited file
        # must not be able to make the threshold 0 - that would offer every
        # profile on the machine as stale.
        $n = 0
        if ($null -ne $cache.InactiveDays -and [int]::TryParse("$($cache.InactiveDays)", [ref]$n) -and $n -gt 0) {
            $Script:PreflightInactiveDays = $n
        }
        if ($null -ne $cache.MinFreeGB -and [int]::TryParse("$($cache.MinFreeGB)", [ref]$n) -and $n -gt 0) {
            $Script:PreflightMinFreeGB = $n
        }
        if ("$($cache.BrowseColumns)".Trim()) {
            # Filtered against the definitions, so a key that no longer exists -
            # a column removed in a later version - is dropped rather than
            # producing a header with no cells under it.
            $known = @($Script:BrowseColumnDefs | ForEach-Object { $_.Key })
            $want  = @("$($cache.BrowseColumns)" -split "," | ForEach-Object { $_.Trim() } | Where-Object { $known -contains $_ })
            if ($want.Count) { $Script:BrowseColumns = $want }
        }
        if ($null -ne $cache.TouchTargets -and [bool]$cache.TouchTargets) { Set-TouchTargets $true }
        if ($null -ne $cache.StackedLayout -and [bool]$cache.StackedLayout) { Set-StackedLayout $true }
    # Before Set-OverlayEnabled below, so the first render already uses whichever
    # artwork was chosen rather than drawing the other one and replacing it.
    if ($null -ne $cache.XamlArt) { $Script:UseXamlArt = [bool]$cache.XamlArt }
            if ($null -ne $cache.Overlay) { Set-OverlayEnabled ([bool]$cache.Overlay) }
            if ($cache.PanelLayout) { Set-LayoutString $cache.PanelLayout }
            elseif ($null -ne $cache.BrowseHidden -and [bool]$cache.BrowseHidden) {
                # Older settings only knew about hiding the lookup panel.
                $lk = $Script:Panels | Where-Object { $_.Key -eq "Lookup" } | Select-Object -First 1
                if ($lk) { $lk.Shown = $false; Update-Layout }
            }
        } catch { Write-CrashLog "Restoring the saved layout failed: $($_.Exception.Message)" }
        Update-Fields
    }

    # ---- Hand-off from a "New Window" click, applied over the saved settings ----
    # Deliberately after the cache load: this window was opened FROM another one
    # and should look like it, not like whatever was last saved to disk.
    if ($Script:IsSecondary -and $Script:HandoffData) {
        $h = $Script:HandoffData
        try {
            if ($h.USMTPath -and (Test-USMTPath $h.USMTPath)) {
                $txtUSMTPath.Text = $h.USMTPath; $txtUSMTPath.ForeColor = $Script:T.Text
                $hvi = Get-UsmtFolderInfo -USMTPath $h.USMTPath
                $lblUSMTStatus.Text = "$($Script:CheckMark) USMT files found - $($hvi.Summary)"
                $lblUSMTStatus.ForeColor = if ($hvi.Released) { $Script:T.Success } else { $Script:T.Warning }
                $lblUSMTStatus.Tag = if ($hvi.Released) { "status-ok" } else { "status-warning" }
                Set-LogPathDisplay (Set-LogFolder $h.USMTPath)
            }
            if ($h.Theme -and $h.Theme -ne $cmbTheme.SelectedItem.ToString()) {
                $cmbTheme.SelectedItem = $h.Theme
                Apply-Theme -Form $Form -ThemeName $h.Theme
                $cmbTheme.BackColor = $Script:T.MedBg; $cmbTheme.ForeColor = $Script:T.Text
            }
            if ($null -ne $h.ScopeIndex  -and $h.ScopeIndex  -ge 0 -and $h.ScopeIndex  -lt $cmbScope.Items.Count)  { $cmbScope.SelectedIndex  = [int]$h.ScopeIndex }
            if ($null -ne $h.ActionIndex -and $h.ActionIndex -ge 0 -and $h.ActionIndex -lt $cmbAction.Items.Count) { $cmbAction.SelectedIndex = [int]$h.ActionIndex }
            if ($null -ne $h.SaveToIndex -and $h.SaveToIndex -ge 0 -and $h.SaveToIndex -lt $cmbSaveTo.Items.Count) { $cmbSaveTo.SelectedIndex = [int]$h.SaveToIndex }
            if ($null -ne $h.ExcludeOneDrive) { $chkExcludeOneDrive.Checked = [bool]$h.ExcludeOneDrive }
            if ($null -ne $h.Overwrite)       { $chkOverwrite.Checked       = [bool]$h.Overwrite }
            if ($null -ne $h.CleanupAfter)    { $chkCleanup.Checked         = [bool]$h.CleanupAfter }
            if ($null -ne $h.VerifyProfile)   { $chkVerifyProfile.Checked   = [bool]$h.VerifyProfile }
            if ($null -ne $h.CheckDisk)       { $chkCheckDisk.Checked       = [bool]$h.CheckDisk }
            if ($null -ne $h.CheckInactive)   { $chkCheckInactive.Checked   = [bool]$h.CheckInactive }
            if ($null -ne $h.EstimateSize)    { $chkEstimateSize.Checked    = [bool]$h.EstimateSize }
            if ($null -ne $h.ODDetect) { $chkODDetect.Checked = [bool]$h.ODDetect }
            if ($null -ne $h.ArchIndex -and $h.ArchIndex -ge 0 -and $h.ArchIndex -lt $cmbArch.Items.Count) { $cmbArch.SelectedIndex = [int]$h.ArchIndex }
            if ($null -ne $h.LogOnExit) { $chkLogOnExit.Checked = [bool]$h.LogOnExit }
            if ($h.ODPattern)   { $txtODPattern.Text  = $h.ODPattern; $Script:OneDriveFolderPattern = $h.ODPattern }
            if ($h.ODMinMB)     { $txtODMin.Text      = "$($h.ODMinMB)" }
            if ($h.Domain)      { $txtDomain.Text      = $h.Domain; $Script:AppConfig.Domain = $h.Domain }
            if ($h.Username)    { $txtUsername.Text    = $h.Username }
            if ($h.CentralPath) { $txtCentralPath.Text = $h.CentralPath }
            if ($h.USBPath)     { $txtUSBPath.Text     = $h.USBPath }
            # The two machine names are deliberately NOT carried across. A second
            # window exists to migrate a DIFFERENT pair of machines, and copying
            # them over is how someone ends up running the same capture twice.
            $txtSourcePC.Text = ""
            $txtNewPC.Text    = ""
            Update-Fields
            Append-Output "Opened from another window - settings carried over, machine names left blank." $Script:AccentPurple
            Append-Output "Fill in the machines for THIS migration before running." $Script:T.TextDim
        } catch {
            Write-CrashLog "Hand-off apply failed: $($_.Exception.Message)"
        }
    }
    # Claim a window number. Every window does this, not just secondary ones -
    # window 1 needs to hold number 1 so the next one can find that it is taken.
    Write-CrashLog "Boot: cache applied at $($Script:BootClock.ElapsedMilliseconds) ms"
    $reg = Register-Instance
    $Script:InstanceNumber = $reg.Number
    $Script:InstanceFile   = $reg.File
    Write-CrashLog "Boot: instance registered at $($Script:BootClock.ElapsedMilliseconds) ms"
    Write-CrashLog "This window is instance #$($Script:InstanceNumber) (PID $PID)"
    Update-WindowTitle

    # ---- Restore the saved mode, last, so the panel opens over a finished layout ----
    $wantMode = if ($Script:IsSecondary -and $Script:HandoffData -and $Script:HandoffData.UiMode) {
                    $Script:HandoffData.UiMode
                } elseif ($cache -and $cache.UiMode) { $cache.UiMode } else { "Simple" }
    if ($wantMode -eq "Expert") {
        $rbExpert.Checked = $true    # fires CheckedChanged, which shows the panel
    }

    # Everything that could rearrange the window has now had its say, so the
    # arrangement is built once.
    $Script:LayoutSuspended = $false
    if ($Script:LayoutDirty) { Update-Layout } else { Update-Stretch }
    }
    Restore-SettingsToForm
    Write-CrashLog "Boot: settings restored at $($Script:BootClock.ElapsedMilliseconds) ms"

    # ---- New Window ----
    # Held as a scriptblock and called through Invoke-NewWindow: this is defined
    # near the end because it reads controls from all over the form, but the
    # File menu is built before it and needs something to call.
    $Script:NewWindowAction = {
        try {
            $me = Join-Path $Script:ScriptDir "UTW-Main.ps1"
            if (-not (Test-Path $me)) {
                Show-ThemedMessage "Cannot find UTW-Main.ps1 next to this one, so a second window cannot be started." "New Window" "OK" "Warning"
                return
            }
            $payload = @{
                USMTPath        = $txtUSMTPath.Text.Trim()
                Theme           = $cmbTheme.SelectedItem.ToString()
                UiMode          = $(if ($rbExpert.Checked) { "Expert" } else { "Simple" })
                ODDetect        = $chkODDetect.Checked
                ODPattern       = $txtODPattern.Text.Trim()
                ODMinMB         = $txtODMin.Text.Trim()
                ArchIndex       = $cmbArch.SelectedIndex
                LogOnExit       = $chkLogOnExit.Checked
                # 'Restore as a different account' and 'delete after capture' are
                # deliberately NOT carried over. They are decisions about one
                # migration; inheriting them into a fresh window is how somebody
                # destroys a profile they never chose to.
                ScopeIndex      = $cmbScope.SelectedIndex
                ActionIndex     = $cmbAction.SelectedIndex
                SaveToIndex     = $cmbSaveTo.SelectedIndex
                Domain          = $txtDomain.Text.Trim()
                Username        = $txtUsername.Text.Trim()
                CentralPath     = $txtCentralPath.Text.Trim()
                USBPath         = $txtUSBPath.Text.Trim()
                ExcludeOneDrive = $chkExcludeOneDrive.Checked
                Overwrite       = $chkOverwrite.Checked
                CleanupAfter    = $chkCleanup.Checked
                VerifyProfile   = $chkVerifyProfile.Checked
                CheckDisk       = $chkCheckDisk.Checked
                CheckInactive   = $chkCheckInactive.Checked
                EstimateSize    = $chkEstimateSize.Checked
            }
            # Handed over as a file rather than on the command line: these values
            # include paths with spaces and UNCs, and quoting them through
            # cmd/PowerShell argument parsing is a reliable source of bugs.
            $hoDir = Join-Path $env:TEMP "UTW_Handoff"
            if (-not (Test-Path $hoDir)) { New-Item -Path $hoDir -ItemType Directory -Force | Out-Null }
            $hoFile = Join-Path $hoDir "handoff_$([Guid]::NewGuid().ToString('N')).json"
            $payload | ConvertTo-Json -Depth 3 | Out-File -FilePath $hoFile -Encoding UTF8 -Force

            Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                "-File", "`"$me`"", "-Handoff", "`"$hoFile`""
            ) | Out-Null
            Write-CrashLog "Opened a second window (handoff $hoFile)"
            Append-Output "Opened a second window. It has the same settings; give it its own machine names." $Script:AccentPurple
        } catch {
            Write-CrashLog "New Window failed: $($_.Exception.Message)"
            Show-ThemedMessage "Could not open a second window.`n`n$($_.Exception.Message)" "New Window" "OK" "Error"
        }
    }

    # ---- Save on close ----
    $Form.Add_FormClosing({
        if ($Script:CurrentProcess -and -not $Script:CurrentProcess.HasExited) { try { $Script:CurrentProcess.Kill() } catch { } }
        if ($Script:RemotePhase -eq 1 -and $Script:RemoteSession) {
            try { Remove-RemoteTask -PC $Script:RemoteSession.Task.PC -TaskName $Script:RemoteSession.Task.TaskName } catch { }
        }
        # Never leave a share open on someone's new PC because the window closed.
        try { Remove-DestStoreShare $Script:DirectShare } catch { }
        # Likewise the destination claim - a window killed mid-run would
        # otherwise leave the store looking busy to the next one. (Lock-StorePath
        # also treats a lock owned by a dead PID as stale, so this is belt and
        # braces rather than the only way out.)
        try { if ($Script:StoreLock) { Unlock-StorePath $Script:StoreLock; $Script:StoreLock = $null } } catch { }
        # Give the window number back so it can be reused rather than climbing.
        try { Unregister-Instance $Script:InstanceFile } catch { }

        # Log-on-exit. Only when something actually happened - a window opened
        # and closed without running anything would otherwise litter the log
        # folder with empty files. Named for the window so two instances
        # closing together cannot collide.
        try {
            if ($chkLogOnExit.Checked -and $Script:AppConfig.LogFolder -and $txtOutput.TextLength -gt 200) {
                $p = Join-Path $Script:AppConfig.LogFolder ("UTW_session_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)
                [void](Save-OutputLog -Path $p)
            }
        } catch { Write-CrashLog "Log-on-exit failed: $($_.Exception.Message)" }
        if ($Script:RoboProcess -and -not $Script:RoboProcess.HasExited) { try { $Script:RoboProcess.Kill() } catch { } }
        $timer.Stop()
        try { $fitTimer.Stop(); $fitTimer.Dispose() } catch { }
        # The coalescing timers hold work that is ABOUT to touch the controls.
        # Left running they fire once more against a half-disposed window, which
        # costs nothing visible but writes an alarming line to the crash log.
        foreach ($tk in @($Script:StretchTimer, $Script:OverlayTimer, $Script:CaptionTimer)) {
            if ($tk) { try { $tk.Stop() } catch { } }
        }
        # Sync domain from GUI to AppConfig so it persists
        $Script:AppConfig.Domain = $txtDomain.Text.Trim()
        # Only the window that owns the settings writes them. Two instances
        # saving on close is a race whose winner is whichever happened to be
        # closed last, which quietly reverts whatever the first one changed.
        if ($Script:IsSecondary) {
            Write-CrashLog "Secondary window closed - settings not saved (the first window owns them)"
            return
        }
        try {
            Save-LiveSettings
        } catch { Write-CrashLog "Save on close failed: $($_.Exception.Message)" }
    })

    # Everything worth remembering, in one place, so "save now" and "save on
    # close" cannot drift apart.
    function Save-LiveSettings {
        # The self-test measures a window it has deliberately distorted; none of
        # that belongs in anybody's settings. See Request-SettingsSave.
        if ($env:UTW_LAYOUT_SELFTEST) { return }
        try {
            Save-SettingsCache @{
                USMTPath        = $txtUSMTPath.Text.Trim()
                Theme           = $cmbTheme.SelectedItem.ToString()
                UiMode          = $(if ($rbExpert.Checked) { "Expert" } else { "Simple" })
                ODDetect        = $chkODDetect.Checked
                ODPattern       = $txtODPattern.Text.Trim()
                ODMinMB         = $txtODMin.Text.Trim()
                ArchIndex       = $cmbArch.SelectedIndex
                LogOnExit       = $chkLogOnExit.Checked
                RenameOn        = $chkRenameOnRestore.Checked
                DeleteSource    = $chkDeleteSource.Checked
                ScopeIndex      = $cmbScope.SelectedIndex
                ActionIndex     = $cmbAction.SelectedIndex
                ExcludeOneDrive = $chkExcludeOneDrive.Checked
                VerifyProfile   = $chkVerifyProfile.Checked
                CheckDisk       = $chkCheckDisk.Checked
                CheckInactive   = $chkCheckInactive.Checked
                EstimateSize    = $chkEstimateSize.Checked
                BrowseColumns   = (@($Script:BrowseColumns) -join ",")
                SyncAppData     = $Script:SyncIncludeAppData
                ConfigXmlMode   = $Script:ConfigXmlMode
                InactiveDays     = $Script:PreflightInactiveDays
                MinFreeGB     = $Script:PreflightMinFreeGB
                TouchTargets    = ($Script:TouchBoost -gt 1.0)
                StackedLayout   = ($split.Orientation -eq [System.Windows.Forms.Orientation]::Horizontal)
                StoreMode       = Get-StoreMode
                CentralPath     = $txtCentralPath.Text.Trim()
                # Kept so an older build reading this file still picks a sane route.
                DestType        = if ((Get-StoreMode) -eq "USB") { "USB" } else { "Network" }
                LastUsername    = $txtUsername.Text.Trim()
                LastNewPC       = $txtNewPC.Text.Trim()
                LastSourcePC    = $txtSourcePC.Text.Trim()
                USBPath         = $txtUSBPath.Text.Trim()
                LastMigFile     = $txtMigrationFile.Text
                LastExtractPath = $txtExtractPath.Text
                # DESIGN pixels, not the real ones the splitter holds. The same
                # settings file follows a technician between a 4K desk monitor
                # and a 1080p laptop; a divider saved at 175% and replayed at
                # 100% would be nearly twice as wide as intended. Dividing out
                # the scale on the way in and multiplying it back on the way out
                # makes the saved preference mean the same thing on both.
                SplitLeft       = $(try { [int]($split.SplitterDistance / $Script:UIScale) } catch { 0 })
                SplitRight      = $(try { [int]($splitRight.SplitterDistance / $Script:UIScale) } catch { 0 })
                BrowseHidden    = $(try { [bool]$splitRight.Panel1Collapsed } catch { $false })
                Overlay         = $(try { [bool]$Script:OverlayEnabled } catch { $false })
                OverlayAnimate  = $(try { [bool]$Script:OverlayAnimate } catch { $false })
        XamlArt         = $(try { [bool]$Script:UseXamlArt } catch { $true })
                # Where every panel ended up: zone, order and shown/hidden.
                PanelLayout     = $(try { Get-LayoutString } catch { "" })
            }
        } catch { Write-CrashLog "Save failed: $($_.Exception.Message)" }
    }

    # SAVED AS YOU GO, not only when the window closes.
    #
    # Closing was the only thing that wrote the file, so a window that was killed
    # - or a machine that restarted - lost everything since it opened, and the
    # theme somebody picked an hour ago was simply gone. Coalesced onto a short
    # timer because the callers are things like a combo box changing, which can
    # fire several times in a row; one write a second after things settle is
    # indistinguishable from writing on every keystroke and costs nothing.
    $Script:SaveTimer = New-Object System.Windows.Forms.Timer
    $Script:SaveTimer.Interval = 1200
    $Script:SaveTimer.Add_Tick({
        try {
            $Script:SaveTimer.Stop()
            if ($Form.IsDisposed -or $Form.Disposing -or $Script:IsSecondary) { return }
            Save-LiveSettings
        } catch { }
    })
    function Request-SettingsSave {
        if ($Script:IsSecondary) { return }   # the first window owns the file
        # AND NOT WHILE THE SELF-TEST IS DRIVING.
        #
        # It drags the divider to both extremes and moves panels between zones to
        # measure them. Before settings saved as you went, that was harmless -
        # nothing was written unless a person closed the window. Now it would
        # persist a deliberately broken layout into the real settings file, and
        # every later run would start from it. Which is exactly what happened:
        # a saved SplitLeft of 426 left panels wider than the zone holding them.
        if ($env:UTW_LAYOUT_SELFTEST) { return }
        try { $Script:SaveTimer.Stop(); $Script:SaveTimer.Start() } catch { }
    }

    # The changes worth persisting the moment they are made: how the tool looks
    # and which operation it is set to. The rest ride along on the same write.
    foreach ($c in @($cmbTheme, $cmbScope, $cmbAction, $cmbArch)) {
        if ($c) { $c.Add_SelectedIndexChanged({ Request-SettingsSave }) }
    }
    foreach ($c in @($rbExpert, $rbSimple, $chkODDetect, $chkLogOnExit, $chkRenameOnRestore,
                     $chkExcludeOneDrive, $chkVerifyProfile, $chkCheckDisk, $chkCheckInactive,
                     $chkEstimateSize)) {
        if ($c) { $c.Add_CheckedChanged({ Request-SettingsSave }) }
    }
    foreach ($c in @($txtUsername, $txtNewPC, $txtSourcePC, $txtUSBPath, $txtCentralPath, $txtDomain)) {
        if ($c) { $c.Add_TextChanged({ Request-SettingsSave }) }
    }

    # Close splash, show main form
    Update-Splash $splash "Ready" "" 100
    try { Write-CrashLog "Boot: window ready at $($Script:BootClock.ElapsedMilliseconds) ms (layout took $($Script:StartClock.ElapsedMilliseconds) ms)" } catch { }
    if ($splash -and -not $splash.Form.IsDisposed) { $splash.Form.Close(); $splash.Form.Dispose() }
    $Form.Add_Shown({ $Form.Activate() })
    [System.Windows.Forms.Application]::Run($Form)
}

# ---- Entry point ----
try { Show-MigrationGUI } catch {
    Write-CrashLog "Unhandled: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    [System.Windows.Forms.MessageBox]::Show("Unhandled error:`n$($_.Exception.Message)", "User Transfer Wizard", "OK", "Error")
}





































