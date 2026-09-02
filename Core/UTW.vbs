Option Explicit

' ===========================================================================
'  User Transfer Wizard - double-click launcher
'
'  Does the same job as UTW-Launcher.bat, with no console window at all: no
'  black flash, and no console-level "the publisher could not be verified"
'  step when it is started straight off a mapped drive or a \\server\share.
'
'  It asks for administrator rights. A declined prompt offers to carry on
'  without them, exactly like the .bat - plenty of the tool works unelevated
'  (this PC's own profiles, extracting a .MIG, reading a store, settings) and
'  the window says so in its header when it is not elevated.
'
'      UTW.vbs             ask for admin, offer to continue without
'      UTW.vbs /noadmin    do not ask at all
'
'  Nothing is compiled. This starts powershell.exe with -File and a local
'  path, which is about as ordinary as a launch gets - the same reasoning as
'  the .bat, which the header there explains.
' ===========================================================================

Const TITLE = "User Transfer Wizard"

Dim fso, sh, shellApp
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
Set shellApp = CreateObject("Shell.Application")

' --- Where this file lives, expressed so an elevated copy can still reach it -
Dim here, ps1
here = ToUNC(fso.GetParentFolderName(WScript.ScriptFullName))
ps1  = here & "\UTW-Main.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "UTW-Main.ps1 was not found next to this launcher." & vbCrLf & vbCrLf & _
           "Keep all of the tool's files together in one folder.", _
           vbExclamation, TITLE
    WScript.Quit 1
End If

' --- /noadmin: skip the whole question -------------------------------------
Dim noAdmin, i
noAdmin = False
For i = 0 To WScript.Arguments.Count - 1
    If LCase(WScript.Arguments(i)) = "/noadmin" Or LCase(WScript.Arguments(i)) = "-noadmin" Then noAdmin = True
Next

' --- The command the GUI is actually started with (matches UTW-Launcher.bat) -
Dim psArgs
psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"

' --- Already elevated, or told not to bother: just run it ------------------
If noAdmin Or IsElevated() Then
    sh.Run "powershell.exe " & psArgs, 0, False
    WScript.Quit 0
End If

' --- Not elevated: ask ----------------------------------------------------
On Error Resume Next
shellApp.ShellExecute "powershell.exe", psArgs, here, "runas", 0
If Err.Number = 0 Then
    On Error GoTo 0
    WScript.Quit 0
End If
Err.Clear
On Error GoTo 0

' --- Declined, or this account has no rights to grant --------------------
Dim answer
answer = MsgBox( _
    "Administrator rights were not granted." & vbCrLf & vbCrLf & _
    "Without them the tool cannot reach another machine, stage USMT on it, or " & _
    "delete a profile. It can still work on this PC's own profiles, extract a " & _
    ".MIG file, browse a store and change its settings." & vbCrLf & vbCrLf & _
    "Start anyway, without administrator rights?", _
    vbQuestion + vbYesNo + vbDefaultButton2, TITLE)

If answer = vbYes Then sh.Run "powershell.exe " & psArgs, 0, False

WScript.Quit 0

' ===========================================================================

Function IsElevated()
    ' HKU\S-1-5-19 is the LocalService hive - only administrators can read it.
    Dim s : Set s = CreateObject("WScript.Shell")
    On Error Resume Next
    s.RegRead "HKEY_USERS\S-1-5-19\Environment\TEMP"
    IsElevated = (Err.Number = 0)
    Err.Clear
    On Error GoTo 0
End Function

Function ToUNC(path)
    ' A launcher run from a mapped drive (Z:\...) would hand an elevated copy a
    ' drive letter it cannot see - elevated logon sessions do not inherit
    ' mapped drives. Swap a network drive letter for its \\server\share form.
    ToUNC = path
    On Error Resume Next
    Dim f : Set f = CreateObject("Scripting.FileSystemObject")
    Dim dl : dl = f.GetDriveName(path)
    If Len(dl) = 2 Then
        Dim dr : Set dr = f.GetDrive(dl)
        If dr.DriveType = 3 And Len(dr.ShareName) > 0 Then
            ToUNC = dr.ShareName & Mid(path, 3)
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Function
