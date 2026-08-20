#Requires -Version 5.1
<#
.SYNOPSIS
    Business logic for User Transfer Wizard (UTW).
    Dot-sourced by UTW-Main.ps1  -  do not run directly.

    Remote export uses scheduled tasks (schtasks.exe) over DCOM/RPC.
    No WinRM, no PSRemoting, no PsExec required.

    Remote export flow:
      1. Copy USMT tools + a generated batch file to \\SourcePC\C$\Windows\Temp\USMT_Temp\
      2. Create a one-shot SYSTEM scheduled task on SourcePC via schtasks /create /s
      3. Run it immediately via schtasks /run /s
      4. Timer polls schtasks /query /s each tick  -  tails logs via UNC the entire time
      5. On completion: robocopy pulls the local store from \\SourcePC admin share
         and copies it to \\DestPC\C$\USMT Profiles\<user>\
      6. Cleanup: delete scheduled task + wipe the USMT_Temp folder from SourcePC
#>

$Script:RemoteTempName  = "USMT_Temp"
$Script:RemoteTempLocal = "C:\Windows\Temp\USMT_Temp"   # as seen FROM the remote machine
$Script:RemoteStoreSub  = "Store"                         # subfolder scanstate writes to

# ---------------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if ([string]::IsNullOrWhiteSpace($Script:AppConfig.LogFolder)) { return }
    if (-not (Test-Path $Script:AppConfig.LogFolder)) {
        New-Item -Path $Script:AppConfig.LogFolder -ItemType Directory -Force | Out-Null
    }
    # UTW's own activity log, distinct from the USMT scanstate/loadstate logs
    # that land in the same folder.
    $logFile = Join-Path $Script:AppConfig.LogFolder "UTW_$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
#  USMT Path Validation
# ---------------------------------------------------------------------------
function Test-USMTPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq "(click Browse to select USMT folder)") { return $false }
    return ((Test-Path (Join-Path $Path "scanstate.exe")) -and
            (Test-Path (Join-Path $Path "loadstate.exe")) -and
            (Test-Path (Join-Path $Path "migapp.xml"))    -and
            (Test-Path (Join-Path $Path "miguser.xml")))
}

function Set-LogFolder {
    param([string]$USMTPath)
    $logPath = Join-Path $USMTPath "Logs"
    if (-not (Test-Path $logPath)) { New-Item -Path $logPath -ItemType Directory -Force | Out-Null }
    $Script:AppConfig.LogFolder = $logPath
    Write-Log "Log folder initialized"
    return $logPath
}

# ---------------------------------------------------------------------------
#  Network Connectivity
# ---------------------------------------------------------------------------
function Test-ComputerReachable {
    param([string]$Name)
    try { return (Test-Connection -ComputerName $Name -Count 1 -Quiet -ErrorAction SilentlyContinue) }
    catch { return $false }
}

function Test-AdminShare {
    param([string]$Name)
    try { return (Test-Path "\\$Name\C$" -ErrorAction SilentlyContinue) }
    catch { return $false }
}

function Test-ProfileExists {
    <#
    .SYNOPSIS
        Checks whether a user profile folder (C:\Users\<Username>) exists on a
        local or remote computer.  Used as a pre-flight check before export to
        prevent USMT from running indefinitely scanning system data when the
        specified profile does not exist.
    #>
    param(
        [string]$Username,
        [string]$ComputerName = $env:COMPUTERNAME,
        [bool]$IsRemote = $false
    )
    if ([string]::IsNullOrWhiteSpace($Username)) { return $false }
    $profilePath = if ($IsRemote) {
        "\\$ComputerName\C$\Users\$Username"
    } else {
        "C:\Users\$Username"
    }
    try { return (Test-Path $profilePath -ErrorAction SilentlyContinue) }
    catch { return $false }
}

# ---------------------------------------------------------------------------
#  OneDrive detection
#
#  Two independent signals, because either one alone misses real cases:
#
#    * a OneDrive folder in the profile - proof the client has actually run on
#      this machine, but absent on a PC the user has only just signed into
#    * membership of the OneDrive rollout group in AD - proof the user is
#      MEANT to be syncing, which is what still answers the question when the
#      folder has not appeared yet, or when the profile sits on a machine whose
#      admin share we cannot read
#
#  Nothing here is ever fatal. Every lookup is wrapped and a workgroup machine,
#  a missing admin share or an unreachable domain controller downgrades the
#  answer to "not checked" instead of blocking a migration.
# ---------------------------------------------------------------------------

# The AD group that marks a user as being on OneDrive. Overridable from
# Config.xml / the settings JSON; the folder check runs regardless.
$Script:OneDriveGroupName = "OneDriveUsers"

# Which folders count as OneDrive. A wildcard because the tenant folder is
# branded ("OneDrive - Contoso") and a profile can hold that AND a personal
# "OneDrive". Narrow it if only one of them is ever worth excluding.
$Script:OneDriveFolderPattern = "OneDrive*"

# How much LOCALLY-HELD data has to be sitting in those folders before the
# operator is interrupted about it.
#
# This is what stops the prompt firing on every single profile. Where OneDrive
# is deployed to everyone, "has a OneDrive folder" and "is in the OneDrive
# group" are true of every user in the company and so discriminate nothing. The
# question that actually matters is whether EXCLUDING it would save anything -
# and with Files On-Demand, a profile can have a 200 GB OneDrive folder holding
# almost nothing on disk. Cloud-only files are already skipped by the byte
# count, so this measures what USMT would really have had to copy.
#
# 0 disables the threshold and restores "prompt whenever a folder exists".
$Script:OneDriveMinLocalBytes = 1GB

# A directory query against a dead DC can hang a WinForms thread for a minute.
$Script:OneDriveADTimeoutSec = 6

function Get-OneDriveFolders {
    <#
        Folders named OneDrive* directly inside a profile. Matches the personal
        client ("OneDrive") and every tenant-branded folder ("OneDrive - Contoso"),
        which is why this is a wildcard and not an equality test.
    #>
    param(
        [Parameter(Mandatory)][string]$Username,
        [string]$ComputerName = $env:COMPUTERNAME,
        [bool]$IsRemote = $false,
        [string]$Pattern = ""
    )
    if ([string]::IsNullOrWhiteSpace($Pattern)) { $Pattern = $Script:OneDriveFolderPattern }
    if ([string]::IsNullOrWhiteSpace($Pattern)) { $Pattern = "OneDrive*" }
    # <user> stands in for the profile being looked at, so a site whose folders
    # are "OneDrive - Contoso" can say so once instead of per person.
    $Pattern = $Pattern -replace '(?i)<user(name)?>', $Username
    $base = if ($IsRemote) { "\\$ComputerName\C$\Users\$Username" } else { "C:\Users\$Username" }
    $out  = @()
    try {
        if (-not (Test-Path $base -ErrorAction SilentlyContinue)) { return $out }
        $dirs = Get-ChildItem -LiteralPath $base -Directory -Filter $Pattern -Force -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            # Files On-Demand means an item count says nothing about disk usage,
            # so this only reports whether the folder holds anything at all -
            # an empty OneDrive folder is not worth interrupting a run over.
            $hasItems = $false
            try { $hasItems = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0 } catch { }
            $out += @{ Path = $d.FullName; Name = $d.Name; HasItems = $hasItems }
        }
    } catch { }
    # @() is load-bearing. A one-element array of hashtables gets unwrapped to
    # the hashtable on return, and .Count on a hashtable is its NUMBER OF KEYS -
    # so a single matched folder reported itself as three.
    return @($out)
}

function Test-OneDriveGroupMember {
    <#
        Is this user in the OneDrive group?

        Returns $true / $false, or $null when the question could not be asked -
        no domain, no DC, no such group. $null is NOT "no": the caller must not
        treat an unanswerable lookup as evidence that OneDrive is unused.

        Nested groups count. The group's DN is resolved first so the membership
        test can use LDAP_MATCHING_RULE_IN_CHAIN, which walks the whole nesting
        tree; a plain memberOf read only ever sees direct membership, and these
        rollout groups are very often nested inside a department group.
    #>
    param(
        [Parameter(Mandatory)][string]$Username,
        [string]$GroupName = ""
    )
    if ([string]::IsNullOrWhiteSpace($Username)) { return $null }
    if ([string]::IsNullOrWhiteSpace($GroupName)) { $GroupName = $Script:OneDriveGroupName }

    # Strip DOMAIN\ or user@domain - the directory wants the bare sAMAccountName.
    $sam = $Username
    if ($sam -match '\\') { $sam = $sam.Split('\')[-1] }
    if ($sam -match '@')  { $sam = $sam.Split('@')[0] }
    $esc = $sam -replace '([\\()*\0])', '\$1'

    try {
        # PowerShell only resolves types from assemblies that are already
        # loaded, and nothing else in this tool touches the directory.
        Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue
        $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://RootDSE")
        $nc   = $root.Properties["defaultNamingContext"].Value
        if (-not $nc) { return $null }

        $gEsc = $GroupName -replace '([\\()*\0])', '\$1'
        $gs = New-Object System.DirectoryServices.DirectorySearcher
        $gs.Filter = "(&(objectCategory=group)(cn=$gEsc))"
        $gs.ClientTimeout = [TimeSpan]::FromSeconds($Script:OneDriveADTimeoutSec)
        $gs.ServerTimeLimit = [TimeSpan]::FromSeconds($Script:OneDriveADTimeoutSec)
        [void]$gs.PropertiesToLoad.Add("distinguishedname")
        $gr = $gs.FindOne()
        if (-not $gr) {
            Write-CrashLog "OneDrive check: group '$GroupName' not found in the directory"
            return $null
        }
        $gDN = [string]$gr.Properties["distinguishedname"][0]

        $us = New-Object System.DirectoryServices.DirectorySearcher
        $us.Filter = "(&(objectCategory=user)(sAMAccountName=$esc)(memberOf:1.2.840.113556.1.4.1941:=$gDN))"
        $us.ClientTimeout = [TimeSpan]::FromSeconds($Script:OneDriveADTimeoutSec)
        $us.ServerTimeLimit = [TimeSpan]::FromSeconds($Script:OneDriveADTimeoutSec)
        [void]$us.PropertiesToLoad.Add("samaccountname")
        return ($null -ne $us.FindOne())
    } catch {
        Write-CrashLog "OneDrive group check unavailable: $($_.Exception.Message)"
        return $null
    }
}

function Get-OneDriveUsage {
    <#
        Combines both signals into one answer for the operator.

        .Detected  - something says this migration involves OneDrive data
        .Folders   - the OneDrive folders found, with the profile they came from
        .InGroup   - $true / $false / $null (see Test-OneDriveGroupMember)
        .Lines     - ready-to-print evidence, in the order it should be shown
    #>
    param(
        [string]$Username = "",
        [string]$ComputerName = $env:COMPUTERNAME,
        [bool]$IsRemote = $false,
        [bool]$AllProfiles = $false,
        [string]$GroupName = "",
        [bool]$CheckGroup = $true,
        [string]$FolderPattern = "",
        [long]$MinLocalBytes = -1,       # -1 = use the configured default
        [scriptblock]$OnProgress
    )
    if ($MinLocalBytes -lt 0) { $MinLocalBytes = $Script:OneDriveMinLocalBytes }
    $res = @{
        Detected = $false; Folders = @(); InGroup = $null
        GroupName = $(if ($GroupName) { $GroupName } else { $Script:OneDriveGroupName })
        Lines = @(); ProfileHost = $ComputerName; Checked = $true; Error = ""
        LocalBytes = [uint64]0; CloudBytes = [uint64]0; Measured = $false
        BelowThreshold = $false; MinLocalBytes = $MinLocalBytes
    }

    # Which profiles to look in. All Profiles has no single username, so the
    # folder walk covers every profile on the box.
    $users = @()
    if ($AllProfiles) {
        $usersRoot = if ($IsRemote) { "\\$ComputerName\C$\Users" } else { "C:\Users" }
        try {
            if (Test-Path $usersRoot -ErrorAction SilentlyContinue) {
                $skip = @("Public","Default","Default User","All Users","defaultuser0")
                $users = @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue |
                           Where-Object { $skip -notcontains $_.Name } | ForEach-Object { $_.Name })
            } else {
                $res.Checked = $false
                $res.Error   = "could not read $usersRoot"
            }
        } catch { $res.Checked = $false; $res.Error = $_.Exception.Message }
    } elseif ($Username) {
        $users = @($Username)
        # A single Test-Path cannot tell "this user has no profile here" from
        # "this machine is unreachable", and the two must not print the same
        # thing: the second one is not evidence that OneDrive is unused. So the
        # profile ROOT is probed as well - if that is unreadable, the whole
        # answer is downgraded to "not checked".
        $usersRoot = if ($IsRemote) { "\\$ComputerName\C$\Users" } else { "C:\Users" }
        try {
            if (-not (Test-Path $usersRoot -ErrorAction SilentlyContinue)) {
                $res.Checked = $false
                $res.Error   = "could not read $usersRoot"
            }
        } catch { $res.Checked = $false; $res.Error = $_.Exception.Message }
    }

    foreach ($u in $users) {
        foreach ($f in (Get-OneDriveFolders -Username $u -ComputerName $ComputerName -IsRemote $IsRemote -Pattern $FolderPattern)) {
            $res.Folders += ($f + @{ User = $u })
        }
    }
    # Same trap as in Get-OneDriveFolders: one folder must count as one, not as
    # the number of keys in the hashtable describing it.
    $res.Folders = @($res.Folders)
    if ($res.Folders.Count -gt 0) {
        $res.Detected = $true
        foreach ($f in $res.Folders) {
            $note = if ($f.HasItems) { "" } else { "  (empty)" }
            $res.Lines += "  $($f.Path)$note"
        }

        # Measure what is really on disk in them, if a threshold is set. Only
        # the folders themselves are walked, not the whole profile, and
        # cloud-only files contribute nothing - so a fully dehydrated OneDrive
        # comes out near zero however large it looks in Explorer.
        if ($MinLocalBytes -gt 0) {
            $local = [uint64]0; $cloud = [uint64]0; $ok = $false
            foreach ($f in $res.Folders) {
                $r = Get-FolderSizeInfo -Path $f.Path -OnProgress $OnProgress
                if ($r.Ok) { $ok = $true; $local += [uint64]$r.Bytes; $cloud += [uint64]$r.CloudBytes }
            }
            if ($ok) {
                $res.Measured   = $true
                $res.LocalBytes = $local
                $res.CloudBytes = $cloud
                $res.Lines += "  $(Format-Size $local) held locally, $(Format-Size $cloud) cloud-only"
                if ($local -lt $MinLocalBytes) {
                    # Present, but excluding it would save almost nothing - so
                    # this is not worth stopping the operator for.
                    $res.Detected       = $false
                    $res.BelowThreshold = $true
                    $res.Lines += "  below the $(Format-Size $MinLocalBytes) threshold - not worth excluding"
                }
            }
        }
    }

    if (-not $res.Checked) { $res.Lines += "  profile folders could not be read - $($res.Error)" }

    # The group question only makes sense for a named user. It is asked even
    # when the profile could not be read: AD still knows whether this user is
    # supposed to be syncing, which is exactly the case the folder check misses.
    if ($CheckGroup -and -not $AllProfiles -and $Username) {
        $res.InGroup = Test-OneDriveGroupMember -Username $Username -GroupName $res.GroupName
        if ($res.InGroup -eq $true) {
            # Membership must NOT override a measurement. Where OneDrive is
            # rolled out to everyone the group is true of everyone, so it says
            # nothing about this profile; the bytes on disk do. It still raises
            # the flag on its own when nothing could be measured - that is the
            # case it exists for.
            if (-not $res.BelowThreshold) { $res.Detected = $true }
            $res.Lines += "  $Username is a member of $($res.GroupName)"
        } elseif ($null -eq $res.InGroup) {
            $res.Lines += "  group membership could not be checked ($($res.GroupName))"
        }
    }
    return $res
}

# ---------------------------------------------------------------------------
#  Pre-flight Checks
#
#  Both of these answer questions a technician would otherwise only discover an
#  hour into a migration: is there room for the store, and is this profile even
#  live. They are deliberately fast - a free-space call and one directory
#  listing - so they can run synchronously before the operation starts.
# ---------------------------------------------------------------------------
$Script:PreflightMinFreeGB = 20      # warn below this much free space
$Script:PreflightInactiveDays = 90   # warn if a profile has not been used in this long
# Flat allowance added to a measured profile when judging whether a store fits.
# Covers what a folder walk cannot see - NTUSER.DAT and UsrClass.dat, the
# system-context components, and the store catalog. Calibrated against a real
# migration where 0.6 GB of measured payload produced a 1.6 GB store.
$Script:StoreOverheadBytes = 2GB

try {
    if (-not ('DiskHelper' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DiskHelper {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetDiskFreeSpaceEx(string dir, out ulong freeForCaller, out ulong total, out ulong totalFree);

    // Works for local paths, mapped drives and UNC shares alike, which matters
    // because the destination is usually \\PC\C$ and WMI would need DCOM.
    public static bool TryGet(string path, out ulong free, out ulong total) {
        free = 0; total = 0;
        ulong f, t, tf;
        if (GetDiskFreeSpaceEx(path, out f, out t, out tf)) { free = f; total = t; return true; }
        return false;
    }
}
"@ -ErrorAction Stop
    }
    $Script:DiskHelperAvailable = $true
} catch {
    $Script:DiskHelperAvailable = $false
}

function Get-USMTErrorSummary {
    <#
        USMT's own account of what went wrong, lifted out of the detail log.

        THE EXIT CODE IS NOT THE DIAGNOSIS. Code 26 is USMT_INIT_ERROR, and the
        table entry for it says "bad XML, more than one Windows installation, or
        an unknown fault" - so a run that filled the destination disk was
        reported to the operator as a migration-XML problem, while the log said
        in plain words:

            |  Error Code | Caused Abort | Recurrence | First Occurence
            |         112 |           No |      25427 | Write error 112 ...
            |        Tips | Not enough disk space, please select another location

        USMT writes that summary itself, including the tip. Reading it back
        costs a few lines and turns a misleading answer into the right one.

        Returns @{ Codes; Tips; Text } or $null when the log has no summary -
        an aborted start-up genuinely has nothing to report.
    #>
    param([Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
    try {
        # These logs run to tens of megabytes and the summary is at the END, so
        # only the tail is read. Reading the whole thing to find the last 30
        # lines is how a failure dialog comes to take a minute to appear.
        $tail = Get-Content -LiteralPath $LogPath -Tail 120 -ErrorAction Stop
    } catch { return $null }

    $codes = @(); $tips = @()
    foreach ($line in $tail) {
        $t = "$line"
        # "|   112 | No | 25427 | Write error 112 for C:\... description: ..."
        if ($t -match '\|\s*(\d{2,5})\s*\|\s*(Yes|No)\s*\|\s*(\d+)\s*\|\s*(.+?)\s*$') {
            $codes += @{ Code = [int]$Matches[1]; Aborted = ($Matches[2] -eq "Yes")
                         Count = [int]$Matches[3]; First = $Matches[4].Trim() }
        }
        elseif ($t -match '\|\s*Tips\s*\|\s*(.+?)\s*$') { $tips += $Matches[1].Trim() }
    }
    if (-not $codes.Count -and -not $tips.Count) { return $null }

    $text = @()
    foreach ($c in $codes) {
        $times = if ($c.Count -gt 1) { " ($($c.Count) times)" } else { "" }
        $text += "USMT error $($c.Code)$times - $($c.First)"
    }
    foreach ($tp in $tips) { $text += "USMT suggests: $tp" }
    return @{ Codes = @($codes); Tips = @($tips); Text = @($text) }
}

function Get-FreeSpaceInfo {
    <#
    .SYNOPSIS
        Free/total bytes for whatever volume backs $Path. Walks up to the nearest
        existing parent, so it still answers for a store folder not created yet.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Script:DiskHelperAvailable) { return $null }
    try {
        $probe = $Path
        # GetDiskFreeSpaceEx needs a directory that exists.
        $guard = 0
        while ($probe -and -not (Test-Path $probe -PathType Container -ErrorAction SilentlyContinue)) {
            $parent = Split-Path $probe -Parent
            if (-not $parent -or $parent -eq $probe -or $guard -gt 40) { break }
            $probe = $parent; $guard++
        }
        if (-not $probe -or -not (Test-Path $probe -PathType Container -ErrorAction SilentlyContinue)) { return $null }
        if (-not $probe.EndsWith('\')) { $probe = "$probe\" }

        $free = [uint64]0; $total = [uint64]0
        if ([DiskHelper]::TryGet($probe, [ref]$free, [ref]$total)) {
            $freeGB  = [Math]::Round($free  / 1GB, 1)
            $totalGB = [Math]::Round($total / 1GB, 1)
            $pct     = if ($total -gt 0) { [Math]::Round(($free / [double]$total) * 100, 1) } else { 0 }
            return @{ FreeGB = $freeGB; TotalGB = $totalGB; PercentFree = $pct; Probed = $probe }
        }
    } catch {
        Write-CrashLog "Free space check failed for '$Path': $($_.Exception.Message)"
    }
    return $null
}

function Get-InactiveProfiles {
    <#
    .SYNOPSIS
        Profiles on $ComputerName not used in $InactiveDays days.
    .DESCRIPTION
        NTUSER.DAT's last write is the usual proxy for last logon - it is
        flushed when the hive unloads at sign-out. Falls back to the profile
        folder timestamp when the hive cannot be read. Built-in and service
        profiles are skipped; they are never migration candidates.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [int]$InactiveDays = 90,
        [string]$OnlyUser = ""
    )
    $skip = @("Public", "Default", "Default User", "All Users", "defaultuser0",
              "Administrator", "MSSQL`$MICROSOFT##WID", "systemprofile", "LocalService", "NetworkService")
    $results = @()
    try {
        $root = if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) { "\\$ComputerName\C$\Users" } else { "C:\Users" }
        if (-not (Test-Path $root -ErrorAction SilentlyContinue)) {
            return @{ Ok = $false; Error = "Cannot read $root"; Profiles = @() }
        }
        $dirs = Get-ChildItem -Path $root -Directory -Force -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            if ($skip -contains $d.Name) { continue }
            if ($OnlyUser -and $d.Name -ne $OnlyUser) { continue }
            $stamp = $null
            try {
                $hive = Join-Path $d.FullName "NTUSER.DAT"
                if (Test-Path $hive -ErrorAction SilentlyContinue) {
                    $stamp = (Get-Item $hive -Force -ErrorAction Stop).LastWriteTime
                }
            } catch { }
            if (-not $stamp) { $stamp = $d.LastWriteTime }
            if (-not $stamp) { continue }
            $days = [int]((Get-Date) - $stamp).TotalDays
            if ($days -ge $InactiveDays) {
                $results += @{ Name = $d.Name; LastUsed = $stamp; DaysIdle = $days }
            }
        }
        # @() is load-bearing: Sort-Object unwraps a single-element array, and
        # .Count on a bare hashtable returns its KEY count (3), not 1.
        return @{ Ok = $true; Error = ""; Profiles = @($results | Sort-Object { $_.DaysIdle } -Descending) }
    } catch {
        Write-CrashLog "Inactive profile check failed on ${ComputerName}: $($_.Exception.Message)"
        return @{ Ok = $false; Error = $_.Exception.Message; Profiles = @() }
    }
}

function Invoke-PreflightChecks {
    <#
    .SYNOPSIS
        Runs the enabled checks and returns findings for the GUI to present.
    .DESCRIPTION
        Returns @{ Warnings = @(strings); Info = @(strings) }. Info always gets
        the measured numbers so they land in the log even when nothing is wrong;
        Warnings are what the technician is asked to confirm.
    #>
    param(
        [bool]$CheckDisk        = $true,
        [bool]$CheckInactive    = $true,
        [string[]]$SpacePaths   = @(),      # label|path pairs, e.g. "Destination|\\PC\C$\..."
        [string]$ProfileHostPC  = "",
        [string]$OnlyUser       = "",
        [bool]$AllProfiles      = $false,
        [double]$MinFreeGB      = 0,
        [int]$InactiveDays      = 0
    )
    if ($MinFreeGB    -le 0) { $MinFreeGB    = $Script:PreflightMinFreeGB }
    if ($InactiveDays -le 0) { $InactiveDays = $Script:PreflightInactiveDays }

    $warnings = @(); $info = @()

    if ($CheckDisk) {
        foreach ($entry in $SpacePaths) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $parts = $entry -split '\|', 2
            if ($parts.Count -lt 2) { continue }
            $label = $parts[0]; $path = $parts[1]
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $sp = Get-FreeSpaceInfo -Path $path
            if (-not $sp) {
                $info += "  $label free space could not be determined ($path)"
                continue
            }
            $info += "  {0,-14} {1} GB free of {2} GB ({3}% free)" -f $label, $sp.FreeGB, $sp.TotalGB, $sp.PercentFree
            if ($sp.FreeGB -lt $MinFreeGB) {
                $warnings += "$label has only $($sp.FreeGB) GB free (below the $MinFreeGB GB threshold)."
            } elseif ($sp.PercentFree -lt 10) {
                $warnings += "$label is $([Math]::Round(100 - $sp.PercentFree,1))% full ($($sp.FreeGB) GB free)."
            }
        }
    }

    if ($CheckInactive -and $ProfileHostPC) {
        $res = Get-InactiveProfiles -ComputerName $ProfileHostPC -InactiveDays $InactiveDays -OnlyUser $OnlyUser
        if (-not $res.Ok) {
            $info += "  Stale profiles skipped: $($res.Error)"
        } elseif ($res.Profiles.Count -eq 0) {
            $info += "  Stale profiles none idle $InactiveDays+ days"
        } else {
            foreach ($p in $res.Profiles) {
                $when = $p.LastUsed.ToString('yyyy-MM-dd')
                if ($OnlyUser) {
                    $warnings += "Profile '$($p.Name)' has not been used since $when ($($p.DaysIdle) days). Check you have the right account."
                } else {
                    $warnings += "Profile '$($p.Name)' idle $($p.DaysIdle) days (last used $when)."
                }
            }
        }
    }

    return @{ Warnings = @($warnings); Info = @($info) }
}

# ---------------------------------------------------------------------------
#  DIRECT-TO-DESTINATION STORE
#
#  The remote task runs as SYSTEM, and SYSTEM holds no user credentials on the
#  network - it authenticates as the machine account, DOMAIN\SOURCEPC$. That
#  account is not a local administrator on the destination, so scanstate can
#  never reach \\DESTPC\C$. This is not a USMT limitation: scanstate writes to
#  a UNC store perfectly well and streams into it as it goes, so the store need
#  never touch the source machine's own disk at all.
#
#  The fix is to give the source machine account a door of its own - a share on
#  the destination, scoped by NTFS to that single computer account, torn down
#  when the migration ends.
#
#  Creating a share has to happen ON the destination, so it goes over DCOM via
#  Win32_Share - the same RPC channel schtasks already uses, so it needs nothing
#  WinRM-shaped. The NTFS ACE is set from here across C$, because the technician
#  running the GUI already has admin rights there.
# ---------------------------------------------------------------------------
$Script:DirectShareName = "UTWStore$"    # trailing $ = hidden share

function Get-MachineAccountName {
    <#
    .SYNOPSIS
        DOMAIN\PCNAME$ - the identity a SYSTEM process on that PC presents to
        the network.
    #>
    param([Parameter(Mandatory)][string]$ComputerName)
    $d = $Script:AppConfig.Domain
    if ([string]::IsNullOrWhiteSpace($d) -or $d -eq "*") { $d = $env:USERDOMAIN }
    return "$d\$($ComputerName.Trim())$"
}

function Grant-StoreFolderAccess {
    param(
        [Parameter(Mandatory)][string]$FolderUNC,
        [Parameter(Mandatory)][string]$Identity
    )
    $acl  = Get-Acl -Path $FolderUNC -ErrorAction Stop
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity,
        [System.Security.AccessControl.FileSystemRights]::Modify,
        ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
         [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    Set-Acl -Path $FolderUNC -AclObject $acl -ErrorAction Stop
    Write-CrashLog "Granted Modify to $Identity on $FolderUNC"
}

function Revoke-AllMachineAccess {
    <#
    .SYNOPSIS
        Strips every computer-account ACE from a folder.
    .DESCRIPTION
        Used when cleaning up after a run that died without telling us which
        machine it had granted - computer accounts end in '$', which is what
        makes them identifiable without knowing the source PC's name.
    #>
    param([string]$FolderUNC)
    try {
        if ([string]::IsNullOrWhiteSpace($FolderUNC) -or -not (Test-Path $FolderUNC)) { return }
        $acl = Get-Acl -Path $FolderUNC -ErrorAction Stop
        $removed = $false
        foreach ($ace in @($acl.Access)) {
            if ($ace.IsInherited) { continue }
            $v = "$($ace.IdentityReference.Value)"
            if ($v.EndsWith('$') -and $v -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)\$?$') {
                [void]$acl.RemoveAccessRule($ace); $removed = $true
            }
        }
        if ($removed) {
            Set-Acl -Path $FolderUNC -AclObject $acl -ErrorAction Stop
            Write-CrashLog "Removed computer-account ACEs from $FolderUNC"
        }
    } catch { Write-CrashLog "Could not clean ACEs on ${FolderUNC}: $($_.Exception.Message)" }
}

function Revoke-StoreFolderAccess {
    param([string]$FolderUNC, [string]$Identity)
    try {
        if ([string]::IsNullOrWhiteSpace($FolderUNC) -or -not (Test-Path $FolderUNC)) { return }
        $acl = Get-Acl -Path $FolderUNC -ErrorAction Stop
        $removed = $false
        foreach ($ace in @($acl.Access)) {
            if ($ace.IdentityReference.Value -ieq $Identity) { [void]$acl.RemoveAccessRule($ace); $removed = $true }
        }
        if ($removed) {
            Set-Acl -Path $FolderUNC -AclObject $acl -ErrorAction Stop
            Write-CrashLog "Revoked $Identity on $FolderUNC"
        }
    } catch { Write-CrashLog "Could not revoke $Identity on ${FolderUNC}: $($_.Exception.Message)" }
}

function New-DestStoreShare {
    <#
    .SYNOPSIS
        Opens a temporary, tightly scoped write path on the destination so the
        source PC can stream its store straight there.
    .DESCRIPTION
        Returns a hashtable describing the share, which must be handed back to
        Remove-DestStoreShare when the migration finishes OR fails. Throws if
        the share cannot be created, so the caller can fall back to the older
        stage-then-robocopy route.
    #>
    param(
        [Parameter(Mandatory)][string]$DestPC,
        [Parameter(Mandatory)][string]$SourcePC,
        [Parameter(Mandatory)][string]$LocalPath,   # path as the DESTINATION sees it, e.g. C:\USMT Profiles
        [string]$ShareName = ""
    )
    if ([string]::IsNullOrWhiteSpace($ShareName)) { $ShareName = $Script:DirectShareName }
    $folderUNC = "\\$DestPC\" + ($LocalPath -replace '^([A-Za-z]):', '$1$')
    $machine   = Get-MachineAccountName -ComputerName $SourcePC

    if (-not (Test-Path $folderUNC)) {
        New-Item -Path $folderUNC -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    Grant-StoreFolderAccess -FolderUNC $folderUNC -Identity $machine

    # Effective access over SMB is the INTERSECTION of the share ACL and the
    # NTFS ACL. Creating the share without an explicit Access descriptor does
    # not leave it wide open - it lands on a default that denies the machine
    # account write, so ScanState reaches the share and then fails to create
    # its store directory: "Access is denied" 0x5, surfacing as USMT error 27.
    # The share ACL therefore has to name the writer explicitly.
    $sidBytes = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($machine)).Translate([System.Security.Principal.SecurityIdentifier])
        $sidBytes = New-Object byte[] $sid.BinaryLength
        $sid.GetBinaryForm($sidBytes, 0)
    } catch {
        Revoke-StoreFolderAccess -FolderUNC $folderUNC -Identity $machine
        throw "Could not resolve the computer account '$machine': $($_.Exception.Message)"
    }

    $FULL_CONTROL = 2032127
    $aces = @()
    foreach ($who in @(@{ Sid = $sidBytes; Name = $machine },
                       @{ Sid = $null;     Name = "BUILTIN\Administrators" })) {
        $tr = ([WMIClass]"\\$DestPC\root\cimv2:Win32_Trustee").CreateInstance()
        if ($who.Sid) {
            $tr.SID       = $who.Sid
            $tr.SidLength = $who.Sid.Length
        } else {
            # Well-known, so let the destination resolve it rather than assuming
            # this machine and that one agree on the name.
            $adminSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
            $b = New-Object byte[] $adminSid.BinaryLength
            $adminSid.GetBinaryForm($b, 0)
            $tr.SID = $b; $tr.SidLength = $b.Length
        }
        $ace = ([WMIClass]"\\$DestPC\root\cimv2:Win32_ACE").CreateInstance()
        $ace.AccessMask = $FULL_CONTROL
        $ace.AceFlags   = 0        # share ACEs do not inherit
        $ace.AceType    = 0        # access allowed
        $ace.Trustee    = $tr
        $aces += $ace
    }
    $sd = ([WMIClass]"\\$DestPC\root\cimv2:Win32_SecurityDescriptor").CreateInstance()
    $sd.ControlFlags = 4           # SE_DACL_PRESENT
    $sd.DACL         = $aces

    $cls = [wmiclass]"\\$DestPC\root\cimv2:Win32_Share"

    # A share left over from an earlier run keeps ITS old permissions, and
    # Create would just return 22 "already exists" while the stale ACL quietly
    # continued to deny the write. Always start from a fresh share.
    try {
        $old = Get-WmiObject -Class Win32_Share -ComputerName $DestPC -Filter "Name='$ShareName'" -ErrorAction SilentlyContinue
        if ($old) { [void]$old.Delete(); Write-CrashLog "Removed a pre-existing '$ShareName' share on $DestPC before recreating it" }
    } catch { }

    $inParams = $cls.psbase.GetMethodParameters("Create")
    $inParams.Path        = $LocalPath
    $inParams.Name        = $ShareName
    $inParams.Type        = [uint32]0        # disk drive
    $inParams.Description = "UTW migration store (temporary)"
    $inParams.Access      = $sd
    $res = $cls.psbase.InvokeMethod("Create", $inParams, $null)
    $rc  = [int]$res.ReturnValue
    if ($rc -ne 0) {
        Revoke-StoreFolderAccess -FolderUNC $folderUNC -Identity $machine
        throw "Could not create share '$ShareName' on ${DestPC}: Win32_Share.Create returned $rc ($(Get-ShareErrorText $rc))"
    }

    # Read the ACL back. If the descriptor did not take, failing here means a
    # clean fall back to the staged route instead of a ScanState error 27 five
    # seconds into the capture.
    $verified = Test-ShareGrantsWriter -DestPC $DestPC -ShareName $ShareName -ExpectedSid $sid.Value
    if (-not $verified) {
        try { $s = Get-WmiObject -Class Win32_Share -ComputerName $DestPC -Filter "Name='$ShareName'" -ErrorAction SilentlyContinue; if ($s) { [void]$s.Delete() } } catch { }
        Revoke-StoreFolderAccess -FolderUNC $folderUNC -Identity $machine
        throw "Share '$ShareName' was created on $DestPC but does not grant write access to $machine"
    }

    Write-CrashLog "Direct store share ready: \\$DestPC\$ShareName -> $LocalPath (writer: $machine / $($sid.Value))"

    return @{
        ShareName = $ShareName
        ShareUNC  = "\\$DestPC\$ShareName"
        FolderUNC = $folderUNC
        LocalPath = $LocalPath
        Machine   = $machine
        DestPC    = $DestPC
    }
}

function Get-ShareErrorText {
    param([int]$Code)
    switch ($Code) {
        2  { "access denied" }
        8  { "unknown failure" }
        9  { "invalid name" }
        10 { "invalid level" }
        21 { "invalid parameter" }
        22 { "duplicate share" }
        23 { "redirected path" }
        24 { "unknown device or directory" }
        25 { "net name not found" }
        default { "code $Code" }
    }
}

function Test-ShareGrantsWriter {
    <#
    .SYNOPSIS
        Confirms the share's DACL actually names the SID we asked for.
    #>
    param(
        [Parameter(Mandatory)][string]$DestPC,
        [Parameter(Mandatory)][string]$ShareName,
        [Parameter(Mandatory)][string]$ExpectedSid
    )
    try {
        $sec = Get-WmiObject -Class Win32_LogicalShareSecuritySetting -ComputerName $DestPC `
                    -Filter "Name='$ShareName'" -ErrorAction Stop
        if (-not $sec) { Write-CrashLog "No security setting returned for share '$ShareName'"; return $false }
        $out = $sec.GetSecurityDescriptor()
        if ([int]$out.ReturnValue -ne 0) { Write-CrashLog "GetSecurityDescriptor returned $($out.ReturnValue)"; return $false }
        foreach ($ace in @($out.Descriptor.DACL)) {
            $t = $ace.Trustee
            if (-not $t) { continue }
            if ($t.SIDString -eq $ExpectedSid -and ([int]$ace.AccessMask -band 0x2) -ne 0) { return $true }
        }
        Write-CrashLog "Share '$ShareName' DACL does not contain $ExpectedSid with write access"
        return $false
    } catch {
        Write-CrashLog "Could not read share security for '$ShareName': $($_.Exception.Message)"
        return $false
    }
}

function Remove-DestStoreShare {
    <#
    .SYNOPSIS
        Tears down the temporary share and the machine-account ACE. Safe to call
        twice, and never throws - cleanup must not mask the real outcome.
    #>
    param($Share)
    if (-not $Share) { return }
    try {
        $s = Get-WmiObject -Class Win32_Share -ComputerName $Share.DestPC `
                -Filter "Name='$($Share.ShareName)'" -ErrorAction Stop
        if ($s) { [void]$s.Delete(); Write-CrashLog "Removed share $($Share.ShareName) on $($Share.DestPC)" }
    } catch {
        Write-CrashLog "Could not remove share $($Share.ShareName) on $($Share.DestPC): $($_.Exception.Message)"
    }
    Revoke-StoreFolderAccess -FolderUNC $Share.FolderUNC -Identity $Share.Machine
}

# ---------------------------------------------------------------------------
#  PROFILE SIZE  -  how much is actually there
#
#  This used to run scanstate /p, which walks the whole profile applying every
#  migration rule just to report a number - so a migration paid for two full
#  passes over the same data. Measuring the profile folder answers the same
#  question directly and takes seconds.
#
#  The number is deliberately an UPPER bound: USMT compresses the store, so a
#  destination with room for the raw profile always has room for the store. It
#  can over-warn; it cannot let a migration start that was never going to fit.
# ---------------------------------------------------------------------------
# Cloud placeholders report their full logical size through FileInfo.Length
# while occupying nothing locally, so counting them makes a OneDrive profile
# look enormous. OFFLINE and RECALL_ON_DATA_ACCESS are how Windows marks a
# dehydrated file.
#
# REPARSE_POINT deliberately is NOT in this mask. Files On-Demand tags EVERY
# synced item as a reparse point whether or not it is downloaded, so testing
# for it throws away the whole OneDrive folder - which is usually the data
# people most want migrated.
$Script:AttrOffline      = 0x1000
$Script:AttrReparsePoint = 0x400
$Script:AttrRecallAccess = 0x400000
$Script:AttrSystem       = 0x4

# AppData cannot be treated as one thing. Excluding all of it undercounts badly,
# because migapp.xml pulls real payload out of it - the Outlook data file alone
# is routinely the largest single item in a migration. Including all of it
# overcounts just as badly, because AppData\Local is mostly caches, temp files
# and app packages that never reach the store.
#
# So: skip AppData on the main walk, then add back the parts USMT actually
# captures. These paths are the ones behind the "Outlook Settings", "Firefox
# Browser Data", "Chrome Browser Data" and "Microsoft Office 16" components.
$Script:ProfileSkipDirs = @("AppData")
$Script:ProfileAppDataIncludes = @(
    @{ Path = "AppData\Roaming";                       Label = "app settings (Roaming)" },
    @{ Path = "AppData\Local\Microsoft\Outlook";       Label = "Outlook data" },
    @{ Path = "AppData\Local\Google\Chrome\User Data"; Label = "Chrome profile" },
    @{ Path = "AppData\Local\Microsoft\Edge\User Data"; Label = "Edge profile" }
)

function Test-IsElevated {
    <#
    .SYNOPSIS
        True when this process is running with administrator rights.
    .DESCRIPTION
        Almost everything here needs them - admin shares, scheduled tasks on
        another machine, creating a share, reading another profile's files. A
        non-elevated run fails several minutes in with an access-denied that
        looks like a network or permissions problem on the far end, so it is
        worth saying up front instead.
    #>
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-CrashLog "Could not determine elevation: $($_.Exception.Message)"
        return $false
    }
}

function Format-Size {
    <#
    .SYNOPSIS
        Bytes as the unit a person would actually say out loud.
    #>
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "$([Math]::Round($Bytes / 1TB, 2)) TB" }
    if ($Bytes -ge 1GB) { return "$([Math]::Round($Bytes / 1GB, 2)) GB" }
    if ($Bytes -ge 1MB) { return "$([Math]::Round($Bytes / 1MB, 1)) MB" }
    if ($Bytes -ge 1KB) { return "$([Math]::Round($Bytes / 1KB, 1)) KB" }
    return "$([int]$Bytes) bytes"
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 60) { return "{0}s" -f [int]$Span.TotalSeconds }
    if ($Span.TotalHours   -lt 1)  { return "{0}m {1}s" -f $Span.Minutes, $Span.Seconds }
    return "{0}h {1}m {2}s" -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds
}

function Get-StoreSizeOnDisk {
    <#
    .SYNOPSIS
        Size of a finished store. USMT never reports this itself.
    .DESCRIPTION
        Sums every file under the store folder rather than looking for
        USMT.MIG alone - a store can be split across .mig/.mig1/.mig2.
    #>
    param([Parameter(Mandatory)][string]$StorePath)
    try {
        if ([string]::IsNullOrWhiteSpace($StorePath) -or -not (Test-Path -LiteralPath $StorePath -ErrorAction SilentlyContinue)) {
            return $null
        }
        $bytes = [uint64]0; $n = 0
        foreach ($f in [System.IO.Directory]::EnumerateFiles($StorePath, "*", [System.IO.SearchOption]::AllDirectories)) {
            try { $bytes += [uint64](New-Object System.IO.FileInfo $f).Length; $n++ } catch { }
        }
        if ($n -eq 0) { return $null }
        return @{ Bytes = $bytes; Text = (Format-Size $bytes); Files = $n }
    } catch {
        Write-CrashLog "Could not size the store at '$StorePath': $($_.Exception.Message)"
        return $null
    }
}

function Get-FolderSizeInfo {
    <#
    .SYNOPSIS
        Recursive size of a folder, counting only what a migration would carry.
    .DESCRIPTION
        Uses an explicit stack with EnumerateFiles rather than Get-ChildItem
        -Recurse: a profile is tens of thousands of files and the pipeline
        overhead dominates, which matters most over a UNC.

        Per-directory try/catch is load-bearing - one locked or denied subfolder
        must not lose the whole measurement.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludeNames = @(),
        [scriptblock]$OnProgress    # called per directory so the GUI can stay awake
    )
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Error = "not found"; Bytes = [uint64]0; GB = 0
                  Files = 0; Skipped = 0; CloudBytes = [uint64]0; CloudGB = 0; ExcludedDirs = 0 }
    }
    $bytes = [uint64]0; $cloud = [uint64]0
    $files = 0; $skipped = 0; $dirs = 0; $excluded = 0
    $mask  = $Script:AttrOffline -bor $Script:AttrRecallAccess

    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop(); $dirs++
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($cur)) {
                try {
                    $fi = New-Object System.IO.FileInfo $f
                    if (([int]$fi.Attributes -band $mask) -ne 0) { $cloud += [uint64]$fi.Length }
                    else { $bytes += [uint64]$fi.Length; $files++ }
                } catch { $skipped++ }
            }
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($cur)) {
                $name = [System.IO.Path]::GetFileName($d)
                if ($ExcludeNames -contains $name) { $excluded++; continue }
                # Skip the legacy per-user compatibility junctions ("My Documents",
                # "Local Settings", "Cookies"...) which point back inside the
                # profile and would double-count or loop. They are the reparse
                # points that are also System; a OneDrive folder is a reparse
                # point too but is not System, so it still gets walked.
                try {
                    $a = [int](New-Object System.IO.DirectoryInfo $d).Attributes
                    if ((($a -band $Script:AttrReparsePoint) -ne 0) -and
                        (($a -band $Script:AttrSystem) -ne 0)) { $excluded++; continue }
                } catch { }
                $stack.Push($d)
            }
        } catch { $skipped++ }
        if ($OnProgress -and ($dirs % 200 -eq 0)) { & $OnProgress $dirs $files }
    }
    return @{
        Ok = $true; Error = ""
        Bytes = $bytes; GB = [Math]::Round($bytes / 1GB, 2)
        Files = $files; Skipped = $skipped
        CloudBytes = $cloud; CloudGB = [Math]::Round($cloud / 1GB, 2)
        ExcludedDirs = $excluded
    }
}

function Get-ProfileSizeInfo {
    <#
    .SYNOPSIS
        Measures what a migration will actually be carrying: one profile, or
        every real profile on the machine when the scope is All Profiles.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$OnlyUser  = "",
        [bool]$AllProfiles = $false,
        [scriptblock]$OnProgress,
        # Mirrors what ScanState is about to be told. An estimate that counts
        # folders the run will skip describes a different capture than the one
        # being launched, which is worse than no estimate at all.
        [bool]$ExcludeOneDrive = $false
    )
    $isLocal = ($ComputerName -eq $env:COMPUTERNAME) -or ($ComputerName -eq ".")
    $usersRoot = if ($isLocal) { "C:\Users" } else { "\\$ComputerName\C`$\Users" }

    if (-not (Test-Path $usersRoot -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Error = "cannot reach $usersRoot"; GB = 0; Parts = @() }
    }

    $targets = @()
    if ($AllProfiles) {
        # Same exclusions the inactive-profile check uses - built-in and service
        # profiles are not what anyone means by "all profiles".
        $skip = @("Public","Default","Default User","All Users","defaultuser0","Administrator",
                  "systemprofile","LocalService","NetworkService")
        foreach ($d in (Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($skip -notcontains $d.Name) { $targets += $d.FullName }
        }
    } elseif ($OnlyUser) {
        $targets += (Join-Path $usersRoot $OnlyUser)
    }

    if ($targets.Count -eq 0) {
        return @{ Ok = $false; Error = "no profile folders to measure"; GB = 0; Parts = @() }
    }

    $total = [uint64]0; $cloud = [uint64]0
    $files = 0; $skipped = 0; $parts = @(); $anyOk = $false
    $breakdown = [ordered]@{}

    foreach ($t in $targets) {
        $leaf = Split-Path $t -Leaf
        # User data: everything outside AppData.
        $skipNames = $Script:ProfileSkipDirs
        if ($ExcludeOneDrive) {
            # Resolved per profile rather than hard-coded: the folder is named
            # after the tenant ("OneDrive - Contoso") and a profile can hold both
            # that and a personal "OneDrive".
            try {
                $odNames = @(Get-ChildItem -LiteralPath $t -Directory -Filter "OneDrive*" -Force -ErrorAction SilentlyContinue |
                             ForEach-Object { $_.Name })
                if ($odNames.Count -gt 0) { $skipNames = @($skipNames) + $odNames }
            } catch { }
        }
        $r = Get-FolderSizeInfo -Path $t -ExcludeNames $skipNames -OnProgress $OnProgress
        if (-not $r.Ok) { $parts += "${leaf}: $($r.Error)"; continue }
        $anyOk = $true
        $total += $r.Bytes; $cloud += $r.CloudBytes
        $files += $r.Files; $skipped += $r.Skipped
        $breakdown["documents and desktop"] = [uint64]$breakdown["documents and desktop"] + $r.Bytes

        # Add back the AppData subtrees a migration actually carries.
        foreach ($inc in $Script:ProfileAppDataIncludes) {
            $p = Join-Path $t $inc.Path
            if (-not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { continue }
            $ri = Get-FolderSizeInfo -Path $p -OnProgress $OnProgress
            if (-not $ri.Ok) { continue }
            $total += $ri.Bytes; $cloud += $ri.CloudBytes
            $files += $ri.Files; $skipped += $ri.Skipped
            $breakdown[$inc.Label] = [uint64]$breakdown[$inc.Label] + $ri.Bytes
        }

        # Deliberately NOT measuring the whole of AppData for context: it is the
        # bulk of the files in a profile, so walking it would roughly double the
        # time for one informational line.
        $parts += "${leaf}: $(Format-Size $r.Bytes) user data"
    }
    if (-not $anyOk) {
        return @{ Ok = $false; Error = "no readable profile folder ($($parts -join ', '))"; GB = 0; Parts = @($parts) }
    }

    # Filter on bytes, not rounded GB - a 500 MB Outlook file rounds to 0.0 GB
    # and would vanish from the breakdown that exists to explain the total.
    $lines = @()
    foreach ($k in $breakdown.Keys) {
        $b = [uint64]$breakdown[$k]
        if ($b -ge 1MB) { $lines += "$k $(Format-Size $b)" }
    }
    return @{
        Ok = $true; Error = ""
        Bytes = $total; GB = [Math]::Round($total / 1GB, 2)
        CloudBytes = $cloud; CloudGB = [Math]::Round($cloud / 1GB, 2)
        Files = $files; Skipped = $skipped
        Parts = @($parts); Breakdown = @($lines)
    }
}

function Test-ProfileSizeAgainstSpace {
    <#
    .SYNOPSIS
        Compares the measured profile size against the destination's free space.
        Returns @{ Warnings; Info } in the same shape as Invoke-PreflightChecks
        so the GUI presents both through one path.
    #>
    param(
        # Not Mandatory: an unreadable profile passes $null, and that has to
        # degrade to an info line rather than throw.
        $Size,
        [Parameter(Mandatory)][string]$DestLabel,
        [Parameter(Mandatory)][string]$DestPath,
        # Set when the disk check has already reported free space, so the
        # figure is not printed twice.
        [bool]$SkipFreeSpaceLine = $false
    )
    $warnings = @(); $info = @()
    if (-not $Size -or -not $Size.Ok) {
        $reason = if ($Size -and $Size.Error) { $Size.Error } else { "could not be measured" }
        $info += "  Profile        $reason"
        return @{ Warnings = @($warnings); Info = @($info) }
    }

    $info += "  {0,-14} {1} in {2:N0} files" -f "Profile", (Format-Size $Size.Bytes), $Size.Files
    # Breakdown on its own line: with four or five categories it is far too long
    # to trail the total without wrapping in the output pane.
    if ($Size.Breakdown -and $Size.Breakdown.Count -gt 0) {
        $info += "                 $($Size.Breakdown -join ', ')"
    }
    if ($Size.Parts -and $Size.Parts.Count -gt 1) { $info += "                 $($Size.Parts -join ', ')" }
    if ($Size.CloudGB -gt 0) {
        $info += "                 plus $(Format-Size $Size.CloudBytes) cloud-only (OneDrive), no local space"
    }

    # A folder walk cannot see everything a store ends up holding: the user's
    # registry hives, the system-context components, and the store's own
    # catalog all land in the .MIG. On a real 0.6 GB measurement the finished
    # store was 1.6 GB, so the fit check allows a flat overhead on top rather
    # than assuming compression makes the store smaller than the payload.
    $needBytes = [double]$Size.Bytes + $Script:StoreOverheadBytes
    $info += "                 allow ~$(Format-Size $needBytes) for the store (registry and system settings add to it)"

    $sp = Get-FreeSpaceInfo -Path $DestPath
    if (-not $sp) {
        $info += "  $DestLabel free space could not be determined ($DestPath)"
        return @{ Warnings = @($warnings); Info = @($info) }
    }
    if (-not $SkipFreeSpaceLine) {
        $info += "  Destination    $($sp.FreeGB) GB free of $($sp.TotalGB) GB ($($sp.PercentFree)% free)"
    }
    $freeBytes = [double]$sp.FreeGB * 1GB
    if ($freeBytes -lt $needBytes) {
        $warnings += "$DestLabel has $(Format-Size $freeBytes) free but the store needs roughly $(Format-Size $needBytes)."
    }
    return @{ Warnings = @($warnings); Info = @($info) }
}

# ---------------------------------------------------------------------------
#  Central store root validation
#
#  A store path is resolved by whichever machine runs scanstate. On a remote
#  export that is the SOURCE PC, so "C:\Users\me\Downloads" silently means a
#  folder on THAT machine - the store goes somewhere nobody looks. A UNC is the
#  only form that means the same thing from every machine, so local paths are
#  refused rather than quietly misfiled.
# ---------------------------------------------------------------------------
function Test-CentralStoreRoot {
    param([string]$Path)
    $p = "$Path".Trim()
    if ([string]::IsNullOrWhiteSpace($p)) {
        return @{ Ok = $false; Reason = "No central store root was entered." }
    }
    if ($p -match '^[A-Za-z]:') {
        return @{ Ok = $false; Reason = "'$p' is a local drive path.`n`nThe store path is resolved by the PC that runs ScanState - on a remote export that is the source PC, not this one, so a C:\ path would write the store onto that machine instead.`n`nUse a UNC path such as \\server\share\UTW-Stores." }
    }
    if (-not $p.StartsWith("\\")) {
        return @{ Ok = $false; Reason = "'$p' is not a UNC path.`n`nUse the \\server\share\folder form so every machine resolves it to the same place." }
    }
    $parts = @($p.TrimEnd('\') -split '\\+' | Where-Object { $_ })
    if ($parts.Count -lt 2) {
        return @{ Ok = $false; Reason = "'$p' is missing a share name. Use \\server\share\folder." }
    }
    # C$, D$, ADMIN$ and friends are administrative shares: reaching one requires
    # local admin on that machine. ScanState runs as SYSTEM, which authenticates
    # as the source's COMPUTER account, and a computer account is never a local
    # admin anywhere else - so the share cannot even be opened. SMB reports that
    # as ERROR_PATH_NOT_FOUND, which surfaces as USMT error 27 "Invalid store
    # path" roughly 16 seconds in, and looks nothing like a permissions problem.
    $share = $parts[1]
    if ($share -match '^[A-Za-z]\$$' -or $share -ieq 'ADMIN$') {
        return @{ Ok = $false; Reason = "'$p' is an administrative share ($share).`n`nScanState runs on the source PC as SYSTEM, so it reaches the network as that machine's computer account - and a computer account is never a local administrator on another machine. Admin shares are therefore unreachable, and USMT reports it as 'Invalid store path'.`n`nUse a real file server share that grants Domain Computers write access.`n`nIf you just want the store on the new PC, choose 'Destination PC (direct)' instead - that route handles the permissions for you." }
    }
    return @{ Ok = $true; Reason = "" }
}

# ---------------------------------------------------------------------------
#  Log Naming
# ---------------------------------------------------------------------------
function Get-SafeNamePart {
    # Keeps a user or machine name usable as part of a file name.
    param([string]$Value)
    $s = ($Value -replace '[\\/:*?"<>|]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return "Unknown" }
    return $s
}

function Get-LogLabel {
    <#
    .SYNOPSIS
        The name that goes in the middle of a log file name.
    .DESCRIPTION
        Mirrors the store path convention in Get-StorePath: a single-profile
        operation is labelled with the user, a whole-machine operation with the
        computer. All-profiles runs used to fall through to $Username, which is
        still holding whatever was typed for the last single-user run - so an
        all-profiles capture would be logged under an unrelated person's name.
    #>
    param(
        [bool]$AllProfiles    = $false,
        [bool]$SettingsOnly   = $false,
        [string]$Username     = "",
        [string]$ComputerName = ""
    )
    if ($SettingsOnly) { return "Settings" }
    if ($AllProfiles) {
        $pc = if ([string]::IsNullOrWhiteSpace($ComputerName)) { $env:COMPUTERNAME } else { $ComputerName }
        return "AllProfiles_$(Get-SafeNamePart $pc)"
    }
    return (Get-SafeNamePart $Username)
}

# ---------------------------------------------------------------------------
#  Store Path Builder
# ---------------------------------------------------------------------------
function Get-StorePath {
    param(
        [string]$Operation,
        [string]$DestType,
        [string]$Username,
        [string]$ComputerName,
        [string]$USBPath,
        [bool]$AllProfiles
    )
    $sub    = $Script:AppConfig.DefaultStorePath
    $folder = if ($AllProfiles) {
        if ($Operation -eq "Export") { $env:COMPUTERNAME } else { $ComputerName }
    } else { $Username }

    if ($DestType -eq "Network") {
        if ($Operation -eq "Export") { return "\\$ComputerName\C$\$sub\$folder" }
        else                         { return "C:\$sub\$folder" }
    } else {
        return Join-Path $USBPath "$sub\$folder"
    }
}

# ---------------------------------------------------------------------------
#  Public Folders XML  -  ensures C:\Users\Public is captured in System context
#  Written to the USMT tools folder on first use; included automatically by
#  Build-USMTCommand when SettingsOnly mode is active.
# ---------------------------------------------------------------------------
function Ensure-PublicFoldersXml {
    param([string]$USMTPath)
    $xmlPath = Join-Path $USMTPath "MigratePublicFolders.xml"
    if (Test-Path $xmlPath) { return $xmlPath }
    $xmlContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<migration urlid="http://www.microsoft.com/migration/1.0/migxmlext/PublicFolders">
  <component type="Documents" context="System">
    <displayName>Public Profile Folders</displayName>
    <role role="Data">
      <rules>
        <include>
          <objectSet>
            <pattern type="File">%PUBLIC%\Documents\* [*]</pattern>
            <pattern type="File">%PUBLIC%\Desktop\* [*]</pattern>
            <pattern type="File">%PUBLIC%\Downloads\* [*]</pattern>
            <pattern type="File">%PUBLIC%\Music\* [*]</pattern>
            <pattern type="File">%PUBLIC%\Pictures\* [*]</pattern>
            <pattern type="File">%PUBLIC%\Videos\* [*]</pattern>
          </objectSet>
        </include>
      </rules>
    </role>
  </component>
</migration>
'@
    try {
        $xmlContent | Out-File -FilePath $xmlPath -Encoding UTF8 -Force
        Write-Log "Created MigratePublicFolders.xml at $xmlPath"
    } catch {
        Write-Log "Failed to create MigratePublicFolders.xml: $($_.Exception.Message)" -Level "WARN"
    }
    return $xmlPath
}

# ---------------------------------------------------------------------------
#  USMT Command Builder
# ---------------------------------------------------------------------------
function Build-USMTArgs {
    <#
        The single place that decides what goes on a ScanState/LoadState command
        line. Local runs, remote runs and the Expert-mode preview all come
        through here, so what the preview shows is what actually runs - two
        copies of this logic would drift the first time either was touched, and
        a preview that lies is worse than no preview.

        Every path is passed in already expressed the way the machine that will
        RUN the command sees it: a remote run passes C:\Windows\Temp\USMT_Temp
        paths even though this process reached them over a UNC to check they
        exist. Deciding whether a file is there is the caller's job for the same
        reason - only the caller knows which end to look at.

        Argument order is fixed and matches what shipped before this was
        extracted; the golden-file test pins it.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet("Export","Import")][string]$Operation,
        [Parameter(Mandatory)][string]$StorePath,
        [string]$MigAppXml   = "",
        [string]$MigUserXml  = "",
        [string]$PublicXml   = "",   # settings-only; "" if not available
        [string]$ConfigXml   = "",   # "" if not available
        [string]$ExcludeXml  = "",   # OneDrive exclusion; "" if not available
        [string]$Username    = "",
        [bool]$AllProfiles   = $false,
        [bool]$SettingsOnly  = $false,
        [int]$Verbosity      = 13,
        [bool]$Overwrite     = $false,
        [string]$LogFile     = "",
        [string]$ProgressLog = "",
        [string]$Domain      = "",
        # Several users in one run. When set it REPLACES the single-user
        # include, because /ui is additive and USMT takes as many as it is given.
        [string[]]$Usernames = @(),
        # Restore under a different account: USMT's /mu, "old:new". Only ever
        # emitted on a LoadState - ScanState has no equivalent and would reject
        # it outright.
        [string]$RenameFrom  = "",
        [string]$RenameTo    = "",
        # Expert mode: anything the operator added that this tool does not model.
        # Placed before the log flags so /l: and /progress: stay at the end where
        # everything reading the command back expects them.
        [string[]]$Extra     = @()
    )
    $dom = if ([string]::IsNullOrWhiteSpace($Domain)) { $Script:AppConfig.Domain } else { $Domain }
    if ([string]::IsNullOrWhiteSpace($dom)) { $dom = "*" }

    $a = [System.Collections.ArrayList]@()
    [void]$a.Add("`"$StorePath`"")
    if ($MigAppXml)  { [void]$a.Add("/i:`"$MigAppXml`"") }
    if ($MigUserXml) { [void]$a.Add("/i:`"$MigUserXml`"") }
    if ($SettingsOnly -and $PublicXml) { [void]$a.Add("/i:`"$PublicXml`"") }
    if ($ConfigXml)  { [void]$a.Add("/config:`"$ConfigXml`"") }
    if ($ExcludeXml -and $Operation -eq "Export") { [void]$a.Add("/i:`"$ExcludeXml`"") }
    [void]$a.Add("/v:$Verbosity")
    if ($Overwrite) { [void]$a.Add("/o") }
    if ($SettingsOnly) {
        # Everything human excluded - this captures machine state only.
        [void]$a.Add("/ue:*\*")
    } elseif ($AllProfiles) {
        [void]$a.Add("/ui:$dom\*"); [void]$a.Add("/ui:%computername%\*")
    } elseif ($Usernames -and @($Usernames).Count -gt 0) {
        # Exclude everyone, then name each wanted account. /ui beats /ue for the
        # same account, which is what makes this pattern work at all.
        [void]$a.Add("/ue:*")
        foreach ($u in $Usernames) {
            $n = "$u".Trim()
            if (-not $n) { continue }
            # A name that already carries a domain is used as given.
            if ($n -match '\\') { [void]$a.Add("/ui:$(Format-UsmtUser $n)") } else { [void]$a.Add("/ui:$(Format-UsmtUser "$dom\$n")") }
        }
    } else {
        # Same guard as the multi-user branch above and the /mu: branch below:
        # a name that already carries a domain is used as given.
        #
        # Without it, "CONTOSO\jbrown" typed into a box labelled "Domain \
        # Username(s)" became /ui:CONTOSO\CONTOSO\jbrown - which matches no account,
        # so USMT captures nothing for that user AND still exits 0. A silent
        # wrong result is the worst failure this tool can produce, and two of
        # the three places that build a qualified name already knew it.
        $n1 = "$Username".Trim()
        [void]$a.Add("/ue:*")
        if ($n1 -match '\\') { [void]$a.Add("/ui:$(Format-UsmtUser $n1)") } else { [void]$a.Add("/ui:$(Format-UsmtUser "$dom\$n1")") }
    }
    if ($Operation -eq "Import" -and $RenameFrom -and $RenameTo) {
        $from = if ($RenameFrom -match '\\') { $RenameFrom } else { "$dom\$RenameFrom" }
        $to   = if ($RenameTo   -match '\\') { $RenameTo }   else { "$dom\$RenameTo" }
        [void]$a.Add("/mu:`"${from}:${to}`"")
    }
    [void]$a.Add("/c")   # keep going through non-fatal errors
    foreach ($x in $Extra) { if ($x -and $x.Trim()) { [void]$a.Add($x.Trim()) } }
    if ($LogFile)     { [void]$a.Add("/l:`"$LogFile`"") }
    if ($ProgressLog) { [void]$a.Add("/progress:`"$ProgressLog`"") }
    return ($a -join " ")
}

function Build-USMTCommand {
    param(
        [string]$USMTPath,
        [string]$Operation,
        [string]$StorePath,
        [string]$Username,
        [bool]$AllProfiles,
        [bool]$ExcludeOneDrive,
        [int]$Verbosity,
        [bool]$Overwrite      = $false,
        [string]$LogFolder    = "",
        [bool]$SettingsOnly   = $false,
        [string]$ComputerName = "",  # machine this operation runs against; log label for all-profiles runs
        [string[]]$Extra      = @(), # expert-mode additions
        [string]$ArgOverride  = "",  # expert mode: use this arg string verbatim
        # DECLARED, BECAUSE UNDECLARED IS SILENT.
        #
        # Callers have passed these three for a long time and this function
        # never had them. A simple PowerShell function does not reject an
        # unmatched named argument - it drops it into $args and carries on - so
        # a two-user capture built a ONE-user command line, ScanState exited 0,
        # and the store and the log both reported success while the second
        # person's profile was never touched. Restore-under-a-different-name was
        # dead the same way. Nothing threw, which is why it lasted.
        [string[]]$Usernames  = @(),
        [string]$RenameFrom   = "",
        [string]$RenameTo     = ""
    )
    $tool     = if ($Operation -eq "Export") { "scanstate.exe" } else { "loadstate.exe" }
    $toolPath = Join-Path $USMTPath $tool
    $effLog   = if ([string]::IsNullOrWhiteSpace($LogFolder)) { $Script:AppConfig.LogFolder } else { $LogFolder }

    # Which optional files are actually present, decided here because this is
    # the local case and these are local paths.
    $pubXml = ""
    if ($SettingsOnly) {
        $p = Ensure-PublicFoldersXml $USMTPath
        if ($p -and (Test-Path $p)) { $pubXml = $p }
    }
    # Config.xml is normally deployed beside the GUI rather than inside the USMT
    # folder, so fall back there - otherwise it is silently never applied.
    $configXml = Join-Path $USMTPath "Config.xml"
    if (-not (Test-Path $configXml) -and $Script:ScriptDir) {
        $alt = Join-Path $Script:ScriptDir "Config.xml"
        if (Test-Path $alt) { $configXml = $alt }
    }
    if (Test-Path $configXml) { Write-Log "Config.xml found and applied: $configXml" } else { $configXml = "" }

    $exXml = ""
    if ($ExcludeOneDrive -and $Operation -eq "Export") {
        $e = Join-Path $USMTPath "ExcludeOneDriveFolders.xml"
        if (Test-Path $e) { $exXml = $e } else { Write-Log "ExcludeOneDriveFolders.xml not found" -Level "WARN" }
    }

    $ts          = Get-Date -Format 'yyyyMMdd_HHmmss'
    $effUser     = Get-LogLabel -AllProfiles $AllProfiles -SettingsOnly $SettingsOnly -Username $Username -ComputerName $ComputerName
    $logFile     = Join-Path $effLog "${Operation}_${effUser}_${ts}.log"
    $progressLog = Join-Path $effLog "${Operation}_progress_${ts}.log"

    $argStr = if ($ArgOverride) { $ArgOverride } else {
        Build-USMTArgs -Operation $Operation -StorePath $StorePath `
            -MigAppXml (Join-Path $USMTPath "migapp.xml") -MigUserXml (Join-Path $USMTPath "miguser.xml") `
            -PublicXml $pubXml -ConfigXml $configXml -ExcludeXml $exXml `
            -Username $Username -AllProfiles $AllProfiles -SettingsOnly $SettingsOnly `
            -Verbosity $Verbosity -Overwrite $Overwrite `
            -LogFile $logFile -ProgressLog $progressLog -Extra $Extra `
            -Usernames $Usernames -RenameFrom $RenameFrom -RenameTo $RenameTo
    }
    # An edited command carries its own /l: and /progress:, and the output pane
    # has to tail the files it will really write, not the ones we planned.
    if ($ArgOverride) {
        $m = [regex]::Match($ArgOverride, '/l:\s*"?([^"]+?)"?(?=\s+/|\s*$)')
        if ($m.Success) { $logFile = $m.Groups[1].Value.Trim() }
        $m = [regex]::Match($ArgOverride, '/progress:\s*"?([^"]+?)"?(?=\s+/|\s*$)')
        if ($m.Success) { $progressLog = $m.Groups[1].Value.Trim() }
    }

    return @{
        ToolPath    = $toolPath
        Arguments   = $argStr
        LogFile     = $logFile
        ProgressLog = $progressLog
        FullCommand = "`"$toolPath`" $argStr"
    }
}

# ---------------------------------------------------------------------------
#  Completion Flag
# ---------------------------------------------------------------------------
function Drop-CompletionFlag {
    param([string]$StorePath, [string]$Username, [string]$SourceComputer, [string]$TargetComputer)
    $flag = @{
        ExportCompleted = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        SourceComputer  = $SourceComputer; TargetComputer = $TargetComputer
        Username = $Username; ExportedBy = $env:USERNAME
    } | ConvertTo-Json -Depth 2
    try { $flag | Out-File -FilePath (Join-Path $StorePath $Script:AppConfig.CompletionFlag) -Encoding UTF8 -Force; return $true }
    catch { return $false }
}


# ---------------------------------------------------------------------------
#  File reader  -  FileShare.ReadWrite so we don't block USMT's open handles
# ---------------------------------------------------------------------------
function Read-SharedFile {
    <#
        Whole-file read, kept for the places that genuinely need every line.
        Anything called on the polling timer should use Read-FileTail or
        Read-FileEndLines instead - see the note on those.
    #>
    param([string]$FilePath)
    try {
        $stream = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = [System.IO.StreamReader]::new($stream)
        $text   = $reader.ReadToEnd()
        $reader.Close(); $stream.Close(); $reader.Dispose(); $stream.Dispose()
        return @($text -split "`n")
    } catch { return @() }
}

# ---------------------------------------------------------------------------
#  Log tailing
#
#  The timer polls once a second while a migration runs, and it used to read
#  every log in full on every tick - then throw away all the lines it had
#  already shown. For a local progress log that is merely wasteful. For a
#  /v:13 detail log on the far end of a UNC it is minutes of SMB traffic per
#  migration, and it is why a finished capture still sat there "working":
#  the completion check could not get a look in between whole-file reads.
#
#  Two replacements, both of which read only the bytes they actually need:
#
#    Read-FileTail      - remembers a byte offset per file and returns only
#                         what has been appended since last time
#    Read-FileEndLines  - seeks to the END and reads back a fixed window, for
#                         the cases that only ever wanted the last N lines
# ---------------------------------------------------------------------------
$Script:TailState = @{}

function Reset-FileTail {
    # Called when an operation starts, so a re-run does not resume at the
    # previous run's offset into a log that has since been recreated.
    param([string]$FilePath = "")
    if ($FilePath) { $Script:TailState.Remove($FilePath.ToLowerInvariant()) }
    else           { $Script:TailState = @{} }
}

function Read-FileTail {
    <#
        Returns @{ Lines; Ok; Restarted; Offset } - only the COMPLETE lines
        appended since the previous call for this path.

        A half-written final line is held back rather than shown: USMT is
        appending as we read, and emitting a partial line would put a torn
        fragment in the output that never gets corrected.

        A file that has SHRUNK was recreated (a new run, same path), so the
        offset resets rather than seeking past the end.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [int]$MaxChunk = 262144
    )
    $key = $FilePath.ToLowerInvariant()
    if (-not $Script:TailState.ContainsKey($key)) {
        $Script:TailState[$key] = @{ Offset = [long]0; Partial = "" }
    }
    $st = $Script:TailState[$key]
    $out = @(); $restarted = $false
    try {
        $fs = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open,
                                          [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -lt $st.Offset) {
                $st.Offset = [long]0; $st.Partial = ""; $restarted = $true
            }
            if ($len -gt $st.Offset) {
                $take = [int][Math]::Min([long]$MaxChunk, ($len - $st.Offset))
                [void]$fs.Seek($st.Offset, [System.IO.SeekOrigin]::Begin)
                $buf  = New-Object byte[] $take
                $read = $fs.Read($buf, 0, $take)
                $st.Offset += $read
                # USMT logs are ASCII, so a chunk boundary cannot land inside a
                # character. Worth knowing if that ever stops being true.
                $text = $st.Partial + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                $nl = $text.LastIndexOf("`n")
                if ($nl -lt 0) {
                    $st.Partial = $text; $text = ""
                } else {
                    $st.Partial = $text.Substring($nl + 1)
                    # TrimEnd because cutting at the last newline leaves the CR
                    # of that CRLF behind. The split below eats the CR of every
                    # OTHER line, so without this the final line of each chunk -
                    # and only that one - came out with a trailing carriage
                    # return riding along into the output pane.
                    $text = $text.Substring(0, $nl).TrimEnd("`r")
                }
                if ($text) { $out = @($text -split "`r?`n") }
            }
        } finally { $fs.Dispose() }
        return @{ Lines = $out; Ok = $true; Restarted = $restarted; Offset = $st.Offset }
    } catch {
        return @{ Lines = @(); Ok = $false; Restarted = $false; Offset = $st.Offset }
    }
}

function Read-FileEndLines {
    <#
        The last $Count lines, read by seeking to the end - never by reading
        the file and slicing it. The markers this tool looks for on completion
        ("USMT error code N", "USMT Completed", "Successful run") are all
        written at the very end of the log, and so are the lines worth showing
        after a failure, so nothing before the window is of any interest.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [int]$Count = 30,
        [int]$MaxBytes = 131072
    )
    try {
        $fs = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open,
                                          [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len  = $fs.Length
            if ($len -le 0) { return @() }
            $take = [int][Math]::Min([long]$MaxBytes, $len)
            [void]$fs.Seek(($len - $take), [System.IO.SeekOrigin]::Begin)
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
        $lines = @($text -split "`r?`n")
        # Starting mid-file almost certainly cut the first line in half.
        if ($take -lt $len -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
        $lines = @($lines | Where-Object { $_.Trim() })
        if ($lines.Count -le $Count) { return $lines }
        return @($lines[($lines.Count - $Count)..($lines.Count - 1)])
    } catch { return @() }
}

# ---------------------------------------------------------------------------
#  Expert mode  -  command preview, editing, and reading edits back
#
#  The preview is generated by the SAME Build-USMTArgs the run uses, so what is
#  shown is what executes. What comes back out of the box is parsed here, and
#  split into two things:
#
#    * flags the GUI models  - these move the checkboxes, so ticking a box and
#                              deleting its flag are the same action
#    * everything else       - carried through untouched as "extra", so adding
#                              /vsc or /encrypt survives the next regeneration
#
#  Nothing here validates USMT syntax. There are far too many options for that
#  to be anything but a source of false rejections, and USMT reports a bad
#  command line clearly (exit 11). The panel says as much.
# ---------------------------------------------------------------------------

# Flags this tool generates itself. Anything matching one of these is REMOVED
# when reading an edited line, because it will be regenerated from GUI state;
# whatever is left over is the operator's own and is preserved.
$Script:UsmtOwnedFlagPatterns = @(
    '^/i:',        '^/config:',  '^/v:\d+$',   '^/o$',
    '^/ue:',       '^/ui:',      '^/c$',       '^/l:',   '^/progress:'
)

function Split-CommandLine {
    <#
        Splits a command line into tokens, keeping quoted runs together.
        USMT paths contain spaces constantly, so a naive split on whitespace
        turns one /i:"C:\Program Files\..." into three broken arguments.
    #>
    param([string]$Line)
    $out = @(); $cur = ""; $inQ = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq '"') { $inQ = -not $inQ; $cur += $ch; continue }
        if (-not $inQ -and ($ch -eq ' ' -or $ch -eq "`t")) {
            if ($cur) { $out += $cur; $cur = "" }
            continue
        }
        $cur += $ch
    }
    if ($cur) { $out += $cur }
    return $out
}

function Read-USMTCommandEdits {
    <#
        Reads one edited command line back into intent.

        Returns @{ Ok; Tool; StorePath; Overwrite; ExcludeOneDrive; Verbosity;
                   LogFile; ProgressLog; Extra; Unknown }

        .Overwrite / .ExcludeOneDrive / .Verbosity are what the checkboxes and
        settings should now say. .Extra is everything this tool does not model,
        ready to be handed back to Build-USMTArgs.
    #>
    param([string]$Line)
    $res = @{ Ok = $false; Tool = ""; StorePath = ""; Overwrite = $false
              ExcludeOneDrive = $false; Verbosity = -1; LogFile = ""; ProgressLog = ""
              Extra = @(); Unknown = @() }
    if ([string]::IsNullOrWhiteSpace($Line)) { return $res }

    $tokens = @(Split-CommandLine $Line.Trim())
    if ($tokens.Count -eq 0) { return $res }

    # The tool is the first token; the store is the first bare (non-slash) one.
    $res.Tool = $tokens[0].Trim('"')
    $rest = @($tokens | Select-Object -Skip 1)
    $extra = @()
    foreach ($t in $rest) {
        $bare = $t.Trim()
        if (-not $bare) { continue }
        if ($bare -notmatch '^/') {
            if (-not $res.StorePath) { $res.StorePath = $bare.Trim('"') }
            else { $extra += $bare }   # a second bare token is not ours to judge
            continue
        }
        if     ($bare -eq '/o')                      { $res.Overwrite = $true; continue }
        elseif ($bare -match '^/v:(\d+)$')           { $res.Verbosity = [int]$Matches[1]; continue }
        elseif ($bare -match '^/l:"?([^"]*)"?$')     { $res.LogFile = $Matches[1]; continue }
        elseif ($bare -match '^/progress:"?([^"]*)"?$') { $res.ProgressLog = $Matches[1]; continue }
        elseif ($bare -match '^/i:') {
            if ($bare -match 'ExcludeOneDriveFolders\.xml') { $res.ExcludeOneDrive = $true }
            continue   # every other /i: is regenerated
        }
        $owned = $false
        foreach ($p in $Script:UsmtOwnedFlagPatterns) { if ($bare -match $p) { $owned = $true; break } }
        if (-not $owned) { $extra += $bare }
    }
    $res.Extra   = @($extra)
    $res.Unknown = @($extra)
    $res.Ok      = [bool]$res.Tool
    return $res
}

function Get-CommandPreview {
    <#
        Every command the current operation will run, in order, as
        @{ Label; Tool; Args; Where; Editable }.

        Export + Import produces two, because it IS two runs on two machines -
        the operator asked to see both, and seeing them side by side is also
        the clearest explanation of what that operation actually does.

        .Where names the machine the command executes ON, which for a remote
        capture is not this workstation and is the single most misread thing
        about the tool.
    #>
    param([hashtable]$Ctx)

    $rows = @()
    $usmt = $Ctx.USMTPath
    $ver  = $Ctx.Verbosity
    $dom  = $Ctx.Domain

    # Paths as the RUNNING machine sees them.
    $remoteUsmt = $Script:RemoteTempLocal
    $localLogs  = if ($Ctx.LogFolder) { $Ctx.LogFolder } else { $Script:AppConfig.LogFolder }
    $remoteLogs = "$($Script:RemoteTempLocal)\Logs"

    function New-Row($label, $tool, $argStr, $where, $editable) {
        return @{ Label = $label; Tool = $tool; Args = $argStr; Where = $where; Editable = $editable }
    }

    switch ($Ctx.Kind) {
        "Extract" {
            $rows += New-Row "Extract" (Join-Path $usmt "usmtutils.exe") `
                     "/extract `"$($Ctx.MigFile)`" `"$($Ctx.ExtractTo)`" /decrypt:none" "this PC" $true
        }
        "Cleanup" {
            # Housekeeping this tool does itself - there is no USMT command to
            # show, so say so rather than inventing one.
            foreach ($pc in $Ctx.CleanupPCs) {
                $rows += New-Row "Remove staged tools" "(UTW)" "Delete $(Get-StagedToolsPath $pc)" $pc $false
                if ($Ctx.CleanStores) {
                    $root = if (Test-IsThisComputer $pc) { "C:\$($Script:AppConfig.DefaultStorePath)" }
                            else { "\\$pc\C`$\$($Script:AppConfig.DefaultStorePath)" }
                    $rows += New-Row "Delete old stores" "(UTW)" "Delete USMT stores under $root" $pc $false
                }
            }
        }
        default {
            $isExport = $Ctx.Kind -eq "Export" -or $Ctx.Kind -eq "Combo"
            $isImport = $Ctx.Kind -eq "Import" -or $Ctx.Kind -eq "Combo"
            # Export + Import to a drive is refused at run time - the disk has to
            # be carried between the machines, so the second leg cannot follow
            # the first. The preview has to agree with that: showing a LoadState
            # command that will never be issued is exactly the kind of lie this
            # panel exists to avoid.
            $driveCombo = ($Ctx.Kind -eq "Combo") -and $Ctx.DriveStore
            if ($driveCombo) { $isImport = $false }

            <#
                EVERYTHING THAT HAPPENS BEFORE SCANSTATE, listed as steps.

                This panel used to show two commands - ScanState and LoadState -
                and nothing else, which was accurate and misleading at the same
                time. A run does a good deal more than that: it checks the tools
                are where they are supposed to be, copies USMT to the remote
                machine, and runs whichever pre-checks are ticked. None of those
                are USMT commands, so none of them appeared, and ticking a
                pre-check changed nothing visible in the panel that exists to
                show what the run will do.

                They are marked "(UTW)" and are not editable, the same way the
                Clean Up steps already were: they are things this tool does
                itself, not a command line anybody can alter. Saying so is much
                better than leaving them out.
            #>
            $srcName = if ($Ctx.SourcePC) { $Ctx.SourcePC } else { "this PC" }
            $dstName = if ($Ctx.DestPC)   { $Ctx.DestPC }   else { "this PC" }

            $rows += New-Row "Check the USMT tools" "(UTW)" `
                     "Confirm scanstate.exe and loadstate.exe are in $usmt" "this PC" $false

            foreach ($pc in @($(if ($isExport) { $Ctx.SourcePC }), $(if ($isImport) { $Ctx.DestPC })) |
                            Where-Object { $_ } | Select-Object -Unique) {
                $rows += New-Row "Reach $pc" "(UTW)" `
                         "Confirm $pc answers, and that \\$pc\C`$ can be opened as an administrator" "this PC" $false
                # The step people forget is here, and it is the slow one: USMT
                # does not exist on the far machine until this copies it there.
                $rows += New-Row "Stage USMT on $pc" "(UTW)" `
                         "Copy $usmt to $($Script:RemoteTempLocal) on $pc" "this PC" $false
            }

            if ($Ctx.VerifyProfile -and $isExport) {
                $who = if ($Ctx.AllProfiles) { "every profile to be captured" }
                       elseif ($Ctx.Username) { "'$($Ctx.Username)'" } else { "the named profile" }
                $rows += New-Row "Pre-check: profile exists" "(UTW)" `
                         "Look for $who in the profile list on $srcName" $srcName $false
            }
            if ($Ctx.EstimateSize -and $isExport) {
                # This one IS a real command - a scanstate dry run - so it is
                # shown as one rather than described.
                $xmlDir0 = if ($Ctx.SourcePC) { $remoteUsmt } else { $usmt }
                $logDir0 = if ($Ctx.SourcePC) { $remoteLogs } else { $localLogs }
                $rows += New-Row "Pre-check: estimate the size" "$xmlDir0\scanstate.exe" `
                         "`"$($Ctx.ExportStore)`" /nocompress /p:`"$logDir0\SizeEstimate.xml`" /i:`"$xmlDir0\migapp.xml`" /i:`"$xmlDir0\miguser.xml`"" `
                         $srcName $false
            }
            if ($Ctx.CheckDisk) {
                $where = if ($isExport) { $Ctx.ExportStore } else { $Ctx.ImportStore }
                $rows += New-Row "Pre-check: free space" "(UTW)" `
                         "Measure free space where the store lands ($where) and warn under $($Script:PreflightMinFreeGB) GB" "this PC" $false
            }
            if ($Ctx.CheckInactive -and $isExport) {
                $rows += New-Row "Pre-check: idle profiles" "(UTW)" `
                         "List profiles on $srcName whose registry hive has not been written in $($Script:PreflightInactiveDays)+ days" $srcName $false
            }
            if ($Ctx.ODDetect -and $isExport) {
                $rows += New-Row "Pre-check: OneDrive" "(UTW)" `
                         "Look for a OneDrive folder in the profile and warn if it is still syncing" $srcName $false
            }

            if ($isExport) {
                $onPC  = if ($Ctx.SourcePC) { $Ctx.SourcePC } else { "this PC" }
                $rem   = [bool]$Ctx.SourcePC
                $xmlDir = if ($rem) { $remoteUsmt } else { $usmt }
                $logDir = if ($rem) { $remoteLogs } else { $localLogs }
                $a = Build-USMTArgs -Operation "Export" -StorePath $Ctx.ExportStore `
                        -MigAppXml "$xmlDir\migapp.xml" -MigUserXml "$xmlDir\miguser.xml" `
                        -PublicXml $(if ($Ctx.SettingsOnly) { "$xmlDir\MigratePublicFolders.xml" } else { "" }) `
                        -ConfigXml "$xmlDir\Config.xml" `
                        -ExcludeXml $(if ($Ctx.ExcludeOneDrive) { "$xmlDir\ExcludeOneDriveFolders.xml" } else { "" }) `
                        -Username $Ctx.Username -AllProfiles $Ctx.AllProfiles -SettingsOnly $Ctx.SettingsOnly `
                        -Verbosity $ver -Overwrite $Ctx.Overwrite -Domain $dom `
                        -LogFile "$logDir\Export_$($Ctx.LogLabel).log" `
                        -ProgressLog "$logDir\Export_progress.log" -Extra $Ctx.ExtraExport `
                        -Usernames @($Ctx.Usernames)
                $rows += New-Row "ScanState (capture)" "$xmlDir\scanstate.exe" $a $onPC $true
            }
            if ($isImport) {
                $onPC = if ($Ctx.DestPC) { $Ctx.DestPC } else { "this PC" }
                $rem  = [bool]$Ctx.DestPC
                $xmlDir = if ($rem) { $remoteUsmt } else { $usmt }
                $logDir = if ($rem) { $remoteLogs } else { $localLogs }
                $a = Build-USMTArgs -Operation "Import" -StorePath $Ctx.ImportStore `
                        -MigAppXml "$xmlDir\migapp.xml" -MigUserXml "$xmlDir\miguser.xml" `
                        -PublicXml $(if ($Ctx.SettingsOnly) { "$xmlDir\MigratePublicFolders.xml" } else { "" }) `
                        -ConfigXml "$xmlDir\Config.xml" `
                        -Username $Ctx.Username -AllProfiles $Ctx.AllProfiles -SettingsOnly $Ctx.SettingsOnly `
                        -Verbosity $ver -Overwrite $false -Domain $dom `
                        -LogFile "$logDir\Import_$($Ctx.LogLabel).log" `
                        -ProgressLog "$logDir\Import_progress.log" -Extra $Ctx.ExtraImport `
                        -Usernames @($Ctx.Usernames) -RenameFrom "$($Ctx.RenameFrom)" -RenameTo "$($Ctx.RenameTo)"
                $rows += New-Row "LoadState (restore)" "$xmlDir\loadstate.exe" $a $onPC $true
            }
            if ($driveCombo) {
                $rows += New-Row "LoadState (restore)" "(not run here)" `
                         "Move the drive to the new PC, then run Import there and browse to the store." `
                         "the new PC, later" $false
            }

            # AND WHAT HAPPENS AFTERWARDS. Delete source is the one that matters:
            # it is the only option in the panel that destroys anything, and it
            # ran without ever appearing in the list of what the run would do.
            if ($Ctx.RenameOn -and $isImport) {
                # The checkbox is "Restore under a different account" - USMT's
                # /mu:, visible on the LoadState line above. It has nothing to do
                # with renaming the machine, which is what this row used to say.
                $who = if ($Ctx.RenameTo) { "'$($Ctx.RenameFrom)' will be restored as '$($Ctx.RenameTo)'" }
                       else { "no new account name has been typed, so nothing will be renamed" }
                $rows += New-Row "Restore under a different account" "(UTW)" $who $dstName $false
            }
            if ($Ctx.DeleteSource -and $isExport) {
                $rows += New-Row "After capture: DELETE the source profile" "(UTW)" `
                         "Remove the captured profile from $srcName - only after the store is proved readable, and only if you confirm" `
                         $srcName $false
            }
        }
    }
    return $rows
}

# ---------------------------------------------------------------------------
#  USMT return codes
#
#  Held locally rather than fetched. A migration tool runs on machines that are
#  half-configured, sometimes off the network, sometimes behind a proxy that
#  eats requests - the one moment you need the explanation is the moment the
#  environment is least likely to give it to you. So the table ships with the
#  tool and the LINK to Microsoft's page is offered alongside it, which is the
#  part that stays current.
#
#  Wording follows the tooltip rule: what happened, then what to do about it,
#  in as few words as carry the meaning. Microsoft's own text is a list of
#  every message that can produce the code; that belongs on their page, not in
#  a status line.
# ---------------------------------------------------------------------------
$Script:USMTDocsUrl = "https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes"
# Microsoft's reference for the switches the Expert panel lets you add.
$Script:ScanStateDocsUrl = "https://learn.microsoft.com/windows/deployment/usmt/usmt-scanstate-syntax"
$Script:LoadStateDocsUrl = "https://learn.microsoft.com/windows/deployment/usmt/usmt-loadstate-syntax"

# Failures that are UTW's own - staging, shares, scheduled tasks, the store
# lock - are not in Microsoft's table and never will be. Sending someone to a
# USMT return-code page for "could not create the share on the new PC" wastes
# their time, so those get pointed at this tool's own notes instead.
$Script:UTWDocsPath = "UTW-README.md"

function Get-UTWDocsRef {
    <#
        Where to send someone for a UTW-level failure. Prefers the README that
        ships beside the script; falls back to naming it, so the message still
        says something useful when the file has not been deployed.
    #>
    $p = if ($Script:ScriptDir) { Join-Path $Script:ScriptDir $Script:UTWDocsPath } else { "" }
    if ($p -and (Test-Path $p)) { return $p }
    return "$($Script:UTWDocsPath) (beside UTW-Main.ps1)"
}

function Format-UTWErrorLines {
    <#
        The UTW equivalent of Format-USMTExitLines: a failure this tool owns,
        with what to try and where to read more. Same @{Text;Kind} rows.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [string]$Try = "",
        [string]$Detail = ""
    )
    $rows = @()
    $rows += @{ Text = "UTW: $What"; Kind = "error" }
    if ($Detail) { $rows += @{ Text = "   $Detail"; Kind = "dim" } }
    if ($Try)    { $rows += @{ Text = "   Try: $Try"; Kind = "warn" } }
    $rows += @{ Text = "   This is a UTW step, not a USMT one - see $(Get-UTWDocsRef)"; Kind = "dim" }
    return $rows
}

$Script:USMTErrors = @{
    0  = @{ Name = "USMT_SUCCESS";                          Cat = "Success"
            What = "Completed with no errors."
            Do   = "" }
    1  = @{ Name = "USMT_DISPLAY_HELP";                     Cat = "Success or cancel"
            What = "USMT printed its command-line help instead of running."
            Do   = "The command line was malformed - the log shows what was passed." }
    2  = @{ Name = "USMT_STATUS_CANCELED";                  Cat = "Success or cancel"
            What = "Cancelled before it finished."
            Do   = "If you did not cancel it, an EFS-encrypted file stopped the gather." }
    3  = @{ Name = "USMT_WOULD_HAVE_FAILED";                Cat = "Completed with errors"
            What = "Finished, but at least one error was skipped because /c was set."
            Do   = "Read the log - something did fail and was ignored." }
    11 = @{ Name = "USMT_INVALID_PARAMETERS";               Cat = "Bad command line"
            What = "Options conflict, or an argument is missing or malformed."
            Do   = "The log names the offending option. If the store path is a share, check it is reachable." }
    12 = @{ Name = "USMT_ERROR_OPTION_PARAM_TOO_LARGE";     Cat = "Bad command line"
            What = "An argument or the store path is longer than 256 characters."
            Do   = "Use a shorter store path." }
    13 = @{ Name = "USMT_INIT_LOGFILE_FAILED";              Cat = "Bad command line"
            What = "The log path is not valid."
            Do   = "Check the log folder exists and can be written to." }
    14 = @{ Name = "USMT_ERROR_USE_LAC";                    Cat = "Bad command line"
            What = "Tried to create a local account without the option that permits it."
            Do   = "Needs /lac (and /lae) on the LoadState command." }
    26 = @{ Name = "USMT_INIT_ERROR";                       Cat = "Start-up"
            What = "Start-up failed: a bad XML file, more than one Windows installation, or an unknown fault."
            Do   = "Usually a migration XML. Config.xml must be passed with /config, not /i - loading it with /i causes exactly this." }
    27 = @{ Name = "USMT_INVALID_STORE_LOCATION";           Cat = "Start-up"
            What = "The store path cannot be used - it already exists, is unreachable, is read-only, or was written by a different USMT version."
            Do   = "Tick 'Overwrite existing store (/o)', or pick a different folder. Check permissions on the destination." }
    28 = @{ Name = "USMT_UNABLE_GET_SCRIPTFILES";           Cat = "Start-up"
            What = "A migration XML named on the command line is missing or invalid."
            Do   = "Check migapp.xml / miguser.xml are in the USMT folder and are valid XML." }
    29 = @{ Name = "USMT_FAILED_MIGSTARTUP";                Cat = "Start-up"
            What = "Could not start: an XML error, another migration already running, or under 250 MB free for temporary files."
            Do   = "Only one USMT can run on a machine at a time. Otherwise free up space on that machine's system drive." }
    31 = @{ Name = "USMT_UNABLE_FINDMIGUNITS";              Cat = "Start-up"
            What = "Failed while working out what to migrate."
            Do   = "Check the migration XML files." }
    32 = @{ Name = "USMT_FAILED_SETMIGRATIONTYPE";          Cat = "Start-up"
            What = "Error processing the migration rules."
            Do   = "Check the migration XML files." }
    33 = @{ Name = "USMT_UNABLE_READKEY";                   Cat = "Start-up"
            What = "The encryption key could not be read."
            Do   = "Check the key or key file given." }
    34 = @{ Name = "USMT_ERROR_INSUFFICIENT_RIGHTS";        Cat = "Start-up"
            What = "Not enough rights to read, create or delete user profiles."
            Do   = "USMT must run elevated ON THE MACHINE BEING MIGRATED - not just on your workstation." }
    35 = @{ Name = "USMT_UNABLE_DELETE_STORE";              Cat = "Start-up"
            What = "The existing store could not be removed - a file in it is locked, or a reboot is pending."
            Do   = "Delete the store folder by hand, or use UsmtUtils.exe /rd." }
    36 = @{ Name = "USMT_ERROR_UNSUPPORTED_PLATFORM";       Cat = "Start-up"
            What = "Wrong platform or phase for this command."
            Do   = "Check whether a temporary profile is active on that machine." }
    37 = @{ Name = "USMT_ERROR_NO_INVALID_KEY";             Cat = "Start-up"
            What = "The store is encrypted and the key supplied was wrong or missing."
            Do   = "Supply the key the store was captured with." }
    38 = @{ Name = "USMT_ERROR_CORRUPTED_NOTENCRYPTED_STORE"; Cat = "Start-up"
            What = "The store could not be read."
            Do   = "Check the store path is reachable and the permissions are right." }
    39 = @{ Name = "USMT_UNABLE_TO_READ_CONFIG_FILE";       Cat = "Start-up"
            What = "Config.xml could not be read."
            Do   = "Check the Config.xml beside the USMT tools is present and valid XML." }
    40 = @{ Name = "USMT_ERROR_UNABLE_CREATE_PROGRESS_LOG"; Cat = "Start-up"
            What = "The progress log could not be written."
            Do   = "Check the log folder exists and can be written to." }
    41 = @{ Name = "USMT_PREFLIGHT_FILE_CREATION_FAILED";   Cat = "Start-up"
            What = "A file USMT needed to create already exists or could not be written."
            Do   = "Check the destination for leftovers and for write access." }
    42 = @{ Name = "USMT_ERROR_CORRUPTED_STORE";            Cat = "Store damaged"
            What = "The store contains one or more corrupted files."
            Do   = "Use UsmtUtils to extract whatever is still readable - the rest of the profile is not recoverable from this store." }
    61 = @{ Name = "USMT_MIGRATION_STOPPED_NONFATAL";       Cat = "Non-fatal"
            What = "Stopped by an I/O error. Not fatal in itself."
            Do   = "Something could not be read or written - the log names it. The run can continue if that file is excluded." }
    71 = @{ Name = "USMT_INIT_OPERATING_ENVIRONMENT_FAILED"; Cat = "Fatal"
            What = "Could not initialise. Almost always because it is not running elevated."
            Do   = "USMT must run elevated on the machine being migrated." }
    72 = @{ Name = "USMT_UNABLE_DOMIGRATION";               Cat = "Fatal"
            What = "Failed part-way through the gather or apply, or ran out of disk space."
            Do   = "Most often V2V arbitration - make sure Config.xml is in the USMT folder so it gets staged. Otherwise check free space at the destination." }
}

function Get-USMTErrorInfo {
    <#
        Returns @{ Code; Name; Cat; What; Do; Url; Known }. An unrecognised code
        still comes back with the link rather than nothing at all.
    #>
    param([int]$Code)
    $e = $Script:USMTErrors[$Code]
    if ($e) {
        return @{ Code = $Code; Name = $e.Name; Cat = $e.Cat; What = $e.What
                  Do = $e.Do; Url = $Script:USMTDocsUrl; Known = $true }
    }
    return @{ Code = $Code; Name = ""; Cat = ""; Known = $false
              What = "USMT returned $Code. This one is not in the built-in list."
              Do   = "Look it up on Microsoft's return-code page."
              Url  = $Script:USMTDocsUrl }
}

function Format-USMTExitLines {
    <#
        The exit code as it should appear in the output pane: a headline, what
        to do, and the reference link. Returned as @{ Text; Kind } rows so the
        caller can colour them - this file knows nothing about themes.
    #>
    param([int]$Code)
    $i = Get-USMTErrorInfo $Code
    $rows = @()
    if ($Code -eq 0) {
        $rows += @{ Text = "Exit 0 - completed with no errors"; Kind = "ok" }
        return $rows
    }
    $head = if ($i.Known) { "Exit $Code - $($i.What)" } else { "Exit $Code - not a documented USMT code" }
    $rows += @{ Text = $head; Kind = "error" }
    if ($i.Name) { $rows += @{ Text = "   $($i.Name)  ($($i.Cat))"; Kind = "dim" } }
    if ($i.Do)   { $rows += @{ Text = "   Try: $($i.Do)"; Kind = "warn" } }
    $rows += @{ Text = "   Microsoft's USMT return codes: $($i.Url)"; Kind = "dim" }
    return $rows
}

# ---------------------------------------------------------------------------
#  Settings Cache
# ---------------------------------------------------------------------------
function Get-FactoryCachePath { return Join-Path $Script:ScriptDir "UTW_Settings.json" }
function Get-LegacyCachePath { return Join-Path $Script:ScriptDir "MigrationTool_Settings.json" }

function Get-SettingsUserName {
    <#
        The current user, reduced to something safe to put in a file name.

        Anything that could change the shape of the path is stripped rather than
        escaped - this name is joined onto a directory, and a user called
        "..\..\etc" is not a problem worth being clever about.
    #>
    $n = "$env:USERNAME".Trim()
    if (-not $n) { $n = "user" }
    $n = ($n -replace '[^A-Za-z0-9._-]', '_')
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
    return $n
}

function Get-UserCachePath {
    return Join-Path $Script:ScriptDir ("UTW_Settings_{0}.json" -f (Get-SettingsUserName))
}

# NO AUTOMATIC BACKUPS. Anything that replaces a user's settings ASKS first.
#
# This used to drop a _previous.json beside every settings file it overwrote,
# which meant the deployment folder filled with files nobody asked for and the
# messages had to explain a concept - "your old settings are kept as..." - that
# the operator never wanted to think about. Offering to save first is the same
# safety with none of the litter: the user decides whether their current setup
# is worth keeping and what to call it, and if it is not, nothing is written.



function Get-CachePath {
    <#
        WHICH settings file this session reads and writes: the user's own, made
        for them the first time they run the tool.

        EVERYONE GETS THEIR OWN. The tool is deployed to a share, so a single
        settings file beside the script is one file for the whole site - the last
        person to close their window decides what the next person opens. Personal
        is therefore the default rather than something to opt into, and the
        factory file becomes what it should always have been: the defaults a
        personal file starts from, and what "reset" resets to.

        Falls back to the factory file if a personal one cannot be created -
        a read-only deployment folder is a real possibility, and a tool that
        cannot remember anything beats a tool that will not start.

        Both load and save go through here, so a session cannot read one file and
        write another.
    #>
    $mine = Get-UserCachePath
    if (Test-Path $mine) { return $mine }
    if (New-UserSettingsFile) { return $mine }
    return Get-FactoryCachePath
}

function New-FactorySettingsFile {
    <#
        Writes UTW_Settings.json if it is not there.

        The factory file is what every personal file is seeded from and what
        Reset resets to, so its absence is not a small problem: a new user gets
        whatever the code happens to default to, and Reset has nothing to reset
        to at all. Recreating it means a deployment can ship without one, or
        survive somebody deleting it, and still behave the same for the next
        person who runs the tool.

        Only the settings worth stating are written. Anything left out falls
        back to the code's own defaults, so this file stays short enough to read
        and edit by hand - which is how a site is expected to set its defaults.
    #>
    $f = Get-FactoryCachePath
    if (Test-Path $f) { return $f }
    $defaults = [ordered]@{
        # Nothing machine- or person-specific: a fresh window starts empty.
        USMTPath        = ""
        Domain          = ""
        CentralPath     = ""
        LastUsername    = ""
        LastNewPC       = ""
        LastSourcePC    = ""
        LastMigFile     = ""
        LastExtractPath = ""
        # Export + Import, straight to the new PC.
        ActionIndex     = 2
        ScopeIndex      = 0
        StoreMode       = "Direct"
        # Plain and quiet: simple mode, the Dark theme, no backdrop, no motion.
        UiMode          = "Simple"
        Theme           = "Dark"
        Overlay         = $false
        OverlayAnimate  = $false
    }
    try {
        $defaults | ConvertTo-Json -Depth 2 | Out-File -FilePath $f -Encoding UTF8 -Force -ErrorAction Stop
        Write-CrashLog "Settings: created $(Split-Path $f -Leaf) with the factory defaults"
        return $f
    } catch {
        Write-CrashLog "Settings: could not create $(Split-Path $f -Leaf): $($_.Exception.Message)"
        return $null
    }
}

function New-UserSettingsFile {
    <#
        Creates this user's settings file, seeded from the factory one, and
        returns its path - or $null if it could not be written.

        Seeded rather than empty so a new user starts with the site's defaults
        instead of a blank tool.
    #>
    $mine = Get-UserCachePath
    if (Test-Path $mine) { return $mine }
    # Recreated if somebody deleted it, so a personal file is always seeded from
    # the site's defaults rather than from nothing.
    $from = New-FactorySettingsFile
    if (-not $from) { $from = Get-FactoryCachePath }
    try {
        if (Test-Path $from) { Copy-Item -Path $from -Destination $mine -Force -ErrorAction Stop }
        else { '{}' | Set-Content -Path $mine -Encoding UTF8 -ErrorAction Stop }
        Write-CrashLog "Settings: created $(Split-Path $mine -Leaf)"
        return $mine
    } catch {
        Write-CrashLog "Settings: could not create $(Split-Path $mine -Leaf): $($_.Exception.Message)"
        return $null
    }
}

function Test-PersonalSettingsActive { return ((Get-CachePath) -eq (Get-UserCachePath)) }

function Reset-ToFactorySettings {
    <#
        Puts the factory settings back over this user's own - "give me the
        defaults again".

        It does not switch which file is used: the user keeps their own file, it
        just holds the site's settings once more. Switching files would leave
        them writing to the shared one and changing it for everybody, which is
        the thing this whole feature exists to stop.
    #>
    $mine = Get-CachePath
    # Recreated if missing - "reset to factory" should never fail because the
    # factory file was deleted; the defaults are known.
    $fact = New-FactorySettingsFile
    if (-not $fact -or -not (Test-Path $fact)) { return "Could not create the factory settings file (UTW_Settings.json)." }
    try {
        Copy-Item -Path $fact -Destination $mine -Force -ErrorAction Stop
        Write-CrashLog "Settings: reset $(Split-Path $mine -Leaf) to the factory defaults"
        return $null
    } catch { return "Could not reset: $($_.Exception.Message)" }
}

function Save-SettingsCopy {
    # Writes the settings this session is using to somewhere else - a colleague,
    # a backup, a share. A copy: the tool carries on using its own file.
    param([string]$Path)
    if (-not $Path) { return "No file was chosen." }
    try {
        $src = Get-CachePath
        if (-not (Test-Path $src)) { return "There are no settings saved yet." }
        Copy-Item -Path $src -Destination $Path -Force -ErrorAction Stop
        Write-CrashLog "Settings: saved a copy to $(Split-Path $Path -Leaf)"
        return $null
    } catch { return "Could not write $(Split-Path $Path -Leaf): $($_.Exception.Message)" }
}

function Import-SettingsFile {
    <#
        Copies a settings file the user picked over the one this session uses.

        Validated before it is copied - a file that is not settings would
        otherwise be discovered at the next start, with the window half built.
        The caller asks the user about their current settings first; nothing is
        backed up here.
    #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return "That file does not exist." }
    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        $j = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return "That file is not valid JSON." }
    # A settings file has at least one key this tool recognises. Anything else is
    # somebody's shopping list and importing it would silently wipe their setup.
    $known = @("Domain","USMTPath","LogFolder","Theme","Overlay","OverlayAnimate","XamlArt",
               "SourcePC","NewPC","StoreRoot","ScopeIndex","ActionIndex","PanelLayout")
    $hit = @($known | Where-Object { $null -ne $j.$_ })
    if ($hit.Count -eq 0) { return "That JSON has none of this tool's settings in it." }
    $dest = Get-CachePath
    try {
        Copy-Item -Path $Path -Destination $dest -Force -ErrorAction Stop
        Write-CrashLog "Settings: imported $(Split-Path $Path -Leaf) over $(Split-Path $dest -Leaf)"
        return $null
    } catch { return "Could not write $(Split-Path $dest -Leaf): $($_.Exception.Message)" }
}

function Load-SettingsCache {
    $cachePath = Get-CachePath
    if (-not (Test-Path $cachePath)) {
        # One-time carry-over from the pre-UTW file name. Copied, not moved, so
        # an older copy of the tool pointed at the same folder keeps working and
        # nobody loses their USMT path, domain or last-used machine names.
        $legacy = Get-LegacyCachePath
        if (Test-Path $legacy) {
            try {
                Copy-Item -Path $legacy -Destination $cachePath -Force -ErrorAction Stop
                Write-CrashLog "Settings carried over from $(Split-Path $legacy -Leaf)"
            } catch {
                Write-CrashLog "Legacy settings carry-over failed, reading in place: $($_.Exception.Message)"
                $cachePath = $legacy
            }
        }
    }
    if (-not (Test-Path $cachePath)) { return $null }
    try {
        $json = Get-Content $cachePath -Raw | ConvertFrom-Json
        if ($json.Domain)           { $Script:AppConfig.Domain           = $json.Domain }
        if ($json.DefaultStorePath) { $Script:AppConfig.DefaultStorePath = $json.DefaultStorePath }
        if ($null -ne $json.Verbosity -and $json.Verbosity -gt 0) { $Script:AppConfig.Verbosity = [int]$json.Verbosity }
        if ($json.CompletionFlag)   { $Script:AppConfig.CompletionFlag   = $json.CompletionFlag }
        # Site-specific: whichever group marks a user as being on OneDrive.
        if ($json.OneDriveGroup)    { $Script:OneDriveGroupName          = $json.OneDriveGroup }
        return @{
            USMTPath        = if ($json.USMTPath)        { $json.USMTPath }        else { "" }
            Theme           = if ($json.Theme)           { $json.Theme }           else { "Dark" }
            UiMode          = if ($json.UiMode)          { $json.UiMode }          else { "Simple" }
            ODDetect        = if ($null -ne $json.ODDetect) { [bool]$json.ODDetect } else { $null }
            ODPattern       = if ($json.ODPattern)       { $json.ODPattern }       else { "" }
            ODMinMB         = if ($null -ne $json.ODMinMB)  { "$($json.ODMinMB)" }  else { "" }
            ArchIndex       = if ($null -ne $json.ArchIndex) { [int]$json.ArchIndex }  else { $null }
            LogOnExit       = if ($null -ne $json.LogOnExit) { [bool]$json.LogOnExit } else { $null }
            Operation       = if ($null -ne $json.OperationIndex) { [int]$json.OperationIndex } else { -1 }
            ScopeIndex      = if ($null -ne $json.ScopeIndex)      { [int]$json.ScopeIndex }      else { $null }
            ActionIndex     = if ($null -ne $json.ActionIndex)     { [int]$json.ActionIndex }     else { $null }
            ExcludeOneDrive = if ($null -ne $json.ExcludeOneDrive) { [bool]$json.ExcludeOneDrive } else { $null }
            VerifyProfile   = if ($null -ne $json.VerifyProfile)   { [bool]$json.VerifyProfile }   else { $null }
            CheckDisk       = if ($null -ne $json.CheckDisk)       { [bool]$json.CheckDisk }       else { $null }
            CheckInactive   = if ($null -ne $json.CheckInactive)   { [bool]$json.CheckInactive }   else { $null }
            DestType        = if ($json.DestType)        { $json.DestType }        else { "Network" }
            # StoreMode supersedes DestType. Settings written before the direct/
            # central split only carry DestType, so map the old value forward.
            StoreMode       = if ($json.StoreMode) { $json.StoreMode }
                              elseif ($json.DestType -eq "USB") { "USB" }
                              else { "Direct" }
            CentralPath     = if ($json.CentralPath)     { $json.CentralPath }     else { "" }
            EstimateSize    = if ($null -ne $json.EstimateSize) { [bool]$json.EstimateSize } else { $null }
            LastUsername    = if ($json.LastUsername)    { $json.LastUsername }    else { "" }
            LastNewPC       = if ($json.LastNewPC)       { $json.LastNewPC }       else { "" }
            LastOldPC       = if ($json.LastOldPC)       { $json.LastOldPC }       else { "" }
            LastSourcePC    = if ($json.LastSourcePC)    { $json.LastSourcePC }    else { "" }
            USBPath         = if ($json.USBPath)         { $json.USBPath }         else { "D:\" }
            LastMigFile     = if ($json.LastMigFile)     { $json.LastMigFile }     else { "" }
            LastExtractPath = if ($json.LastExtractPath) { $json.LastExtractPath } else { "" }
            # Where the two dividers were left, in real (scaled) pixels, and
            # whether the lookup panel was put away. Null means "never set" -
            # the layout then opens at its shipped proportions.
            SplitLeft       = if ($null -ne $json.SplitLeft)    { [int]$json.SplitLeft }     else { $null }
            SplitRight      = if ($null -ne $json.SplitRight)   { [int]$json.SplitRight }    else { $null }
            BrowseHidden    = if ($null -ne $json.BrowseHidden) { [bool]$json.BrowseHidden } else { $null }
            # Whether the themed backdrop is on. Null means never chosen, which
            # leaves it off - the feature costs nothing until it is asked for.
            Overlay         = if ($null -ne $json.Overlay)        { [bool]$json.Overlay }        else { $null }
            OverlayAnimate  = if ($null -ne $json.OverlayAnimate) { [bool]$json.OverlayAnimate } else { $null }
        XamlArt         = if ($null -ne $json.XamlArt)        { [bool]$json.XamlArt }        else { $null }
        }
    } catch {
        Write-CrashLog "Failed to load settings cache: $($_.Exception.Message)"; return $null
    }
}

function Save-SettingsCache {
    # Defaulted, so a caller with nothing new to add can still flush what is
    # already known - "save now" is a reasonable thing to ask for. Without this
    # a no-argument call landed on $null.ContainsKey(), threw, was swallowed by
    # the catch below and wrote NOTHING, which looked exactly like settings
    # quietly not saving.
    param([hashtable]$Settings = @{})
    $cachePath = Get-CachePath
    try {
        # MERGE over whatever is already on disk rather than replacing it.
        #
        # Every caller passes the subset of settings it happens to know about -
        # picking a USMT folder saves fifteen keys, closing the window saves
        # thirty - so a plain overwrite meant the smaller callers silently
        # dropped everything the bigger one had written. Reading the file first
        # and writing the union makes adding a setting a one-place change
        # instead of a hunt through every Save-SettingsCache call site.
        if (Test-Path $cachePath) {
            try {
                $old = Get-Content $cachePath -Raw | ConvertFrom-Json
                foreach ($p in $old.PSObject.Properties) {
                    if (-not $Settings.ContainsKey($p.Name)) { $Settings[$p.Name] = $p.Value }
                }
            } catch { Write-CrashLog "Could not merge the existing settings, writing fresh: $($_.Exception.Message)" }
        }
        $Settings["Domain"]           = $Script:AppConfig.Domain
        $Settings["DefaultStorePath"] = $Script:AppConfig.DefaultStorePath
        $Settings["Verbosity"]        = $Script:AppConfig.Verbosity
        $Settings["CompletionFlag"]   = $Script:AppConfig.CompletionFlag
        $Settings["OneDriveGroup"]    = $Script:OneDriveGroupName
        $Settings | ConvertTo-Json -Depth 2 | Out-File -FilePath $cachePath -Encoding UTF8 -Force
        Write-CrashLog "Settings cache saved"
    } catch { Write-CrashLog "Failed to save settings cache: $($_.Exception.Message)" }
}

# ===========================================================================
#  REMOTE EXPORT  -  Scheduled Task method (schtasks over DCOM/RPC, no WinRM)
# ===========================================================================

# ---------------------------------------------------------------------------
#  Store locks  -  one migration per destination, across windows
#
#  A second window is a second PROCESS, so nothing in the UI can stop it aiming
#  at the same store as the first. Two ScanState runs writing one store folder
#  do not fail cleanly; they interleave and produce a .MIG that restores badly.
#
#  The lock is a file in the technician's own TEMP named after a hash of the
#  destination, holding the owning PID. It deliberately FAILS OPEN: if the lock
#  cannot be written or read, the migration proceeds. A locking scheme that can
#  block legitimate work is worse than the collision it prevents.
# ---------------------------------------------------------------------------
$Script:StoreLockDir = Join-Path $env:TEMP "UTW_Locks"

# ---------------------------------------------------------------------------
#  Instance registry  -  which window am I?
#
#  Each window drops a marker naming its PID and claims the lowest free number.
#  Markers whose process has exited are swept on the way past, so numbers are
#  reused: close window 2 of 3 and the next one opened becomes 2 again, rather
#  than climbing forever. Nothing depends on the number being unique over time,
#  only on it being unique RIGHT NOW, which is all a person needs to tell two
#  taskbar buttons apart.
# ---------------------------------------------------------------------------
$Script:InstanceDir = Join-Path $env:TEMP "UTW_Instances"

function Register-Instance {
    <#
        Returns the number this window should call itself, and the marker file
        to delete on the way out. Falls back to 1 if the registry cannot be
        written - a number is a convenience, never a reason not to start.
    #>
    try {
        if (-not (Test-Path $Script:InstanceDir)) {
            New-Item -Path $Script:InstanceDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $taken = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath $Script:InstanceDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            $rec = $null
            try { $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { }
            $live = $false
            # A PID ALONE IS NOT PROOF the owner is still running.
            #
            # Windows reuses process ids. A window that was killed leaves its
            # marker behind, and once something unrelated is given that id the
            # marker looks alive for good - so a later window skips the number
            # and calls itself #2 with nothing else open. Recording WHEN the
            # owner started settles it: the same id belonging to a process that
            # started at a different moment is a different process.
            if ($rec -and $rec.OwnerPid) {
                $proc = Get-Process -Id ([int]$rec.OwnerPid) -ErrorAction SilentlyContinue
                if ($proc) {
                    if ($rec.OwnerStart) {
                        try { $live = ($proc.StartTime.ToString("o") -eq [string]$rec.OwnerStart) } catch { $live = $true }
                    } else {
                        # Written by a build with no start time in it. Trust the
                        # id, but only for a PowerShell host - the only thing
                        # this tool ever runs as.
                        $live = ($proc.ProcessName -like "*powershell*" -or $proc.ProcessName -like "*pwsh*")
                    }
                }
            }
            if ($live -and [int]$rec.OwnerPid -ne $PID) { $taken[[int]$rec.Number] = $true }
            else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
        $n = 1
        while ($taken.ContainsKey($n)) { $n++ }
        $file = Join-Path $Script:InstanceDir "$PID.json"
        @{ OwnerPid   = $PID
           Number     = $n
           Started    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
           # The identity half of the check above - see the note there.
           OwnerStart = $(try { (Get-Process -Id $PID).StartTime.ToString("o") } catch { "" }) } |
            ConvertTo-Json | Out-File -FilePath $file -Encoding UTF8 -Force
        return @{ Number = $n; File = $file }
    } catch {
        Write-CrashLog "Instance registry unavailable: $($_.Exception.Message)"
        return @{ Number = 1; File = "" }
    }
}

function Unregister-Instance {
    param([string]$File)
    if (-not $File) { return }
    try { if (Test-Path -LiteralPath $File) { Remove-Item -LiteralPath $File -Force -ErrorAction Stop } } catch { }
}

function Get-StoreLockFile {
    param([Parameter(Mandatory)][string]$StorePath)
    $norm = "$StorePath".Trim().TrimEnd('\').ToLowerInvariant()
    $md5  = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))).Replace("-", "")
    } finally { $md5.Dispose() }
    return (Join-Path $Script:StoreLockDir "$hash.lock")
}

function Lock-StorePath {
    <#
        Returns @{ Ok; Owner; File }. Ok=$false means another LIVE process holds
        this destination and .Owner says which. A lock whose owner has exited is
        stale - the window was closed or crashed mid-run - and gets taken over.
    #>
    param([Parameter(Mandatory)][string]$StorePath)
    try {
        if (-not (Test-Path $Script:StoreLockDir)) {
            New-Item -Path $Script:StoreLockDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $f = Get-StoreLockFile $StorePath
        if (Test-Path -LiteralPath $f) {
            $o = $null
            try { $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { }
            if ($o -and $o.OwnerPid) {
                $ownerPid = [int]$o.OwnerPid
                $alive = $null -ne (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
                if ($alive -and $ownerPid -ne $PID) {
                    Write-CrashLog "Store '$StorePath' is locked by PID $ownerPid"
                    return @{ Ok = $false; Owner = $o; File = $f }
                }
                if (-not $alive) { Write-CrashLog "Taking over stale store lock from PID $ownerPid" }
            }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
        @{ OwnerPid = $PID; User = $env:USERNAME; Machine = $env:COMPUTERNAME
           Store = $StorePath; Started = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") } |
            ConvertTo-Json | Out-File -FilePath $f -Encoding UTF8 -Force
        return @{ Ok = $true; Owner = $null; File = $f }
    } catch {
        Write-CrashLog "Store lock unavailable for '$StorePath' - continuing without one: $($_.Exception.Message)"
        return @{ Ok = $true; Owner = $null; File = "" }
    }
}

function Unlock-StorePath {
    param([string]$LockFile)
    if (-not $LockFile) { return }
    try { if (Test-Path -LiteralPath $LockFile) { Remove-Item -LiteralPath $LockFile -Force -ErrorAction Stop } }
    catch { Write-CrashLog "Could not release store lock ${LockFile}: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Remote diagnosis
#
#  "Access is denied" and "the RPC server is unavailable" send a technician in
#  completely different directions, and the raw exception text says neither in
#  words anyone acts on. These translate the handful of failures that actually
#  happen into the next thing to try.
# ---------------------------------------------------------------------------
function Get-RemoteErrorHelp {
    <#
        Turns an exception (or its message) into @{ What; Try }. Unrecognised
        errors come back with the original text and no invented advice - a wrong
        suggestion costs more time than no suggestion.
    #>
    param([string]$Message, [int]$HResult = 0)
    $m = "$Message"

    # 0x800706BA RPC unavailable, 0x80070005 access denied, 0x8004100E bad namespace
    if ($m -match '0x800706BA' -or $m -match 'RPC server is unavailable') {
        return @{ What = "the machine did not answer"
                  Try  = "Check it is switched on and on the network. RPC and File and Printer Sharing must be open to it - that is what blocks this most often." }
    }
    if ($m -match '0x80070005' -or $m -match 'Access is denied') {
        return @{ What = "access was denied"
                  Try  = "You need to be an administrator ON THAT MACHINE. Being an admin here is not enough, and a local (non-domain) admin account is refused over the network by default." }
    }
    if ($m -match '0x8004100E' -or $m -match 'Invalid namespace') {
        return @{ What = "WMI on that machine is broken"
                  Try  = "Its WMI repository is damaged. On that machine run: winmgmt.exe /resetrepository" }
    }
    if ($m -match '0x80041003') {
        return @{ What = "WMI refused the query"
                  Try  = "Your account lacks WMI permissions on that machine, even if it is an administrator." }
    }
    if ($m -match '0x80080005' -or $m -match 'Server execution failed') {
        return @{ What = "the WMI service would not start there"
                  Try  = "Start the 'Windows Management Instrumentation' service on that machine." }
    }
    if ($m -match 'network path was not found' -or $m -match '0x80070035') {
        return @{ What = "the network path was not found"
                  Try  = "The name did not resolve, or file sharing is closed. Check the spelling and try the IP address." }
    }
    if ($m -match 'network name cannot be found' -or $m -match '0x80070043') {
        return @{ What = "that share does not exist"
                  Try  = "The admin share (C$) may have been turned off on that machine." }
    }
    if ($m -match 'logon failure' -or $m -match '0x8007052E') {
        return @{ What = "the credentials were rejected"
                  Try  = "Your signed-in account is not accepted by that machine. Check it is domain-joined and that your account is not locked." }
    }
    return @{ What = $m; Try = "" }
}

# ---------------------------------------------------------------------------
#  OS architecture
#
#  SuperGrate keeps an x86 and an x64 USMT and picks per machine. Everything at
#  This fleet is x64, so amd64 stays the default and the 32-bit build is an override
#  rather than an auto-switch - but a 32-bit target now says so instead of
#  failing with an unexplained "not a valid Win32 application".
# ---------------------------------------------------------------------------
function Get-RemoteArchitecture {
    <#
        Returns @{ Ok; Arch ("amd64"/"x86"); Raw; Error }. Ok=$false means it
        could not be asked, which is NOT the same as "32-bit".
    #>
    param([Parameter(Mandatory)][string]$ComputerName)
    $pc = "$ComputerName".Trim()
    if (-not (Test-ValidComputerName $pc)) { return @{ Ok = $false; Arch = ""; Raw = ""; Error = "not a valid computer name" } }
    try {
        $wmiArgs = @{ Class = "Win32_OperatingSystem"; ErrorAction = "Stop" }
        if (-not (Test-IsThisComputer $pc)) { $wmiArgs["ComputerName"] = $pc }
        $os = Get-WmiObject @wmiArgs | Select-Object -First 1
        $raw = "$($os.OSArchitecture)"
        $arch = if ($raw -match '32') { "x86" } else { "amd64" }
        return @{ Ok = $true; Arch = $arch; Raw = $raw; Error = "" }
    } catch {
        return @{ Ok = $false; Arch = ""; Raw = ""; Error = $_.Exception.Message }
    }
}

function Get-USMTPathForArch {
    <#
        The USMT folder to use for a given architecture. Falls back to the
        configured folder when a sibling build is not deployed, because a
        missing x86 folder must not stop an x64 migration.
    #>
    param([Parameter(Mandatory)][string]$BasePath, [string]$Arch = "amd64")
    if ($Arch -ne "x86") { return $BasePath }
    $parent = Split-Path $BasePath -Parent
    foreach ($name in @("x86", "X86", "i386")) {
        $cand = Join-Path $parent $name
        if (Test-Path (Join-Path $cand "scanstate.exe")) { return $cand }
    }
    return $BasePath
}

function Test-ValidUsername {
    <#
        A name is only accepted if it cannot change the SHAPE of a command line.

        The same rule Test-ValidComputerName applies to machine names, and for a
        sharper reason: a remote run does not hand USMT an argument ARRAY. It
        builds one string and gives it to "schtasks /tr", and the task scheduler
        re-parses that string when the task runs. Anything unquoted in it is
        re-read as syntax on a machine where the task runs elevated.

        Spaces are allowed - "john doe" is a legitimate profile folder - and are
        handled by quoting at the point of use instead. What is rejected is the
        set of characters that mean something to a command line rather than
        naming a person.

        Deliberately not an existence check: a name that is not on the machine
        yet is still a legitimate thing to type.
    #>
    param([string]$Name)
    $n = "$Name".Trim()
    if (-not $n) { return $false }
    if ($n.Length -gt 256) { return $false }
    # Shell punctuation and control characters. A backslash is allowed because
    # DOMAIN\user is the normal form, and @ because so is a UPN.
    #
    # THE APOSTROPHE IS ALLOWED. O'Brien is a person, and refusing that name
    # would block a migration that works today - which is a worse outcome than
    # the thing being defended against, because the value ends up inside a
    # DOUBLE-quoted command line where an apostrophe is an ordinary character.
    # The caveat is narrow and worth writing down: anything that ever puts a
    # username into a WQL filter must quote it, because WQL delimits with
    # single quotes. Nothing does today.
    if ($n -match '["`&|;<>^%$()\[\]{}*?]') { return $false }
    if ($n -match '[\x00-\x1f]') { return $false }
    # A leading slash or dash would be read as another switch rather than a name.
    if ($n -match '^\s*[/-]') { return $false }
    # One separator at most: "CONTOSO\CONTOSO\jbrown" names nobody, and a trailing or
    # leading one is a name that is missing half of itself.
    if (($n.ToCharArray() | Where-Object { $_ -eq '\' }).Count -gt 1) { return $false }
    if ($n.StartsWith('\') -or $n.EndsWith('\')) { return $false }
    return $true
}

function Format-UsmtUser {
    <#
        A DOMAIN\user value as it should appear on a USMT command line.

        QUOTED ONLY WHEN IT HAS TO BE. Every name without a space comes out
        byte-identical to what this tool has always produced, so no working
        migration changes shape; a name WITH a space stops being split into two
        arguments, which is what "/ui:CONTOSO\john doe" did - USMT matched no
        account, captured nothing and exited 0. That is the same silent
        empty-capture that a one-character username caused before.
    #>
    param([string]$Value)
    if ("$Value" -match '\s') { return "`"$Value`"" }
    return $Value
}

function Test-ValidComputerName {
    <#
        Everything that names a machine ends up interpolated straight into a
        UNC path, so a name is only accepted if it cannot change the SHAPE of
        that path. Rejects anything containing a separator or a share character,
        and the device names that make \\.\ and \\?\ mean something other than
        "a computer": \\.\C$ is the raw volume, not a folder on a PC.

        Deliberately not a reachability test - an offline machine is still a
        legitimate thing to type. This is only about the string.
    #>
    param([string]$Name)
    $n = "$Name".Trim()
    if ([string]::IsNullOrWhiteSpace($n)) { return $false }
    if ($n.Length -gt 63) { return $false }
    if ($n -eq "." -or $n -eq "?" -or $n -eq "*") { return $false }
    # Letters, digits, dot and hyphen only: covers NetBIOS names and FQDNs and
    # excludes \ / : $ ? * " < > | and whitespace in one rule.
    if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]*$') { return $false }
    return $true
}

function Test-IsThisComputer {
    param([string]$Name)
    $n = "$Name".Trim()
    return ($n -eq "." -or $n -ieq "localhost" -or $n -ieq $env:COMPUTERNAME)
}

function Get-StagedToolsPath {
    <#
        Where USMT_Temp lives, as THIS machine should address it.

        The local machine gets a plain local path rather than \\OURSELF\C$.
        Loopback SMB works for a domain admin but is slower, needs the server
        service, and fails outright for a local (non-domain) administrator
        because that token is UAC-filtered over the network - so the tool used
        to report "not reachable" for the machine it was running on.
    #>
    param([string]$PC)
    if (Test-IsThisComputer $PC) { return "C:\Windows\Temp\$($Script:RemoteTempName)" }
    return Get-RemoteTempUNC $PC
}

function Get-RemoteTempUNC {
    param([string]$PC)
    return "\\$PC\C$\Windows\Temp\$($Script:RemoteTempName)"
}

function Copy-USMTToRemote {
    <#
    .SYNOPSIS
        Stages USMT tools on the source PC via its C$ admin share.
        Creates the Logs\ and Store\ subfolders.
        Returns the local path on the remote machine.
    #>
    param([string]$LocalUSMTPath, [string]$SourcePC, [bool]$Force = $false)
    $unc = Get-RemoteTempUNC $SourcePC
    if (-not (Test-Path $unc)) { New-Item -Path $unc -ItemType Directory -Force -ErrorAction Stop | Out-Null }

    # An estimate pass and the capture that follows it both need the tools, and
    # a re-run against the same PC finds them already there. Copying ~30 MB a
    # second time buys nothing, so match on scanstate.exe and skip if identical.
    $skip = $false
    if (-not $Force) {
        try {
            $src = Get-Item (Join-Path $LocalUSMTPath "scanstate.exe") -ErrorAction Stop
            $dst = Get-Item (Join-Path $unc "scanstate.exe") -ErrorAction Stop
            if ($src.Length -eq $dst.Length -and $src.LastWriteTimeUtc -eq $dst.LastWriteTimeUtc) { $skip = $true }
        } catch { $skip = $false }
    }
    if ($skip) {
        Write-CrashLog "USMT tools already staged at $unc - skipping copy"
    } else {
        Write-CrashLog "Staging USMT tools at $unc"
        # The tools folder is also the local log folder, so a plain wildcard copy
        # pushes every previous run's logs onto every machine touched - they pile
        # up and none of them are of any use over there. Copy the tools only.
        $skipNames = @("Logs", $Script:RemoteStoreSub)
        foreach ($item in (Get-ChildItem -LiteralPath $LocalUSMTPath -Force -ErrorAction Stop)) {
            if ($item.PSIsContainer -and ($skipNames -contains $item.Name)) { continue }
            if (-not $item.PSIsContainer -and ($item.Extension -ieq ".log")) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination $unc -Recurse -Force -ErrorAction Stop
        }
    }

    # Outside the skip branch on purpose. Config.xml normally sits beside the GUI
    # rather than inside the USMT folder, so a machine staged by an older build
    # has the tools but not the Config - and "tools already staged, skipping"
    # would then skip the one file that was missing. Without it, loadstate hits
    # error 72 (V2V arbitration).
    if (-not (Test-Path (Join-Path $unc "Config.xml"))) {
        foreach ($cand in @((Join-Path $LocalUSMTPath "Config.xml"),
                            $(if ($Script:ScriptDir) { Join-Path $Script:ScriptDir "Config.xml" } else { $null }))) {
            if ($cand -and (Test-Path $cand)) {
                Copy-Item -LiteralPath $cand -Destination $unc -Force -ErrorAction SilentlyContinue
                Write-CrashLog "Config.xml staged from $cand"
                break
            }
        }
    }
    foreach ($sub in @("Logs", $Script:RemoteStoreSub)) {
        $p = Join-Path $unc $sub
        if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
    }
    return $Script:RemoteTempLocal
}

function Write-RemoteBatchFile {
    <#
    .SYNOPSIS
        Writes RunScan.bat to the remote temp folder.
        Using a batch file avoids nested-quote hell in schtasks /tr.
        The batch exits with ScanState's exit code so the task reflects it.
    #>
    param(
        [string]$SourcePC,
        [string]$RemoteUSMTPath,    # local-on-remote, e.g. C:\Windows\Temp\USMT_Temp
        [string]$RemoteStorePath,   # local-on-remote store destination
        [string]$Username,
        [bool]$AllProfiles,
        [bool]$ExcludeOneDrive,
        [int]$Verbosity,
        [bool]$Overwrite,
        [string]$RemoteLogFile,
        [string]$RemoteProgressLog,
        [string]$RemoteStdoutLog,
        [bool]$SettingsOnly = $false,
        [string[]]$Extra    = @(),
        [string]$ArgOverride = "",
        # Same reason Build-USMTCommand declares it: an unmatched named argument
        # is not an error in a plain function, it just vanishes into $args. A
        # two-user REMOTE capture built a one-user command line and exited 0.
        [string[]]$Usernames = @()
    )
    # Presence is checked over the UNC; the ARGUMENT uses the path as the remote
    # machine will see it. Get-CommandPreview applies exactly the same rule so
    # the Expert-mode preview of a remote run matches what gets written here.
    $tempUNC = Get-RemoteTempUNC $SourcePC
    $cfgUNC  = Join-Path $tempUNC "Config.xml"
    $exUNC   = Join-Path $tempUNC "ExcludeOneDriveFolders.xml"
    $pubUNC  = Join-Path $tempUNC "MigratePublicFolders.xml"

    $cfgArg = ""
    if (Test-Path $cfgUNC -ErrorAction SilentlyContinue) {
        $cfgArg = "$RemoteUSMTPath\Config.xml"
        Write-CrashLog "Config.xml found and added to scanstate args"
    } else {
        Write-CrashLog "WARNING: Config.xml not found at $cfgUNC - V2V arbitration errors (error 72) may occur. Place Config.xml in your USMT tools folder."
    }
    $exArg = ""
    if ($ExcludeOneDrive) {
        if (Test-Path $exUNC -ErrorAction SilentlyContinue) {
            $exArg = "$RemoteUSMTPath\ExcludeOneDriveFolders.xml"
            Write-CrashLog "ExcludeOneDriveFolders.xml found and added to scanstate args"
        } else {
            Write-CrashLog "WARNING: ExcludeOneDriveFolders.xml not found at $exUNC - OneDrive will NOT be excluded. Place the file in your USMT tools folder."
        }
    }
    $pubArg = ""
    if ($SettingsOnly -and (Test-Path $pubUNC -ErrorAction SilentlyContinue)) {
        $pubArg = "$RemoteUSMTPath\MigratePublicFolders.xml"
    }

    $argStr = if ($ArgOverride) { $ArgOverride } else {
        Build-USMTArgs -Operation "Export" -StorePath $RemoteStorePath `
            -MigAppXml "$RemoteUSMTPath\migapp.xml" -MigUserXml "$RemoteUSMTPath\miguser.xml" `
            -PublicXml $pubArg -ConfigXml $cfgArg -ExcludeXml $exArg `
            -Username $Username -AllProfiles $AllProfiles -SettingsOnly $SettingsOnly `
            -Verbosity $Verbosity -Overwrite $Overwrite `
            -LogFile $RemoteLogFile -ProgressLog $RemoteProgressLog -Extra $Extra `
            -Usernames $Usernames
    }

    $batchContent = "@echo off`r`n`"$RemoteUSMTPath\scanstate.exe`" $argStr > `"$RemoteStdoutLog`" 2>&1`r`nexit /b %ERRORLEVEL%`r`n"

    $batchUNC = Join-Path (Get-RemoteTempUNC $SourcePC) "RunScan.bat"
    [System.IO.File]::WriteAllText($batchUNC, $batchContent, [System.Text.Encoding]::ASCII)
    Write-CrashLog "Wrote RunScan.bat -> $batchUNC"
}

function Start-RemoteScanTask {
    <#
    .SYNOPSIS
        Creates then immediately runs a one-shot SYSTEM task on the source PC.
        SYSTEM = full local profile access, no network credential issues on the source side.
        schtasks uses DCOM/RPC (port 135 + dynamic)  -  same as Computer Management remote.
        Returns @{ PC; TaskName } for polling.
    #>
    param([string]$SourcePC, [string]$RemoteUSMTPath)
    $ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
    $taskName = "USMT_Export_$ts"
    $batchLocal = "$RemoteUSMTPath\RunScan.bat"

    Write-CrashLog "Creating task '$taskName' on $SourcePC"
    $createOut = & schtasks /create /s $SourcePC /tn $taskName /tr `"$batchLocal`" /sc ONCE /st 00:00 /sd 01/01/2000 /ru SYSTEM /f 2>&1
    if ($LASTEXITCODE -ne 0) { throw "schtasks /create failed ($LASTEXITCODE): $createOut" }

    Write-CrashLog "Running task '$taskName' on $SourcePC"
    $runOut = & schtasks /run /s $SourcePC /tn $taskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        & schtasks /delete /s $SourcePC /tn $taskName /f 2>$null | Out-Null
        throw "schtasks /run failed ($LASTEXITCODE): $runOut"
    }
    return @{ PC = $SourcePC; TaskName = $taskName }
}

function Get-RemoteTaskStatus {
    <#
    .SYNOPSIS
        Quick non-throwing poll of task state. Called every timer tick.
        Returns @{ Finished; ExitCode; StatusText }

        Uses three independent methods - whichever fires first wins:
          A) schtasks /query CSV LastResult: if LastResult != 267011 (STILL_ACTIVE), task is done.
             We do NOT rely on the Status text column - it is locale-dependent (e.g. "Running"
             only on English Windows). The exit code constant 267011 is language-independent.
          B) Progress log: if USMT wrote "Successful run" or "errorCode," we know it finished.
          C) Detail log: scan for "USMT error code N" or "Successful run". Catches failures like
             error 72 (V2V arbitration) that exit during PHASE Applying without writing an
             errorCode line to the progress log.
    #>
    param(
        [string]$PC,
        [string]$TaskName,
        [string]$ProgressLogUNC = "",
        [string]$DetailLogUNC   = ""   # USMT /l: detail log - more reliable for errors
    )

    # ---- Method A: schtasks /query  (exit code only, locale-independent) ----
    try {
        $raw = & schtasks /query /s $PC /tn $TaskName /fo CSV /nh 2>&1
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $dataLine = $raw | Where-Object { $_ -match ',' -and $_ -notmatch '^\s*$' } | Select-Object -First 1
            if ($dataLine) {
                $clean   = $dataLine.Trim().TrimStart([char]0xFEFF)
                # CSV columns: "TaskName","Next Run Time","Status","Last Run Time","Last Result"
                $fields  = $clean -split '","'
                $exitRaw = if ($fields.Count -gt 4) { $fields[4].Trim('"').Trim() } else { "267011" }
                $exitInt = try { [int]$exitRaw } catch { 267011 }
                # 267011 = 0x00041303 = STILL_ACTIVE - task is still running
                if ($exitInt -ne 267011) {
                    $statusText = if ($fields.Count -gt 2) { $fields[2].Trim('"').Trim() } else { "Done" }
                    Write-CrashLog "Task '$TaskName' on $PC finished via Method A: exit=$exitInt status=$statusText"
                    return @{ Finished = $true; ExitCode = $exitInt; StatusText = $statusText }
                }
            }
        }
    } catch { }

    # ---- Method B: USMT progress log (CSV format) ----
    # Catches normal completions: "Successful run" on success, "errorCode, N" on failure.
    # NOTE: V2V arbitration failures (error 72) may NOT write an errorCode line here -
    #       the progress log ends at "PHASE, Applying". Use Method C for those.
    if (-not [string]::IsNullOrWhiteSpace($ProgressLogUNC)) {
        try {
            if (Test-Path $ProgressLogUNC -ErrorAction SilentlyContinue) {
                # Same reasoning as Method C: both markers close the log.
                $lines = Read-FileEndLines -FilePath $ProgressLogUNC -Count 60 -MaxBytes 32768
                foreach ($line in $lines) {
                    if ($line -match 'Successful run') {
                        Write-CrashLog "Task '$TaskName' completed via Method B (progress): Successful run"
                        return @{ Finished = $true; ExitCode = 0; StatusText = "SuccessViaProgressLog" }
                    }
                    if ($line -match 'errorCode,\s*(\d+)') {
                        $ec = try { [int]$Matches[1] } catch { 1 }
                        Write-CrashLog "Task '$TaskName' failed via Method B (progress): errorCode=$ec"
                        return @{ Finished = $true; ExitCode = $ec; StatusText = "FailedViaProgressLog" }
                    }
                }
            }
        } catch { }
    }

    # ---- Method C: USMT detail log ----
    # The detail log is written by the /l: flag and captures the full USMT run.
    # "USMT Completed" appears on BOTH success and failure, so we read it in conjunction
    # with the "USMT error code N" line or "Successful run" line that precedes it.
    if (-not [string]::IsNullOrWhiteSpace($DetailLogUNC)) {
        try {
            if (Test-Path $DetailLogUNC -ErrorAction SilentlyContinue) {
                # Only the END of the log. All three markers are written in the
                # closing lines of a run, so the megabytes before them were being
                # pulled across the wire once a second for nothing - which is why
                # a finished capture could sit there looking busy.
                $lines = Read-FileEndLines -FilePath $DetailLogUNC -Count 120 -MaxBytes 65536
                $detailErrorCode = -1
                $detailCompleted = $false
                foreach ($line in $lines) {
                    # e.g.: "2026-02-20 12:58:23, Info [0x000000] * USMT error code 72:"
                    if ($line -match 'USMT error code\s+(\d+)') {
                        $detailErrorCode = try { [int]$Matches[1] } catch { 1 }
                    }
                    # "USMT Completed" is the final line in the detail log (both success and failure)
                    if ($line -match 'USMT Completed') {
                        $detailCompleted = $true
                    }
                    if ($line -match 'Successful run') {
                        Write-CrashLog "Task '$TaskName' completed via Method C (detail): Successful run"
                        return @{ Finished = $true; ExitCode = 0; StatusText = "SuccessViaDetailLog" }
                    }
                }
                if ($detailCompleted) {
                    $ec = if ($detailErrorCode -ge 0) { $detailErrorCode } else { 0 }
                    Write-CrashLog "Task '$TaskName' completed via Method C (detail): errorCode=$ec"
                    return @{ Finished = $true; ExitCode = $ec; StatusText = "DoneViaDetailLog" }
                }
            }
        } catch { }
    }

    # None of the three methods confirmed completion
    return @{ Finished = $false; ExitCode = 267011; StatusText = "Running" }
}

function Remove-RemoteTask {
    param([string]$PC, [string]$TaskName)
    try { & schtasks /delete /s $PC /tn $TaskName /f 2>$null | Out-Null; Write-CrashLog "Deleted task '$TaskName' on $PC" }
    catch { Write-CrashLog "Task delete skipped: $($_.Exception.Message)" }
}

function Remove-RemoteTempFolder {
    param([string]$SourcePC)
    try {
        $unc = Get-RemoteTempUNC $SourcePC
        if (Test-Path $unc) { Remove-Item -Path $unc -Recurse -Force -ErrorAction Stop; Write-CrashLog "Cleaned remote temp on $SourcePC" }
    } catch { Write-CrashLog "Remote cleanup skipped: $($_.Exception.Message)" }
}

function Get-StagedToolsInfo {
    <#
    .SYNOPSIS
        Reports whether USMT_Temp is sitting on a machine, and how big it is.
    .DESCRIPTION
        A failed run deliberately leaves the folder behind so its logs survive
        for diagnosis, which means nothing ever removes it afterwards. This is
        what the manual cleanup reads to show what it would be deleting.
    #>
    param([Parameter(Mandatory)][string]$ComputerName)
    $pc  = $ComputerName.Trim()
    if (-not (Test-ValidComputerName $pc)) {
        return @{ PC = $pc; Present = $false; Reachable = $false; Error = "not a valid computer name"; MB = 0; Files = 0; Path = "" }
    }
    $unc = Get-StagedToolsPath $pc
    try {
        if (-not (Test-Path $unc -ErrorAction Stop)) {
            return @{ PC = $pc; Present = $false; Reachable = $true; Error = ""; MB = 0; Files = 0; Path = $unc }
        }
    } catch {
        return @{ PC = $pc; Present = $false; Reachable = $false; Error = $_.Exception.Message; MB = 0; Files = 0; Path = $unc }
    }
    $bytes = [uint64]0; $files = 0
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($unc, "*", [System.IO.SearchOption]::AllDirectories)) {
            try { $bytes += [uint64](New-Object System.IO.FileInfo $f).Length; $files++ } catch { }
        }
    } catch { }
    return @{
        PC = $pc; Present = $true; Reachable = $true; Error = ""
        MB = [Math]::Round($bytes / 1MB, 1); Files = $files; Path = $unc
    }
}

# ---------------------------------------------------------------------------
#  Stale user profiles
#
#  sysdm.cpl cannot do this. It is an interactive Control Panel applet - System
#  Properties > Advanced > User Profiles > Settings - with no command line, no
#  remoting, and nothing to automate but the dialog itself.
#
#  Win32_UserProfile is what that dialog drives underneath, and it IS remotable
#  over DCOM - the same transport this tool already uses for Win32_Share. Its
#  Delete() removes the profile directory AND the ProfileList registry entry.
#
#  That second half is the whole reason to do it this way. Deleting
#  C:\Users\<name> by hand leaves the registry entry behind, and the next time
#  that user signs in Windows cannot match them to a profile and hands them a
#  temporary one - the "you have been logged on with a temporary profile"
#  fault, which is markedly worse than the disk space it was meant to reclaim.
# ---------------------------------------------------------------------------

# Well-known SIDs that are never a person: SYSTEM, LOCAL SERVICE, NETWORK SERVICE.
$Script:SystemProfileSids = @("S-1-5-18", "S-1-5-19", "S-1-5-20")

function Get-RemoteUserProfiles {
    <#
        Lists the user profiles on a machine and says which are safe to remove.

        Every profile comes back, including the ones that must not be touched,
        each with a Removable flag and the reason. Filtering them out silently
        would leave the operator wondering where a profile went.

        LastUseTime is the same figure the sysdm.cpl dialog shows. It is a
        guide, not gospel - a backup agent or an AV sweep touching the profile
        can refresh it - so age is offered as evidence, not as a decision.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [int]$InactiveDays = 0,          # 0 = do not judge on age
        [string[]]$Protect = @()         # extra account names to refuse
    )
    $pc = $ComputerName.Trim()
    if (-not (Test-ValidComputerName $pc)) {
        return @{ Ok = $false; PC = $pc; Error = "not a valid computer name"; Profiles = @() }
    }
    $out = @()
    try {
        $wmiArgs = @{ Class = "Win32_UserProfile"; ErrorAction = "Stop" }
        if (-not (Test-IsThisComputer $pc)) { $wmiArgs["ComputerName"] = $pc }
        $profiles = @(Get-WmiObject @wmiArgs)
    } catch {
        return @{ Ok = $false; PC = $pc; Error = $_.Exception.Message; Profiles = @() }
    }

    $meNames = @($env:USERNAME, "$env:USERDOMAIN\$env:USERNAME")
    foreach ($p in $profiles) {
        $path = "$($p.LocalPath)"
        $sid  = "$($p.SID)"
        $leaf = if ($path) { Split-Path $path -Leaf } else { $sid }

        # SID -> account name. A local account on a remote box often will not
        # resolve from here, so the folder name stands in rather than showing a
        # raw SID to someone deciding what to delete.
        # AN UNRESOLVABLE SID IS EVIDENCE, not a formatting problem.
        #
        # It is what sysdm.cpl shows as "Account Unknown": the profile is still
        # on the disk but the account it belonged to has been deleted from the
        # directory. That is the single most useful thing to know about a profile
        # before a migration - there is nobody to migrate it FOR - and it was
        # being swallowed, leaving an orphan looking like an ordinary user.
        #
        # A local account on a remote box often will not resolve from here
        # either, so this is reported rather than acted on: the folder name still
        # stands in for the label, and the row simply says the account could not
        # be found.
        $account = $leaf
        $orphan  = $false
        try {
            $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate(
                        [System.Security.Principal.NTAccount]).Value
        } catch { $orphan = $true }
        # ASK THE MACHINE THAT OWNS THE ACCOUNT BEFORE CALLING IT DELETED.
        #
        # The translate above runs HERE, against this machine's authority. A
        # LOCAL account on a remote PC will never resolve from here, and calling
        # that an orphan is a false accusation on the one screen where somebody
        # decides what to delete. SuperGrate resolves the SID on the host itself
        # via Win32_SID, so the same is done - but only for the SIDs that already
        # failed, which keeps it to a handful of calls instead of one per profile
        # on every refresh.
        if ($orphan -and $sid -and -not (Test-IsThisComputer $pc)) {
            try {
                $s = Get-WmiObject -Class Win32_SID -Filter "SID='$sid'" -ComputerName $pc -ErrorAction Stop
                if ($s -and $s.AccountName -and $s.AccountName -ne $sid) {
                    $account = if ($s.ReferencedDomainName) { "$($s.ReferencedDomainName)\$($s.AccountName)" }
                               else { $s.AccountName }
                    $orphan = $false
                }
            } catch { }
        }

        # TWO FACTS, NEITHER OF THEM CALLED "LAST USED".
        #
        # Three signals used to fall back to each other, and remote profiles
        # untouched for months came back as used 0-1 days ago. The fallbacks
        # were the bug:
        #   LastUseTime - moved whenever the profile service touches a profile,
        #                 and reads "now" for any loaded hive. Not used.
        #   Folder date - moved by indexing, antivirus, backup. Measured here as
        #                 six days newer than the truth. Not used.
        #   NTUSER.DAT  - the user's hive, written on load and unload. Real
        #                 sessions. The only one read.
        # Unreadable means "unknown", not a plausible wrong number. SuperGrate
        # does the same and never calls either date a last-used date, which is
        # why the columns say FIRST CREATED and LAST MODIFIED.
        $last = $null; $dateFrom = ""; $created = $null
        if ($path) {
            try {
                $folder = if (Test-IsThisComputer $pc) { $path }
                          else { $path -replace '^([A-Za-z]):', "\\$pc\`$1`$" }
                $di = New-Object System.IO.DirectoryInfo $folder
                if ($di.Exists) { $created = $di.CreationTime }
                $fi = New-Object System.IO.FileInfo (Join-Path $folder "NTUSER.DAT")
                if ($fi.Exists) { $last = $fi.LastWriteTime; $dateFrom = "NTUSER.DAT" }
            } catch { }
        }
        $age = if ($last) { [int]((Get-Date) - $last).TotalDays } else { -1 }
        $createdDays = if ($created) { [int]((Get-Date) - $created).TotalDays } else { -1 }

        # Two separate questions, and they do NOT have the same answer.
        #
        # Migratable: is this a real person's profile that USMT could capture?
        # Being signed in does not disqualify it - capturing a live profile is
        # the normal case, and refusing it would rule out most machines.
        #
        # Removable: is it safe to DELETE? Much stricter, and a signed-in
        # profile is firmly out.
        $isSystem = $p.Special -or ($Script:SystemProfileSids -contains $sid) -or ($path -match '^[A-Za-z]:\\Windows\\')
        $migratable = (-not $isSystem) -and $path -and ($leaf -notin @("Public","Default","Default User","All Users","defaultuser0"))

        $removable = $true; $reason = ""
        if ($p.Special)                              { $removable = $false; $reason = "system profile" }
        elseif ($Script:SystemProfileSids -contains $sid) { $removable = $false; $reason = "built-in account" }
        elseif ($path -match '^[A-Za-z]:\\Windows\\') { $removable = $false; $reason = "lives under Windows" }
        elseif ($p.Loaded)                           { $removable = $false; $reason = "signed in right now" }
        elseif ($meNames -contains $account -or $leaf -ieq $env:USERNAME) {
                                                       $removable = $false; $reason = "that is you" }
        elseif ($Protect -contains $leaf -or $Protect -contains $account) {
                                                       $removable = $false; $reason = "protected by this run" }
        # AN ORPHAN IS STALE WITHOUT NEEDING A DATE.
        #
        # This is the rule that was missing. Stale meant one thing - idle for
        # longer than the setting - so a profile whose account had been deleted
        # outright was held back for want of a readable timestamp, which is the
        # single clearest case there is. There is nobody left who can sign in.
        # It does not have to prove it is old as well.
        elseif ($orphan)                             { }
        elseif ($InactiveDays -gt 0 -and $age -ge 0 -and $age -lt $InactiveDays) {
                                                       $removable = $false; $reason = "changed $age days ago" }
        elseif ($InactiveDays -gt 0 -and $age -lt 0)  { $removable = $false; $reason = "no readable date" }

        # STALE, stated once, so every screen agrees on what the word means.
        # Old enough by the setting, OR no account left behind it.
        $stale = $orphan -or ($InactiveDays -gt 0 -and $age -ge $InactiveDays)

        $out += @{
            PC = $pc; SID = $sid; Path = $path; Account = $account; Leaf = $leaf
            # Modified, not "last used" - it is the hive's write time and that is
            # all this tool can prove. Created is when the profile folder first
            # appeared. Both are facts; neither is a logon record.
            LastUse = $last; AgeDays = $age; DateFrom = $dateFrom
            Created = $created; CreatedDays = $createdDays
            Loaded = [bool]$p.Loaded; Special = [bool]$p.Special
            # "Account Unknown" in sysdm.cpl - the account is gone, the profile
            # is not. Nothing is decided on this; it is shown so the operator can.
            Orphan = $orphan
            Stale = $stale
            Removable = $removable; Reason = $reason
            Migratable = $migratable
        }
    }
    # Orphans first, then oldest by hive date. The rows somebody is looking for
    # are at the top instead of scattered through a list sorted by a date half
    # of them do not have.
    return @{ Ok = $true; PC = $pc; Error = ""
              Profiles = @($out | Sort-Object @{ E = { [int][bool]$_.Orphan }; Descending = $true },
                                              @{ E = { $_.AgeDays }; Descending = $true }) }
}

function Remove-SourceProfileAfterCapture {
    <#
        Deletes the captured profile from the machine it came off.

        This is the most destructive thing the tool can do: it runs straight
        after a capture, on a profile that by definition still exists, and its
        only safety net is the store that was just written. So it refuses
        unless that store is provably readable FIRST - a capture that failed,
        or wrote somewhere unexpected, must never be followed by a deletion.

        Returns @{ Ok; Skipped; Error }. Skipped=$true means it declined on
        safety grounds, which is not a failure of the migration.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$StorePath,
        # ScanState's log for the run that produced this store. Without it the
        # only evidence available is store-wide, which says nothing about this
        # particular user - see gate 2b.
        [string]$CaptureLog = ""
    )
    $pc = "$ComputerName".Trim()
    if (-not (Test-ValidComputerName $pc)) { return @{ Ok = $false; Skipped = $true; Error = "not a valid computer name" } }

    # 1. The store has to exist and be a real store.
    $chk = Test-StoreReadable $StorePath
    if (-not $chk.Ok) {
        Write-CrashLog "REFUSED to delete source profile: store not readable ($($chk.Error))"
        return @{ Ok = $false; Skipped = $true; Error = "the store is not readable, so the profile was left alone ($($chk.Error))" }
    }
    # 2. And it has to have something in it. An empty .MIG means the capture
    #    produced nothing, whatever exit code it reported.
    $sz = Get-StoreSizeOnDisk -StorePath $chk.Root
    if (-not $sz -or [uint64]$sz.Bytes -lt 1MB) {
        Write-CrashLog "REFUSED to delete source profile: store is only $(if ($sz) { $sz.Bytes } else { 0 }) bytes"
        return @{ Ok = $false; Skipped = $true; Error = "the store is suspiciously small, so the profile was left alone" }
    }

    # 2b. AND THIS USER HAS TO BE IN IT.
    #
    # Gates 1 and 2 are properties of the STORE, not of the person. On a
    # multi-user capture they pass on somebody else's data: if alice and bob
    # captured and carol was skipped, carol's store-wide checks all succeed and
    # her profile gets deleted with her data held nowhere. $chk.Root can even be
    # the parent folder, so the size can be an aggregate over unrelated users.
    #
    # $false means the log ran to the end without ever naming her - refuse.
    # $null means there was no readable log, which is not evidence either way,
    # so it also refuses: this deletes the only remaining copy of someone's
    # files, and "no proof" must never read as "go ahead".
    $seen = Test-UserCapturedInLog -LogPath $CaptureLog -Username $Username
    if ($seen -ne $true) {
        $why = if ($null -eq $seen) { "there is no readable capture log to check against" }
               else { "the capture log never names them - either nothing of theirs was captured, or the log detail is too low to tell" }
        Write-CrashLog "REFUSED to delete source profile for '$Username' on $pc - $why"
        return @{ Ok = $false; Skipped = $true
                  Error = "'$Username' was left alone - $why" }
    }

    # 3. Find that user's profile, and only that one.
    $all = Get-RemoteUserProfiles -ComputerName $pc
    if (-not $all.Ok) { return @{ Ok = $false; Skipped = $true; Error = $all.Error } }
    $bare = if ($Username -match '\\') { $Username.Split('\')[-1] } else { $Username }
    $target = @($all.Profiles | Where-Object {
        $_.Migratable -and ($_.Leaf -ieq $bare -or $_.Account -ieq $Username)
    })
    if ($target.Count -eq 0) { return @{ Ok = $false; Skipped = $true; Error = "no profile for '$bare' on $pc" } }
    if ($target.Count -gt 1) { return @{ Ok = $false; Skipped = $true; Error = "more than one profile matches '$bare' on $pc" } }

    $t = $target[0]
    if ($t.Loaded) {
        # Deleting a loaded profile leaves the user in a broken session.
        return @{ Ok = $false; Skipped = $true; Error = "'$bare' is signed in on $pc - sign them out first" }
    }
    $r = Remove-RemoteUserProfile -ComputerName $pc -SID $t.SID
    if ($r.Ok) { return @{ Ok = $true; Skipped = $false; Error = ""; Path = $t.Path } }
    return @{ Ok = $false; Skipped = $false; Error = $r.Error }
}

function Test-UserCapturedInLog {
    <#
        Did THIS user actually get captured, according to ScanState's own log?

        The store-level gates cannot answer this. A multi-user capture that
        skipped one person - locked hive, no local profile, a name that matched
        nothing - still writes a large, readable, perfectly valid store and
        still exits 0. Both existing gates pass on the OTHER users' data, so the
        skipped person's profile was deleted from the source with their data
        held nowhere.

        ScanState names each user as it works: "DOMAIN\user (1 of 2): 100% done"
        and "<DOMAIN\user>\..." migration units throughout.

        WHAT COUNTS AS EVIDENCE IS DELIBERATELY NARROW. Every false yes here
        deletes somebody's only copy, and "the name appears somewhere in the
        log" says yes far too easily:

          - USMT echoes its own command line, so a name that was ASKED FOR but
            captured nothing still appears - which is the exact case this gate
            exists to catch. Being requested is not evidence of being captured.
          - A bare substring lets a file called bobsled-plans.docx vouch for a
            user named bob.

        So the name has to appear the way USMT writes an ACCOUNT - qualified by
        a backslash (DOMAIN\bob, <DOMAIN\bob>\Documents, C:\Users\bob\...) or as
        the subject of a per-user progress line - it has to end on a word
        boundary, and lines that merely quote the arguments are skipped.

        Returns $true, $false, or $null for "cannot tell" - a missing or
        unreadable log is not proof of either, and the caller must treat it as
        no proof rather than as consent.
    #>
    param([string]$LogPath, [Parameter(Mandatory)][string]$Username)
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $null }
    $bare = if ($Username -match '\\') { $Username.Split('\')[-1] } else { $Username }
    if (-not $bare) { return $null }
    try {
        $n    = [regex]::Escape($bare)
        $rx   = [regex]::new("(?:[\\<]$n\b)|(?:\b$n\s*\(\s*\d+\s+of\s+\d+\s*\))", 'IgnoreCase')
        $echo = [regex]::new('command line|/ue:|/ui:|/mu:', 'IgnoreCase')
        # These logs reach tens of megabytes, so it streams rather than loading
        # the file: one match is enough and most are found early.
        $sr = New-Object System.IO.StreamReader($LogPath)
        try {
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($echo.IsMatch($line)) { continue }
                if ($rx.IsMatch($line))   { return $true }
            }
        } finally { $sr.Dispose() }
        return $false
    } catch { return $null }
}

function Remove-RemoteUserProfile {
    <#
        Deletes one profile by SID, re-proving the safety rules first.

        The list was built before a confirmation dialog the operator may have
        sat on for a while, and someone can sign in during that time - so the
        Loaded and Special flags are read again from the live object rather
        than trusted from the list.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$SID
    )
    $pc = $ComputerName.Trim()
    if (-not (Test-ValidComputerName $pc)) { return @{ Ok = $false; Error = "not a valid computer name" } }
    if ($Script:SystemProfileSids -contains $SID) {
        Write-CrashLog "REFUSED to delete built-in profile $SID on $pc"
        return @{ Ok = $false; Error = "refused: built-in account" }
    }
    try {
        $wmiArgs = @{ Class = "Win32_UserProfile"; Filter = "SID='$SID'"; ErrorAction = "Stop" }
        if (-not (Test-IsThisComputer $pc)) { $wmiArgs["ComputerName"] = $pc }
        $p = Get-WmiObject @wmiArgs
        if (-not $p) { return @{ Ok = $false; Error = "no profile with that SID any more" } }
        if ($p.Special) {
            Write-CrashLog "REFUSED to delete special profile $SID on $pc"
            return @{ Ok = $false; Error = "refused: system profile" }
        }
        if ($p.Loaded) {
            # Changed under us between listing and confirming.
            Write-CrashLog "REFUSED to delete loaded profile $SID on $pc"
            return @{ Ok = $false; Error = "refused: that user has signed in since the list was made" }
        }
        $path = "$($p.LocalPath)"
        [void]$p.Delete()
        Write-CrashLog "Deleted profile $SID ($path) on $pc"
        return @{ Ok = $true; Error = ""; Path = $path }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
#  Store metadata
#
#  A .MIG file says nothing about itself. Six months later a folder called
#  "jbrown" tells you a name and nothing else: which machine it came off,
#  who captured it, whether it was ever restored, or onto what.
#
#  So a small JSON file is written beside every store. It EXTENDS the existing
#  export_complete.json rather than replacing it - older builds still read that
#  file, and the import side still uses it as the "this finished" flag.
# ---------------------------------------------------------------------------
$Script:StoreMetaName = "utw_store.json"

function Write-StoreMetadata {
    <#
        Records or updates what is known about a store. Called after a capture
        with the export facts, and again after a restore with the import ones -
        so a store carries its whole history, not just its birth.
    #>
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [hashtable]$Facts = @{}
    )
    try {
        if (-not (Test-Path -LiteralPath $StorePath)) { return $false }
        $file = Join-Path $StorePath $Script:StoreMetaName
        $meta = @{}
        # Merge rather than overwrite: the import pass must not erase the
        # export pass's record of where the profile came from.
        if (Test-Path -LiteralPath $file) {
            try {
                $existing = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                foreach ($p in $existing.PSObject.Properties) { $meta[$p.Name] = $p.Value }
            } catch { }
        }
        foreach ($k in $Facts.Keys) { $meta[$k] = $Facts[$k] }
        $meta["SchemaVersion"] = 1
        $meta | ConvertTo-Json -Depth 3 | Out-File -FilePath $file -Encoding UTF8 -Force
        return $true
    } catch {
        Write-CrashLog "Could not write store metadata to ${StorePath}: $($_.Exception.Message)"
        return $false
    }
}

function Read-StoreMetadata {
    <#
        Everything known about one store, from utw_store.json, falling back to
        the older export_complete.json, then to the folder itself. Always
        returns a row - a store with no metadata at all is still a store, and
        hiding it because it predates this feature would be wrong.
    #>
    param([Parameter(Mandatory)][string]$StorePath)
    $row = @{
        Path = $StorePath; Name = (Split-Path $StorePath -Leaf)
        Username = ""; Domain = ""; SourceComputer = ""; DestinationComputer = ""
        ExportedBy = ""; ExportedOn = ""; ImportedBy = ""; ImportedOn = ""
        RestoredAs = ""; Bytes = [uint64]0; Text = ""; AgeDays = -1; HasMeta = $false
    }
    try {
        $di = New-Object System.IO.DirectoryInfo $StorePath
        if ($di.Exists) { $row.AgeDays = [int]((Get-Date) - $di.LastWriteTime).TotalDays }
    } catch { }
    $sz = Get-StoreSizeOnDisk -StorePath $StorePath
    if ($sz) { $row.Bytes = [uint64]$sz.Bytes; $row.Text = (Format-Size $sz.Bytes) }

    $meta = Join-Path $StorePath $Script:StoreMetaName
    if (Test-Path -LiteralPath $meta) {
        try {
            $j = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
            foreach ($k in @("Username","Domain","SourceComputer","DestinationComputer",
                             "ExportedBy","ExportedOn","ImportedBy","ImportedOn","RestoredAs")) {
                if ($j.PSObject.Properties.Name -contains $k -and $j.$k) { $row[$k] = "$($j.$k)" }
            }
            $row.HasMeta = $true
        } catch { Write-CrashLog "Store metadata unreadable at ${meta}: $($_.Exception.Message)" }
    }
    if (-not $row.HasMeta) {
        # Stores captured before this existed still have the completion flag.
        $flag = Join-Path $StorePath $Script:AppConfig.CompletionFlag
        if (Test-Path -LiteralPath $flag) {
            try {
                $j = Get-Content -LiteralPath $flag -Raw | ConvertFrom-Json
                if ($j.Username)        { $row.Username = "$($j.Username)" }
                if ($j.SourceComputer)  { $row.SourceComputer = "$($j.SourceComputer)" }
                if ($j.TargetComputer)  { $row.DestinationComputer = "$($j.TargetComputer)" }
                if ($j.ExportedBy)      { $row.ExportedBy = "$($j.ExportedBy)" }
                if ($j.ExportCompleted) { $row.ExportedOn = "$($j.ExportCompleted)" }
                $row.HasMeta = $true
            } catch { }
        }
    }
    # Last resort: the folder is named after the user or the machine.
    if (-not $row.Username) { $row.Username = $row.Name }
    return $row
}

function Get-StoreContents {
    <#
        Every store under a root, with its metadata - the store browser's data.

        Works against any root: a network share, a USB drive, or C:\USMT
        Profiles on a machine. Non-stores are reported separately rather than
        silently dropped, same rule as the clean up.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Recurse
    )
    $res = @{ Ok = $false; Root = $Root; Error = ""; Stores = @(); Ignored = @() }
    try {
        if (-not (Test-Path -LiteralPath $Root -ErrorAction Stop)) {
            $res.Error = "not found or not reachable"; return $res
        }
    } catch {
        $h = Get-RemoteErrorHelp $_.Exception.Message
        $res.Error = $h.What; return $res
    }
    $res.Ok = $true

    # The root itself may BE a store - people point at one directly.
    $self = Test-StoreReadable $Root
    if ($self.Ok) { $res.Stores = @((Read-StoreMetadata $self.Root)); return $res }

    $stores = @(); $ignored = @()
    try {
        foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
            $chk = Test-StoreReadable $d.FullName
            if ($chk.Ok) { $stores += (Read-StoreMetadata $chk.Root); continue }
            # One level down as well: a per-machine folder holding per-user stores.
            $found = $false
            if ($Recurse) {
                foreach ($sub in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $c2 = Test-StoreReadable $sub.FullName
                    if ($c2.Ok) { $stores += (Read-StoreMetadata $c2.Root); $found = $true }
                }
            }
            if (-not $found) { $ignored += @{ Name = $d.Name; Path = $d.FullName; Reason = $chk.Error } }
        }
    } catch { $res.Error = $_.Exception.Message }
    $res.Stores  = @($stores | Sort-Object { $_.AgeDays })
    $res.Ignored = @($ignored)
    return $res
}

# ---------------------------------------------------------------------------
#  Active Directory computer search
# ---------------------------------------------------------------------------
function Search-ADComputers {
    <#
        Finds domain computers by name or description, so a machine can be
        picked from a list instead of remembered. Returns @{ Ok; Computers; Error }.

        Capped and time-limited: a wildcard against a large directory otherwise
        returns thousands of rows and freezes the window that asked for them.
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxResults = 200,
        [int]$TimeoutSec = 15
    )
    $res = @{ Ok = $false; Computers = @(); Error = "" }
    $q = "$Query".Trim()
    if ([string]::IsNullOrWhiteSpace($q)) { $res.Error = "nothing to search for"; return $res }
    # The filter is built from this string, so the LDAP metacharacters go first.
    $esc = $q -replace '([\\()*\0/])', '\$1'
    try {
        Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue
        $ds = New-Object System.DirectoryServices.DirectorySearcher
        $ds.Filter = "(&(objectCategory=computer)(|(name=*$esc*)(description=*$esc*)))"
        $ds.PageSize = 200
        $ds.SizeLimit = $MaxResults
        $ds.ClientTimeout   = [TimeSpan]::FromSeconds($TimeoutSec)
        $ds.ServerTimeLimit = [TimeSpan]::FromSeconds($TimeoutSec)
        foreach ($p in @("name","description","distinguishedname","operatingsystem","lastlogontimestamp")) {
            [void]$ds.PropertiesToLoad.Add($p)
        }
        $out = @()
        foreach ($r in $ds.FindAll()) {
            $get = { param($k) if ($r.Properties[$k].Count -gt 0) { "$($r.Properties[$k][0])" } else { "" } }
            $dn  = & $get "distinguishedname"
            # The IMMEDIATE OU only. The full chain is the entire DN backwards
            # ("Support,OU=IT,OU=Administration,OU=Workstations,...") and is far
            # too long for a column; the leaf OU is the bit that identifies
            # where a machine lives.
            $ou = ""
            if ($dn -match ',OU=([^,]+)') { $ou = $Matches[1] }
            $last = ""
            try {
                if ($r.Properties["lastlogontimestamp"].Count -gt 0) {
                    $last = [DateTime]::FromFileTime([int64]$r.Properties["lastlogontimestamp"][0]).ToString("yyyy-MM-dd")
                }
            } catch { }
            $out += @{
                Name = (& $get "name"); Description = (& $get "description")
                OU = $ou; OS = (& $get "operatingsystem"); LastSeen = $last; DN = $dn
            }
        }
        $res.Ok = $true
        $res.Computers = @($out | Sort-Object { $_.Name })
    } catch {
        $h = Get-RemoteErrorHelp $_.Exception.Message
        $res.Error = $h.What
        Write-CrashLog "AD computer search failed: $($_.Exception.Message)"
    }
    return $res
}

function Resolve-StoreRoot {
    <#
    .SYNOPSIS
        Normalises whatever the technician picked into the path LoadState wants.
    .DESCRIPTION
        USMT expects the store ROOT - the folder that holds USMT\USMT.MIG - but
        people reasonably point at the USMT folder, or at the .MIG file itself.
        All three resolve to the same store, so accept all three rather than
        failing with "invalid store path" on a perfectly good selection.
    #>
    param([string]$Path)
    $p = "$Path".Trim().TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    try {
        # The .MIG file itself -> up two levels (â€¦\<root>\USMT\USMT.MIG)
        if ($p -match '\.mig\d*$' -and (Test-Path -LiteralPath $p -PathType Leaf -ErrorAction SilentlyContinue)) {
            $usmtDir = Split-Path $p -Parent
            if ((Split-Path $usmtDir -Leaf) -ieq "USMT") { return (Split-Path $usmtDir -Parent) }
            return $usmtDir
        }
        if (-not (Test-Path -LiteralPath $p -PathType Container -ErrorAction SilentlyContinue)) { return $null }
        # Already the store root
        if (Test-Path -LiteralPath (Join-Path $p "USMT") -ErrorAction SilentlyContinue) { return $p }
        # The USMT folder -> its parent is the root
        if ((Split-Path $p -Leaf) -ieq "USMT") { return (Split-Path $p -Parent) }
        # A folder holding .MIG files directly
        if (@(Get-ChildItem -LiteralPath $p -Filter "*.mig*" -File -ErrorAction SilentlyContinue).Count -gt 0) {
            return (Split-Path $p -Parent)
        }
    } catch { Write-CrashLog "Could not resolve store root for '$Path': $($_.Exception.Message)" }
    return $null
}

function Test-StoreReadable {
    <#
    .SYNOPSIS
        Confirms a path really is a USMT store before anything is copied or run.
    #>
    param([string]$Path)
    $root = Resolve-StoreRoot $Path
    if (-not $root) { return @{ Ok = $false; Root = ""; Error = "not a USMT store (no USMT\USMT.MIG inside)" } }
    $mig = Join-Path (Join-Path $root "USMT") "USMT.MIG"
    if (-not (Test-Path -LiteralPath $mig -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Root = $root; Error = "no USMT.MIG under $root" }
    }
    return @{ Ok = $true; Root = $root; Error = "" }
}

function Get-StoredMigrations {
    <#
    .SYNOPSIS
        Lists the migration stores sitting in the store folder on a machine.
    .DESCRIPTION
        These are finished .MIG stores, not tooling - real captured user data
        that may not have been imported yet. Size and age come back with each
        one so the technician is deciding against facts rather than a folder
        name, because deleting the wrong one loses somebody's profile.
    #>
    param([Parameter(Mandatory)][string]$ComputerName)
    $pc   = $ComputerName.Trim()
    if (-not (Test-ValidComputerName $pc)) {
        return @{ Ok = $false; PC = $pc; Root = ""; Error = "not a valid computer name"; Stores = @(); Ignored = @() }
    }

    # A blank or stray store path would make the root a DRIVE ROOT, and every
    # folder on C: would then be listed as a deletable "migration store". The
    # setting comes out of a JSON file that anyone can edit, so it is checked
    # here rather than trusted.
    $sub = "$($Script:AppConfig.DefaultStorePath)".Trim().Trim('\')
    if ([string]::IsNullOrWhiteSpace($sub) -or $sub -match '^[A-Za-z]:$' -or $sub -match '[:*?"<>|]') {
        Write-CrashLog "Refusing to list stores: DefaultStorePath is '$($Script:AppConfig.DefaultStorePath)'"
        return @{ Ok = $false; PC = $pc; Root = ""; Error = "the configured store folder is not usable"; Stores = @(); Ignored = @() }
    }
    $root = if (Test-IsThisComputer $pc) { "C:\$sub" } else { "\\$pc\C`$\$sub" }

    # Test-Path returns false for an unreachable machine just as it does for a
    # missing folder, so check the share itself first - otherwise a PC that is
    # switched off reports as "nothing to clean up", which is a different thing
    # entirely and would hide leftovers.
    $probe = if (Test-IsThisComputer $pc) { "C:\" } else { "\\$pc\C`$" }
    try {
        if (-not (Test-Path $probe -ErrorAction Stop)) {
            return @{ Ok = $false; PC = $pc; Root = $root; Error = "not reachable"; Stores = @(); Ignored = @() }
        }
    } catch {
        return @{ Ok = $false; PC = $pc; Root = $root; Error = $_.Exception.Message; Stores = @(); Ignored = @() }
    }
    if (-not (Test-Path $root -ErrorAction SilentlyContinue)) {
        return @{ Ok = $true; PC = $pc; Root = $root; Error = ""; Stores = @(); Ignored = @() }
    }
    $out = @(); $ignored = @()
    foreach ($d in @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue)) {
        # Being in the store folder is NOT enough to be treated as a store. Only
        # a folder that really holds USMT\USMT.MIG is offered for deletion; the
        # old code listed every subfolder and would happily recurse-delete
        # anything a technician had parked in there.
        $chk = Test-StoreReadable $d.FullName
        if (-not $chk.Ok) {
            $ignored += @{ Name = $d.Name; Path = $d.FullName; Reason = $chk.Error }
            continue
        }
        $sz    = Get-StoreSizeOnDisk -StorePath $d.FullName
        $bytes = if ($sz) { [uint64]$sz.Bytes } else { [uint64]0 }
        $out += @{
            Name      = $d.Name
            Path      = $d.FullName
            Root      = $root
            Bytes     = $bytes
            Text      = (Format-Size $bytes)
            LastWrite = $d.LastWriteTime
            AgeDays   = [int]((Get-Date) - $d.LastWriteTime).TotalDays
        }
    }
    # @() matters: Sort-Object unwraps a single-element array, and the caller
    # reads .Count on this.
    return @{ Ok = $true; PC = $pc; Root = $root; Error = ""
              Stores = @($out | Sort-Object { $_.LastWrite }); Ignored = @($ignored) }
}

function Test-FolderWritable {
    <#
        Proves a folder can actually be written to, by writing to it.

        Test-Path only says the folder exists, and an existing folder you cannot
        write to is the exact case that matters here - a log folder on a share
        with read-only rights looks perfectly fine until USMT exits 13 partway
        through a capture. Writing and removing a probe file is the only answer
        that is not a guess about ACLs.
    #>
    param([string]$Path = "")
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) {
        try { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        catch { return $false }
    }
    $probe = Join-Path $Path "utw_write_test.tmp"
    try {
        "test" | Out-File -FilePath $probe -Encoding ascii -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Remove-EmptyStoreRoot {
    <#
        Removes the store FOLDER itself - "C:\USMT Profiles" - once the stores
        inside it have gone.

        Clean Up used to empty this folder and leave it sitting there, which
        looks like the clean up did not finish and leaves a folder on the root
        of C: on every machine the tool has ever touched.

        Deliberately narrow, because this is a path assembled from a setting and
        pointed at somebody else's machine:

          * the leaf must be exactly the configured store folder name, so a
            mistyped setting cannot aim it at "Users" or "Windows"
          * it must be directly under a drive root or an admin share, which is
            the only place this tool ever creates it
          * it must be EMPTY apart from empty sub-folders - one file and it
            stays, on the assumption that something is in there we did not put
            there and did not list

        Failing any of those is a normal, quiet outcome, not an error: the
        folder simply stays.
    #>
    param(
        [string]$Root = "",
        [string]$FolderName = ""
    )
    $r = "$Root".TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($r)) { return @{ Ok = $false; Removed = $false; Error = "empty path" } }
    if (-not $FolderName) { $FolderName = $Script:AppConfig.DefaultStorePath }
    if (-not $FolderName) { return @{ Ok = $false; Removed = $false; Error = "no store folder name configured" } }

    $leaf = Split-Path $r -Leaf
    if ($leaf -ine $FolderName) {
        Write-CrashLog "REFUSED to remove '$r' - leaf is not the store folder '$FolderName'"
        return @{ Ok = $false; Removed = $false; Error = "refused: '$leaf' is not the store folder" }
    }
    $parent = Split-Path $r -Parent
    $parentOk = ($parent -match '^[A-Za-z]:\\?$') -or ($parent -match '^\\\\[^\\]+\\[^\\]+\\?$')
    if (-not $parentOk) {
        Write-CrashLog "REFUSED to remove '$r' - parent '$parent' is not a drive or share root"
        return @{ Ok = $false; Removed = $false; Error = "refused: not directly under a drive root" }
    }
    if (-not (Test-Path -LiteralPath $r)) { return @{ Ok = $true; Removed = $false; Error = "" } }
    try {
        $left = @(Get-ChildItem -LiteralPath $r -Recurse -Force -File -ErrorAction Stop)
        if ($left.Count -gt 0) {
            return @{ Ok = $true; Removed = $false; Error = "$($left.Count) file(s) still in it" }
        }
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction Stop
        Write-CrashLog "Removed the empty store folder $r"
        return @{ Ok = $true; Removed = $true; Error = "" }
    } catch {
        return @{ Ok = $false; Removed = $false; Error = $_.Exception.Message }
    }
}

function Remove-StoredMigration {
    <#
        Recursive force-delete, so the target is re-proved here rather than
        trusted from the caller. Three conditions, all of which held when the
        list was built:

          * it is inside the store root it was listed under
          * it is not that root itself, and not a drive root
          * it still looks like a USMT store

        Re-checking is not paranoia about our own UI: the confirmation dialog
        gives the operator time to change something on disk, and this is the
        one call in the tool that destroys captured user data.
    #>
    param(
        # Not Mandatory: an empty path must come back as a refusal like every
        # other bad input. A binding exception here would abort the whole
        # delete loop partway through instead of skipping one entry.
        [string]$Path = "",
        # The root the path was LISTED under, from somewhere other than the path
        # itself. Deriving it as (Split-Path $Path -Parent) makes the containment
        # test below always true - it looks like a guard and refuses nothing.
        # Leave it empty when there is no independent root; the location and
        # store-shape checks still apply.
        [string]$ExpectedRoot = ""
    )
    $p = "$Path".TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($p)) { return @{ Ok = $false; Error = "empty path" } }
    # A drive root, a share root (\\pc\c$) or a UNC with nothing after the share.
    if ($p -match '^[A-Za-z]:$' -or $p -match '^\\\\[^\\]+\\[^\\]+$') {
        Write-CrashLog "REFUSED to delete '$p' - that is a drive or share root"
        return @{ Ok = $false; Error = "refused: '$p' is a drive or share root" }
    }
    # NEVER a place user data lives, whatever the caller believes.
    #
    # The store folder name comes out of an operator-editable JSON. Set
    # DefaultStorePath to "Users" and every store path this tool builds aims at
    # C:\Users\<name> - so the LOCATION is refused here, independently of
    # anything the caller passed. This does not depend on ExpectedRoot, which a
    # caller can weaken by deriving it from the path it is about to delete.
    $parentLeaf = "$(Split-Path $p -Parent)" -replace '.*\\', ''
    if ($parentLeaf -ieq 'Users' -or $p -imatch '\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)') {
        Write-CrashLog "REFUSED to delete '$p' - that is a system or user-profile location"
        return @{ Ok = $false; Error = "refused: '$p' is a system or user-profile location" }
    }
    if ($ExpectedRoot) {
        $r = "$ExpectedRoot".TrimEnd('\')
        if ($p -ieq $r -or -not $p.StartsWith("$r\", [StringComparison]::OrdinalIgnoreCase)) {
            Write-CrashLog "REFUSED to delete '$p' - outside the store root '$r'"
            return @{ Ok = $false; Error = "refused: outside the store folder" }
        }
    }
    $chk = Test-StoreReadable $p
    if (-not $chk.Ok) {
        Write-CrashLog "REFUSED to delete '$p' - no longer a USMT store ($($chk.Error))"
        return @{ Ok = $false; Error = "refused: not a USMT store ($($chk.Error))" }
    }
    try {
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
        Write-CrashLog "Removed old migration store $p"
        return @{ Ok = $true; Error = "" }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Remove-StagedTools {
    <#
    .SYNOPSIS
        Removes USMT_Temp from a machine, keeping its logs first.
    .DESCRIPTION
        The logs are the only reason the folder was left behind, so they are
        copied out before anything is deleted - otherwise cleaning up after a
        failure destroys the evidence of why it failed.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$LogFolder = ""
    )
    $pc  = $ComputerName.Trim()
    if (-not (Test-ValidComputerName $pc)) {
        return @{ PC = $pc; Ok = $false; Removed = $false; SavedLogs = 0; Error = "not a valid computer name" }
    }
    $unc = Get-StagedToolsPath $pc
    $savedLogs = 0

    # A direct-mode run that died leaves the temporary share behind too, and a
    # stale share is worse than useless: its old permissions get reused by the
    # next attempt. Take it off whether or not USMT_Temp is present.
    $shareRemoved = $false
    try {
        $s = Get-WmiObject -Class Win32_Share -ComputerName $pc `
                -Filter "Name='$($Script:DirectShareName)'" -ErrorAction SilentlyContinue
        if ($s) {
            $sharedPath = $s.Path
            [void]$s.Delete()
            $shareRemoved = $true
            Write-CrashLog "Removed leftover share $($Script:DirectShareName) on $pc"
            if ($sharedPath -match '^([A-Za-z]):') {
                Revoke-AllMachineAccess -FolderUNC ("\\$pc\" + ($sharedPath -replace '^([A-Za-z]):', '$1$'))
            }
        }
    } catch { Write-CrashLog "Share cleanup skipped on ${pc}: $($_.Exception.Message)" }

    if (-not (Test-Path $unc -ErrorAction SilentlyContinue)) {
        return @{ PC = $pc; Ok = $true; Removed = $shareRemoved; SavedLogs = 0
                  Error = $(if ($shareRemoved) { "" } else { "nothing staged" }) }
    }
    if ($LogFolder -and (Test-Path $LogFolder -ErrorAction SilentlyContinue)) {
        $remoteLogs = Join-Path $unc "Logs"
        if (Test-Path $remoteLogs -ErrorAction SilentlyContinue) {
            # Named for the machine it came off and when, so it is obvious later
            # what these are and which run they belong to.
            $dest = Join-Path $LogFolder "CleanUp_$(Get-SafeNamePart $pc)_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            try {
                if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
                $items = @(Get-ChildItem -Path $remoteLogs -File -ErrorAction SilentlyContinue)
                foreach ($i in $items) { Copy-Item -LiteralPath $i.FullName -Destination $dest -Force -ErrorAction SilentlyContinue }
                $savedLogs = $items.Count
            } catch { Write-CrashLog "Could not save logs from ${pc}: $($_.Exception.Message)" }
        }
    }
    try {
        Remove-Item -Path $unc -Recurse -Force -ErrorAction Stop
        Write-CrashLog "Manual cleanup removed $unc"
        return @{ PC = $pc; Ok = $true; Removed = $true; SavedLogs = $savedLogs; Error = "" }
    } catch {
        return @{ PC = $pc; Ok = $false; Removed = $false; SavedLogs = $savedLogs; Error = $_.Exception.Message }
    }
}

function Invoke-RemoteExport {
    <#
    .SYNOPSIS
        Full orchestration: stage tools, write batch, create + start task.
        Returns a monitoring hashtable for the GUI timer.
    #>
    param(
        [string]$SourcePC,
        [string]$LocalUSMTPath,
        [string]$Username,
        [bool]$AllProfiles,
        [bool]$ExcludeOneDrive,
        [int]$Verbosity,
        [bool]$Overwrite,
        [bool]$SettingsOnly = $false,
        [string]$StorePathOverride = "",   # e.g. \\DESTPC\UTWStore$\logang - store never lands on the source
        [string[]]$Extra = @(),            # expert-mode extra arguments
        [string]$ArgOverride = "",         # expert-mode: whole arg string, verbatim
        # Multi-user capture. Undeclared this silently became a one-user run.
        [string[]]$Usernames = @()
    )
    $unc  = Get-RemoteTempUNC $SourcePC
    $ts   = Get-Date -Format 'yyyyMMdd_HHmmss'
    # Source PC, not this workstation - the capture belongs to the machine being read.
    $user = Get-LogLabel -AllProfiles $AllProfiles -SettingsOnly $SettingsOnly -Username $Username -ComputerName $SourcePC

    # All remote-local paths (as seen from the source PC itself)
    $rUSMT     = $Script:RemoteTempLocal
    $rStore    = if ([string]::IsNullOrWhiteSpace($StorePathOverride)) {
                     "$($Script:RemoteTempLocal)\$($Script:RemoteStoreSub)"
                 } else { $StorePathOverride }
    $rLogs     = "$($Script:RemoteTempLocal)\Logs"
    $rLog      = "$rLogs\Export_${user}_${ts}.log"
    $rProgress = "$rLogs\Export_progress_${ts}.log"
    $rStdout   = "$rLogs\Export_stdout_${ts}.log"

    # UNC equivalents for log tailing from this machine
    $logUNC      = Join-Path $unc "Logs\Export_${user}_${ts}.log"
    $progressUNC = Join-Path $unc "Logs\Export_progress_${ts}.log"
    $stdoutUNC   = Join-Path $unc "Logs\Export_stdout_${ts}.log"
    $storeUNC    = Join-Path $unc $Script:RemoteStoreSub

    Copy-USMTToRemote -LocalUSMTPath $LocalUSMTPath -SourcePC $SourcePC | Out-Null

    # For settings-only mode, ensure MigratePublicFolders.xml is staged on remote
    if ($SettingsOnly) { Ensure-PublicFoldersXml $LocalUSMTPath | Out-Null }

    Write-RemoteBatchFile -SourcePC $SourcePC -RemoteUSMTPath $rUSMT -RemoteStorePath $rStore `
        -Username $Username -AllProfiles $AllProfiles -ExcludeOneDrive $ExcludeOneDrive `
        -Verbosity $Verbosity -Overwrite $Overwrite `
        -RemoteLogFile $rLog -RemoteProgressLog $rProgress -RemoteStdoutLog $rStdout `
        -SettingsOnly $SettingsOnly -Extra $Extra -ArgOverride $ArgOverride `
        -Usernames $Usernames

    $task = Start-RemoteScanTask -SourcePC $SourcePC -RemoteUSMTPath $rUSMT

    return @{
        Task          = $task           # for schtasks polling
        ProgressUNC   = $progressUNC   # tail in timer
        LogFileUNC    = $logUNC        # tail in timer
        StdoutUNC     = $stdoutUNC     # tail in timer
        LocalStoreUNC = $storeUNC      # robocopy source after task finishes (staged mode only)
        # True when scanstate wrote straight to the destination, so there is no
        # store on the source to copy and the robocopy phase is skipped entirely.
        DirectStore   = (-not [string]::IsNullOrWhiteSpace($StorePathOverride))
        StorePathUsed = $rStore
    }
}


function Write-RemoteImportBatchFile {
    <#
    .SYNOPSIS
        Writes a RunLoad.bat to the dest PC's USMT_Temp folder via UNC.
        Loadstate reads the store from a LOCAL path on the dest PC and restores
        the profile there. Running as SYSTEM gives full access to the user hive.
    #>
    param(
        [string]$DestPC,
        [string]$RemoteUSMTPath,    # local-on-dest, e.g. C:\Windows\Temp\USMT_Temp
        [string]$RemoteStorePath,   # local-on-dest store path, e.g. C:\USMT Profiles\logang
        [string]$Username,
        [bool]$AllProfiles,
        [int]$Verbosity,
        [string]$RemoteLogFile,
        [string]$RemoteProgressLog,
        [string]$RemoteStdoutLog,
        [bool]$SettingsOnly = $false,
        [string[]]$Extra    = @(),
        [string]$ArgOverride = "",
        # Multi-user restore, and restore-under-a-different-name (/mu). Both
        # were being passed by the caller and silently swallowed here, so a
        # remote rename restored the profile under the ORIGINAL name instead.
        [string[]]$Usernames = @(),
        [string]$RenameFrom  = "",
        [string]$RenameTo    = ""
    )
    # Same rule as the export side: presence checked over the UNC, path written
    # as the destination machine sees it. Loadstate is where V2V arbitration
    # fails, so Config.xml matters more here than anywhere else.
    $tempUNC = Get-RemoteTempUNC $DestPC
    $cfgArg = ""
    if (Test-Path (Join-Path $tempUNC "Config.xml") -ErrorAction SilentlyContinue) {
        $cfgArg = "$RemoteUSMTPath\Config.xml"
        Write-CrashLog "Config.xml found and added to loadstate args"
    } else {
        Write-CrashLog "WARNING: Config.xml not found in $tempUNC - error 72 (V2V arbitration) is likely. Place Config.xml in your USMT tools folder."
    }
    $pubArg = ""
    if ($SettingsOnly -and (Test-Path (Join-Path $tempUNC "MigratePublicFolders.xml") -ErrorAction SilentlyContinue)) {
        $pubArg = "$RemoteUSMTPath\MigratePublicFolders.xml"
    }

    $argStr = if ($ArgOverride) { $ArgOverride } else {
        Build-USMTArgs -Operation "Import" -StorePath $RemoteStorePath `
            -MigAppXml "$RemoteUSMTPath\migapp.xml" -MigUserXml "$RemoteUSMTPath\miguser.xml" `
            -PublicXml $pubArg -ConfigXml $cfgArg `
            -Username $Username -AllProfiles $AllProfiles -SettingsOnly $SettingsOnly `
            -Verbosity $Verbosity -Overwrite $false `
            -LogFile $RemoteLogFile -ProgressLog $RemoteProgressLog -Extra $Extra `
            -Usernames $Usernames -RenameFrom $RenameFrom -RenameTo $RenameTo
    }

    $batchContent = "@echo off`r`n`"$RemoteUSMTPath\loadstate.exe`" $argStr > `"$RemoteStdoutLog`" 2>&1`r`nexit /b %ERRORLEVEL%`r`n"

    $batchUNC = Join-Path (Get-RemoteTempUNC $DestPC) "RunLoad.bat"
    [System.IO.File]::WriteAllText($batchUNC, $batchContent, [System.Text.Encoding]::ASCII)
    Write-CrashLog "Wrote RunLoad.bat -> $batchUNC"
}

function Start-RemoteLoadTask {
    <#
    .SYNOPSIS
        Creates and immediately runs a one-shot SYSTEM loadstate task on the dest PC.
        Returns @{ PC; TaskName } for polling.
    #>
    param([string]$DestPC, [string]$RemoteUSMTPath)
    $ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
    $taskName = "USMT_Import_$ts"
    $batchLocal = "$RemoteUSMTPath\RunLoad.bat"

    Write-CrashLog "Creating import task '$taskName' on $DestPC"
    $createOut = & schtasks /create /s $DestPC /tn $taskName /tr `"$batchLocal`" /sc ONCE /st 00:00 /sd 01/01/2000 /ru SYSTEM /f 2>&1
    if ($LASTEXITCODE -ne 0) { throw "schtasks /create failed ($LASTEXITCODE): $createOut" }

    Write-CrashLog "Running import task '$taskName' on $DestPC"
    $runOut = & schtasks /run /s $DestPC /tn $taskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        & schtasks /delete /s $DestPC /tn $taskName /f 2>$null | Out-Null
        throw "schtasks /run failed ($LASTEXITCODE): $runOut"
    }
    return @{ PC = $DestPC; TaskName = $taskName }
}

function Invoke-RemoteImport {
    <#
    .SYNOPSIS
        Stages USMT tools on the dest PC, writes RunLoad.bat, creates + starts
        a loadstate scheduled task on that PC.
        The store must already exist at $RemoteStorePath (local path on dest PC).
        Returns a monitoring hashtable for the GUI timer Phase 3.
        DestStoreUNC is the \\PC\C$\... path of the store so Phase 3 can delete it
        after a successful loadstate.
    #>
    param(
        [string]$DestPC,
        [string]$LocalUSMTPath,
        [string]$RemoteStorePath,   # local path on dest PC, e.g. C:\USMT Profiles\logang
        [string]$DestStoreUNC,      # UNC of same path, for post-import cleanup
        [string]$Username,
        [bool]$AllProfiles,
        [int]$Verbosity,
        [bool]$SettingsOnly = $false,
        [string[]]$Extra = @(),            # expert-mode extra arguments
        [string]$ArgOverride = "",         # expert-mode: whole arg string, verbatim
        [string[]]$Usernames = @(),
        [string]$RenameFrom  = "",
        [string]$RenameTo    = ""
    )
    $unc  = Get-RemoteTempUNC $DestPC
    $ts   = Get-Date -Format 'yyyyMMdd_HHmmss'
    # Dest PC - loadstate is applying these profiles to that machine.
    $user = Get-LogLabel -AllProfiles $AllProfiles -SettingsOnly $SettingsOnly -Username $Username -ComputerName $DestPC

    $rUSMT     = $Script:RemoteTempLocal
    $rLogs     = "$($Script:RemoteTempLocal)\Logs"
    $rLog      = "$rLogs\Import_${user}_${ts}.log"
    $rProgress = "$rLogs\Import_progress_${ts}.log"
    $rStdout   = "$rLogs\Import_stdout_${ts}.log"

    $progressUNC = Join-Path $unc "Logs\Import_progress_${ts}.log"
    $logUNC      = Join-Path $unc "Logs\Import_${user}_${ts}.log"
    $stdoutUNC   = Join-Path $unc "Logs\Import_stdout_${ts}.log"

    # Stage USMT tools on dest PC
    Copy-USMTToRemote -LocalUSMTPath $LocalUSMTPath -SourcePC $DestPC | Out-Null

    # For settings-only mode, ensure MigratePublicFolders.xml is staged
    if ($SettingsOnly) { Ensure-PublicFoldersXml $LocalUSMTPath | Out-Null }

    Write-RemoteImportBatchFile -DestPC $DestPC -RemoteUSMTPath $rUSMT `
        -RemoteStorePath $RemoteStorePath -Username $Username -AllProfiles $AllProfiles `
        -Verbosity $Verbosity -RemoteLogFile $rLog -RemoteProgressLog $rProgress -RemoteStdoutLog $rStdout `
        -SettingsOnly $SettingsOnly -Extra $Extra -ArgOverride $ArgOverride `
        -Usernames $Usernames -RenameFrom $RenameFrom -RenameTo $RenameTo

    $task = Start-RemoteLoadTask -DestPC $DestPC -RemoteUSMTPath $rUSMT

    return @{
        Task         = $task
        ProgressUNC  = $progressUNC
        LogFileUNC   = $logUNC
        StdoutUNC    = $stdoutUNC
        DestPC       = $DestPC
        DestStoreUNC = $DestStoreUNC   # store to remove after successful loadstate
    }
}





# ---------------------------------------------------------------------------
#  CATCH-UP SYNC
#
#  The case this exists for: a profile was exported and imported days ago, the
#  person carried on using the OLD machine afterwards, and now the new PC is
#  missing whatever they did in between. USMT cannot answer this - a second
#  capture would overwrite the new machine wholesale, including everything done
#  on it since - so the question is not "migrate again" but "what is different,
#  and which of it do you want".
#
#  Robocopy answers exactly that. /L lists what it WOULD copy without copying
#  anything, and its default rule - newer or missing - is the definition of the
#  delta we are after. So the comparison and the copy are the same command run
#  twice, which means what the operator is shown and what actually happens
#  cannot drift apart.
# ---------------------------------------------------------------------------

# Junk that is different on every machine and wanted on none. Copying a browser
# cache over a working profile is at best pointless and at worst breaks the
# thing it lands on.
$Script:SyncExcludeDirs = @(
    "AppData\Local\Temp"
    "AppData\Local\Microsoft\Windows\INetCache"
    "AppData\Local\Microsoft\Windows\WebCache"
    "AppData\Local\Microsoft\Windows\Explorer"
    "AppData\Local\Google\Chrome\User Data\Default\Cache"
    "AppData\Local\Microsoft\Edge\User Data\Default\Cache"
    "AppData\Local\Packages"
    "AppData\Local\CrashDumps"
)
# NTUSER.DAT is the registry hive. It is locked while the account is signed in,
# it is meaningless on top of a different account's hive, and copying it is how
# a working profile gets destroyed. It is never in scope here.
$Script:SyncExcludeFiles = @(
    "ntuser.dat*", "ntuser.ini", "UsrClass.dat*", "desktop.ini", "thumbs.db"
    # Working files, not documents. Every one of these is written constantly by
    # something that is not the user, and they were the bulk of what came back
    # from the first real comparison - a few genuinely changed documents lost
    # among thousands of log lines nobody would ever choose to copy.
    "*.tmp", "*.temp", "*.log", "*.etl", "*.dmp", "*.old", "*.bak"
    "*.crdownload", "*.part", "*.partial", "~$*"
)

# WHAT "THE PROFILE" MEANS FOR A COMPARISON.
#
# Everything, was the first answer, and it was wrong in practice: a real pair of
# machines took 20-30 minutes and produced 5,000 differences, almost all of them
# AppData - caches, logs and settings files that programs rewrite every time
# they run. The handful of documents that actually mattered were buried.
#
# So the default is the folders a person keeps their own work in. It is both the
# useful answer and, by a wide margin, the fast one: AppData is where the file
# count lives, and not walking it is what turns half an hour into seconds.
$Script:SyncUserFolders = @(
    "Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos"
    "Favorites", "Links", "Contacts", "Searches"
)
# Roaming only, and only when asked for. AppData\Local is machine-specific by
# definition - caches, and per-install state that is meaningless on the other
# machine - so it is never included. Roaming is where a program keeps settings
# that are supposed to follow a person, which is occasionally what somebody is
# actually chasing.
$Script:SyncAppDataFolders = @("AppData\Roaming")
$Script:SyncIncludeAppData = $false

function Import-SyncRules {
    <#
        Replaces the lists above from UTW_SyncRules.json, if it is there.

        THE VALUES ABOVE REMAIN THE DEFAULTS. Every list here is site-specific -
        which folders hold real work, which caches are noise, which C: root
        folders are ordinary - and hard-coding them meant anyone whose estate
        differs had to edit the source and maintain a fork. As a data file they
        are configuration.

        Borrowed from BleachBit, which keeps 95 application cleaners as XML
        rather than code, so adding one needs no release and cannot break the
        engine.

        A missing file is normal. A malformed one is reported and then ignored:
        this decides what a comparison looks at, and falling back to values
        known to be sane is much better than starting from nothing because a
        comma was in the wrong place.
    #>
    param([string]$Path)
    if (-not $Path) {
        # $Script:ScriptDir is set by UTW-Main. This file is also dot-sourced on
        # its own - every test does it - so it falls back to its own folder
        # rather than throwing on a null path before the tool has even started.
        $dir = if ($Script:ScriptDir) { $Script:ScriptDir } else { $PSScriptRoot }
        if (-not $dir) { return $null }
        $Path = Join-Path $dir "UTW_SyncRules.json"
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-CrashLog "UTW_SyncRules.json could not be read, using built-in rules: $($_.Exception.Message)"
        return "could not be read - $($_.Exception.Message)"
    }
    # Each list is taken only if it is present AND non-empty. A key someone has
    # emptied out is far more likely to be a mistake than a request to compare
    # nothing at all.
    $map = @{
        userFolders     = "SyncUserFolders"
        appDataFolders  = "SyncAppDataFolders"
        excludeDirs     = "SyncExcludeDirs"
        excludeFiles    = "SyncExcludeFiles"
        rootFolderNoise = "RootFolderNoise"
    }
    foreach ($k in $map.Keys) {
        $v = @($j.$k | Where-Object { "$_".Trim() })
        if ($v.Count) { Set-Variable -Name $map[$k] -Value $v -Scope Script }
    }
    return $null
}
[void](Import-SyncRules)

function Get-ReachablePath {
    <#
        A path a remote machine reported, rewritten so THIS machine can open it.

        Win32_UserProfile reports LocalPath - the path as the machine that owns
        the profile sees it. That is "C:\Users\asmith" on the old PC and also
        "C:\Users\asmith" on the new one, so handing both to robocopy compared a
        folder with itself: two different computers, one string, and the
        comparison refused as "the source and the destination are the same
        folder". They are only distinguishable once the machine name is in the
        path.
    #>
    param([string]$ComputerName, [string]$LocalPath)
    if (-not $LocalPath) { return "" }
    if (Test-IsThisComputer $ComputerName) { return $LocalPath }
    # Already a UNC path - leave it alone rather than mangling it.
    if ($LocalPath -like "\\*") { return $LocalPath }
    return ($LocalPath -replace '^([A-Za-z]):', "\\$ComputerName\`$1`$")
}

function Get-ProfileFolderPath {
    <#
        The profile folder as THIS machine can reach it - local path when it is
        this PC, admin share when it is not.
    #>
    param([string]$ComputerName, [string]$UserFolder)
    if (-not $UserFolder) { return "" }
    return (Get-ReachablePath $ComputerName (Join-Path "C:\Users" $UserFolder))
}

function Get-ProfileNameMatches {
    <#
        Pairs up a profile on one machine with the likely same person on
        another, because the two are often not spelled the same.

        The real example: megant on the old PC, megans on the new one. A rename,
        a second account, a different naming standard - it happens often enough
        that requiring an exact match would make this feature useless, and
        guessing silently would be worse. So it SCORES the candidates and the
        operator confirms; nothing is chosen on its behalf.
    #>
    param([Parameter(Mandatory)][string]$SourceUser, [string[]]$Candidates)
    $s = "$SourceUser".ToLower()
    $out = @()
    foreach ($c in @($Candidates | Where-Object { $_ })) {
        $t = "$c".ToLower()
        $score = 0
        if ($t -eq $s)                                   { $score = 100 }
        elseif ($t.StartsWith($s) -or $s.StartsWith($t)) { $score = 80 }
        else {
            # Longest shared prefix, as a percentage of the longer name. megant
            # and megans share five of six characters and score 83; megant and
            # brianz share none and score 0.
            $n = [Math]::Min($s.Length, $t.Length); $i = 0
            while ($i -lt $n -and $s[$i] -eq $t[$i]) { $i++ }
            $longer = [Math]::Max($s.Length, $t.Length)
            if ($longer -gt 0 -and $i -ge 3) { $score = [int](100 * $i / $longer) }
        }
        $out += @{ Name = $c; Score = $score }
    }
    return @($out | Sort-Object { $_.Score } -Descending)
}

function Get-ProfileSyncPreview {
    <#
        What is on the old machine that the new one has not got, or has an older
        copy of. Nothing is written: robocopy runs with /L.

        Returns @{ Ok; Error; Source; Dest; Items; Truncated } where each item is
        @{ Class; Bytes; RelPath; Source; Dest }.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePC,
        [Parameter(Mandatory)][string]$SourceUser,
        [Parameter(Mandatory)][string]$DestPC,
        [Parameter(Mandatory)][string]$DestUser,
        [string[]]$Subfolders,
        [int]$MaxItems = 5000,
        # The folders, when they are not where the name says they should be.
        # A profile folder does not have to be C:\Users\<name> - it keeps the
        # name it was created with, so a renamed account or a second profile
        # ("megant.CONTOSO") lives somewhere the username cannot predict. The
        # caller reads the real path off Get-RemoteUserProfiles and passes it.
        [string]$SourcePath,
        [string]$DestPath,
        # Adds AppData\Roaming to the scope. Off by default because it is where
        # the noise and nearly all of the time is; on when somebody is chasing a
        # program's settings rather than a document.
        [switch]$IncludeAppData
    )
    foreach ($pc in @($SourcePC, $DestPC)) {
        if (-not (Test-ValidComputerName $pc)) { return @{ Ok = $false; Error = "'$pc' is not a valid computer name"; Items = @() } }
    }
    # CONVERTED HERE, not by the caller. SourcePath and DestPath are whatever
    # Get-RemoteUserProfiles reported, which is the path the OWNING machine
    # sees - so both sides read "C:\Users\asmith" and every caller would have to
    # remember to rewrite them. Doing it once, here, is the only way that cannot
    # be forgotten at one call site.
    $src = if ($SourcePath) { Get-ReachablePath $SourcePC $SourcePath } else { Get-ProfileFolderPath $SourcePC $SourceUser }
    $dst = if ($DestPath)   { Get-ReachablePath $DestPC   $DestPath }   else { Get-ProfileFolderPath $DestPC   $DestUser }
    if ($src -ieq $dst) { return @{ Ok = $false; Error = "the source and the destination are the same folder"; Items = @() } }
    if (-not (Test-Path -LiteralPath $src)) { return @{ Ok = $false; Error = "cannot read $src"; Items = @() } }
    if (-not (Test-Path -LiteralPath $dst)) { return @{ Ok = $false; Error = "cannot read $dst"; Items = @() } }

    # One robocopy per folder in scope. NOT one for the whole profile: an
    # explicit list is what keeps AppData out, and walking the profile root
    # would pull it straight back in.
    $roots = if ($Subfolders -and $Subfolders.Count) {
        $Subfolders
    } else {
        $list = @($Script:SyncUserFolders)
        if ($IncludeAppData -or $Script:SyncIncludeAppData) { $list += $Script:SyncAppDataFolders }
        $list
    }
    $items = @(); $truncated = $false; $problems = @()

    foreach ($sub in $roots) {
        $s = if ($sub) { Join-Path $src $sub } else { $src }
        $d = if ($sub) { Join-Path $dst $sub } else { $dst }
        if (-not (Test-Path -LiteralPath $s)) { continue }

        # /L        list only - this call must never write anything
        # /E        subdirectories, including empty ones
        # /XJ       DO NOT FOLLOW JUNCTIONS. A profile is full of them
        #           ("Application Data" -> AppData\Roaming) and they loop.
        # /FP /BYTES  full paths and raw numbers, so the output can be parsed
        # /NJH /NJS /NDL  no header, summary or directory lines - just files
        # /R:0 /W:0 never retry; a locked file is reported, not waited on
        # /XO EXCLUDE OLDER. This one is a safety rule, not a tidy-up.
        #
        # "Older" means the NEW machine has the more recent copy - somebody
        # edited it there after the migration, which is the normal and correct
        # state of things. Listing it as a difference invites an operator to
        # tick it and quietly overwrite the newer work with the older file. The
        # feature exists to carry changes FORWARD from the old PC; it must never
        # offer to carry them backwards, so those files are not collected at all.
        $args = @($s, $d, "/L", "/E", "/XJ", "/XO", "/FP", "/BYTES", "/NJH", "/NJS", "/NDL", "/NP", "/R:0", "/W:0")
        foreach ($x in $Script:SyncExcludeDirs)  { $args += @("/XD", (Join-Path $s $x)) }
        foreach ($x in $Script:SyncExcludeFiles) { $args += @("/XF", $x) }

        try {
            $out = & robocopy.exe @args 2>&1
        } catch {
            $problems += "robocopy failed on $s - $($_.Exception.Message)"
            continue
        }
        # ROBOCOPY'S EXIT CODE IS A BITMASK, NOT A VERDICT.
        #
        # 1 means "files were copied", 2 "extra files exist", 3 both - all
        # perfectly normal, and all non-zero. Left in $LASTEXITCODE it makes the
        # shell look like the last thing it did failed: the first run of this
        # under the test runner reported a failure while every single check
        # inside it had passed. It is read once, here, and cleared.
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        # 8 and above is a real failure; below that is robocopy's normal
        # "here is what I found" bitmask.
        if ($code -ge 8) { $problems += "robocopy reported errors reading $s (code $code)" }

        foreach ($line in $out) {
            $text = "$line"
            # Older is not in this list, and /XO above means it never arrives -
            # belt and braces on the one class of change that must not be copied.
            if ($text -notmatch '^\s*(New File|Newer|Changed)\s+(\d+)\s+(.+?)\s*$') { continue }
            $class = $Matches[1]; $bytes = [int64]$Matches[2]; $full = $Matches[3]
            $rel = $full
            if ($full.StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) {
                $rel = $full.Substring($s.Length).TrimStart('\')
                if ($sub) { $rel = Join-Path $sub $rel }
            }
            $items += @{
                Class  = $class
                Bytes  = $bytes
                RelPath= $rel
                Source = $full
                Dest   = (Join-Path $dst $rel)
            }
            if ($items.Count -ge $MaxItems) { $truncated = $true; break }
        }
        if ($truncated) { break }
    }

    return @{
        Ok        = $true
        Error     = ($problems -join "; ")
        Source    = $src
        Dest      = $dst
        Items     = @($items)
        Truncated = $truncated
        # What was actually looked at, so the operator is never left guessing
        # whether "nothing changed" means nothing changed or nothing was read.
        Scope     = @($roots)
    }
}

function Invoke-ProfileSyncCopy {
    <#
        Copies the items the operator ticked, one at a time, with robocopy.

        PER FILE ON PURPOSE. Re-running the directory-level command would copy
        everything it found, not the subset that was chosen, and the whole point
        of the review step is that the operator decides. Robocopy only works on
        directories, so each file is a one-file copy: source dir, dest dir, name.
    #>
    param(
        [Parameter(Mandatory)]$Items,
        # The profile folder everything must land inside. Required, because a
        # copy with no boundary is a copy that can go anywhere.
        [Parameter(Mandatory)][string]$DestRoot
    )
    $done = 0; $failed = 0; $bytes = 0; $errors = @()

    # THE BOUNDARY IS RE-PROVED HERE, at the point of writing.
    #
    # Every other destructive operation in this tool does the same and for the
    # same reason: the list was built before a dialog the operator may have sat
    # on, and the thing that acts on it must not trust that the list still says
    # what it said. The relative paths come from parsing robocopy's output, so a
    # path that escapes the profile - a "..", an absolute path where a relative
    # one was expected, a prefix strip that did not match - has to be refused
    # rather than copied to wherever it points.
    $rootFull = ""
    try { $rootFull = [System.IO.Path]::GetFullPath($DestRoot).TrimEnd('\') } catch { }
    if (-not $rootFull) {
        return @{ Ok = $false; Copied = 0; Failed = 0; Bytes = 0
                  Errors = @("refused: '$DestRoot' is not a usable destination folder") }
    }

    foreach ($it in @($Items)) {
        $destFull = ""
        try { $destFull = [System.IO.Path]::GetFullPath($it.Dest) } catch { }
        if (-not $destFull -or
            -not $destFull.StartsWith("$rootFull\", [StringComparison]::OrdinalIgnoreCase)) {
            Write-CrashLog "REFUSED to copy to '$($it.Dest)' - outside the destination profile '$rootFull'"
            $failed++; $errors += "$($it.RelPath) - refused, it points outside the profile folder"
            continue
        }
        $sDir = Split-Path $it.Source -Parent
        $dDir = Split-Path $it.Dest   -Parent
        $name = Split-Path $it.Source -Leaf
        try {
            $null = & robocopy.exe $sDir $dDir $name "/R:1" "/W:1" "/NJH" "/NJS" "/NP" "/NDL" 2>&1
            # Same bitmask, same clear - see Get-ProfileSyncPreview.
            $code = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            if ($code -ge 8) {
                $failed++; $errors += "$($it.RelPath) (code $code)"
            } else {
                $done++; $bytes += [int64]$it.Bytes
            }
        } catch {
            $failed++; $errors += "$($it.RelPath) - $($_.Exception.Message)"
        }
    }
    Write-CrashLog "Catch-up sync: copied $done item(s), $failed failed"
    return @{ Ok = ($failed -eq 0); Copied = $done; Failed = $failed; Bytes = $bytes; Errors = @($errors) }
}


# ---------------------------------------------------------------------------
#  PROGRAM INVENTORY
#
#  "What did the old machine have that the new one has not?" USMT does not move
#  applications - it never has - so after every migration somebody works this out
#  by opening Programs and Features on two machines and reading them side by
#  side. That is the list this builds.
# ---------------------------------------------------------------------------

# NOT Win32_Product. EVER.
#
# It is the obvious way to do this and it is a trap: enumerating that class makes
# the Windows Installer RECONFIGURE every MSI-installed product as it goes. It
# takes minutes, it writes thousands of event log entries, and it has been known
# to repair - or break - working installs on a machine somebody is standing at.
# Microsoft advise against it in their own documentation.
#
# The uninstall keys hold the same information, are what Programs and Features
# itself reads, and cost milliseconds.
$Script:UninstallKeys = @(
    "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

# Folders that live on the root of C: on every Windows machine. Anything ELSE
# down there was put on deliberately, and is worth a look - a surprising amount
# of line-of-business software still installs to C:\<vendor> and keeps its data
# there, which no migration and no program list would ever mention.
$Script:RootFolderNoise = @(
    "Windows", "Program Files", "Program Files (x86)", "ProgramData", "Users"
    "PerfLogs", "Recovery", "System Volume Information", '$Recycle.Bin'
    '$WinREAgent', '$SysReset', "OneDriveTemp", "Intel", "AMD", "NVIDIA"
    "Drivers", "Config.Msi", "Documents and Settings", "MSOCache"
    "Temp", "inetpub", "swsetup", "SWSetup", "Dell", "HP"
)

function Get-InstalledPrograms {
    <#
        Everything Programs and Features would show, read from the registry.

        Returns @{ Ok; Error; PC; Programs = @(@{ Name; Version; Publisher; Scope }) }
    #>
    param([Parameter(Mandatory)][string]$ComputerName)
    if (-not (Test-ValidComputerName $ComputerName)) {
        return @{ Ok = $false; Error = "'$ComputerName' is not a valid computer name"; Programs = @() }
    }
    $found = @{}
    try {
        $local = Test-IsThisComputer $ComputerName
        foreach ($hive in @("LocalMachine", "Users")) {
            $base = $null
            try {
                $base = if ($local) {
                    [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
                } else {
                    [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($hive, $ComputerName)
                }
            } catch {
                if ($hive -eq "LocalMachine") {
                    # Remote registry is a service, and it is disabled by default
                    # on client Windows. Saying so is far more use than "access
                    # denied" - it is a fixable thing, not a permissions maze.
                    return @{ Ok = $false; Programs = @()
                              Error = "cannot read the registry on $ComputerName - the Remote Registry service may be stopped" }
                }
                continue
            }
            # HKLM directly; HKU one level down, per signed-in user, for the
            # per-user installs that never appear under HKLM at all (Teams,
            # Chrome and most of what a person installs for themselves).
            $roots = if ($hive -eq "LocalMachine") { @("") } else {
                try { @($base.GetSubKeyNames() | Where-Object { $_ -match '^S-1-5-21-' -and $_ -notmatch '_Classes$' }) } catch { @() }
            }
            foreach ($r in $roots) {
                foreach ($k in $Script:UninstallKeys) {
                    $path = if ($r) { "$r\$k" } else { $k }
                    $key = $null
                    try { $key = $base.OpenSubKey($path) } catch { }
                    if (-not $key) { continue }
                    foreach ($sub in $key.GetSubKeyNames()) {
                        try {
                            $e = $key.OpenSubKey($sub)
                            if (-not $e) { continue }
                            $name = "$($e.GetValue('DisplayName'))".Trim()
                            if (-not $name) { continue }
                            # Patches, hotfixes and the hidden plumbing entries.
                            # Programs and Features hides these too; a list of
                            # 400 security updates is not a curated anything.
                            if ([int]("0" + "$($e.GetValue('SystemComponent'))") -eq 1) { continue }
                            if ("$($e.GetValue('ParentKeyName'))") { continue }
                            if ("$($e.GetValue('ReleaseType'))" -match 'Update|Hotfix|Security') { continue }
                            if ($name -match '^(Update|Hotfix|Security Update|Definition Update)\b') { continue }
                            if ($name -match '^KB\d{6,}') { continue }
                            $key2 = $name.ToLower()
                            if (-not $found.ContainsKey($key2)) {
                                $found[$key2] = @{
                                    Name      = $name
                                    Version   = "$($e.GetValue('DisplayVersion'))"
                                    Publisher = "$($e.GetValue('Publisher'))"
                                    Scope     = $(if ($hive -eq "Users") { "per user" } else { "all users" })
                                }
                            }
                        } catch { }
                    }
                }
            }
        }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message; Programs = @(); PC = $ComputerName }
    }
    return @{ Ok = $true; Error = ""; PC = $ComputerName
              Programs = @($found.Values | Sort-Object { $_.Name }) }
}

function Get-RootFolders {
    <#
        Folders on the root of C: that Windows did not put there.

        Software that installs to C:\<something> and keeps its data beside itself
        is invisible to everything else here: it is often not in the uninstall
        keys either, and it is never in a user profile. It is also exactly the
        kind of thing that is noticed weeks later.
    #>
    param([Parameter(Mandatory)][string]$ComputerName)
    if (-not (Test-ValidComputerName $ComputerName)) {
        return @{ Ok = $false; Error = "'$ComputerName' is not a valid computer name"; Folders = @() }
    }
    $root = if (Test-IsThisComputer $ComputerName) { "C:\" } else { "\\$ComputerName\C`$\" }
    try {
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop |
                  Where-Object { $Script:RootFolderNoise -notcontains $_.Name })
        $out = @()
        foreach ($d in $dirs) {
            $out += @{ Name = $d.Name; Path = "C:\$($d.Name)"; Modified = $d.LastWriteTime }
        }
        return @{ Ok = $true; Error = ""; Folders = @($out | Sort-Object { $_.Name }) }
    } catch {
        return @{ Ok = $false; Error = "cannot read $root - $($_.Exception.Message)"; Folders = @() }
    }
}

function Compare-MachinePrograms {
    <#
        What the old machine has that the new one does not.

        Matched on the display name with the version stripped off, because the
        same product reinstalled is usually a different build - "Google Chrome"
        against "Google Chrome" is the comparison anybody wants, not 118.0.1 
        against 121.0.6. A version difference is reported, not treated as
        missing.

        Returns @{ Ok; Error; Missing; Newer; SameCount; OldFolders; NewFolders;
                   MissingFolders }
    #>
    param([Parameter(Mandatory)][string]$OldPC, [Parameter(Mandatory)][string]$NewPC)
    $a = Get-InstalledPrograms -ComputerName $OldPC
    if (-not $a.Ok) { return @{ Ok = $false; Error = "$OldPC - $($a.Error)" } }
    $b = Get-InstalledPrograms -ComputerName $NewPC
    if (-not $b.Ok) { return @{ Ok = $false; Error = "$NewPC - $($b.Error)" } }

    $newBy = @{}
    foreach ($p in $b.Programs) { $newBy[$p.Name.ToLower()] = $p }

    $missing = @(); $differs = @(); $same = 0
    foreach ($p in $a.Programs) {
        $hit = $newBy[$p.Name.ToLower()]
        if (-not $hit) { $missing += $p }
        elseif ("$($hit.Version)" -ne "$($p.Version)") {
            $differs += @{ Name = $p.Name; Publisher = $p.Publisher; Version = $p.Version
                           Scope = $p.Scope; OtherVersion = $hit.Version }
        } else { $same++ }
    }

    # The root of C: as well. Reported separately: a folder is a hint that
    # something is installed, not proof, and it should not be mixed in with the
    # things the registry can actually vouch for.
    $of = Get-RootFolders -ComputerName $OldPC
    $nf = Get-RootFolders -ComputerName $NewPC
    $newNames = @($nf.Folders | ForEach-Object { $_.Name.ToLower() })
    $missingFolders = @($of.Folders | Where-Object { $newNames -notcontains $_.Name.ToLower() })

    return @{
        Ok = $true; Error = ""
        OldPC = $OldPC; NewPC = $NewPC
        Missing = @($missing); Differs = @($differs); SameCount = $same
        OldCount = @($a.Programs).Count; NewCount = @($b.Programs).Count
        MissingFolders = @($missingFolders)
        FolderError = @(@($of.Error), @($nf.Error) | Where-Object { $_ }) -join "; "
    }
}
