@echo off
setlocal
title User Transfer Wizard

REM ===========================================================================
REM  Double-click this. It asks for administrator rights itself.
REM
REM  It used to just run the script, which meant right-clicking and choosing
REM  "Run as administrator" every single time - and forgetting to left the tool
REM  half-working, because reading another machine's profiles needs admin.
REM
REM  ADMIN IS NOT FORCED. Plenty of what this tool does works without it -
REM  looking at this PC's own profiles, extracting a .MIG file, reading a store,
REM  reviewing settings - and the window says so in its header when it is not
REM  elevated. So a declined UAC prompt offers to carry on rather than closing.
REM
REM    UTW-Launcher.bat            ask for admin, offer to continue without
REM    UTW-Launcher.bat /noadmin   do not ask at all
REM
REM  Nothing is compiled. A packed PowerShell executable is one of the oldest
REM  antivirus heuristics there is, and this has to run on managed machines
REM  with endpoint protection watching. A batch file calling powershell.exe is
REM  boring, which is exactly what you want here.
REM ===========================================================================

if not exist "%~dp0UTW-Main.ps1" (
    echo.
    echo   UTW-Main.ps1 was not found beside this launcher.
    echo   Keep all the tool's files together in one folder.
    echo.
    pause
    exit /b 1
)

REM --- /noadmin: skip the whole question. ----------------------------------
if /i "%~1"=="/noadmin" goto :run
if /i "%~1"=="-noadmin" goto :run

REM --- Already elevated? "net session" only succeeds as administrator. ------
net session >nul 2>&1
if %errorlevel% equ 0 goto :run

REM --- Not elevated: ask. --------------------------------------------------
REM  The second argument marks the relaunch as already-asked, so a declined
REM  prompt in the elevated copy cannot start the question over.
echo Requesting administrator rights...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Start-Process -FilePath '%~f0' -ArgumentList '/noadmin' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if %errorlevel% equ 0 exit /b

REM --- Declined, or no rights available on this account. -------------------
echo.
echo   Administrator rights were not granted.
echo.
echo   Without them the tool cannot reach another machine, stage USMT on it,
echo   or delete a profile. It CAN still work on this PC's own profiles,
echo   extract a .MIG file, browse a store and change its settings.
echo.
choice /C YN /N /M "   Start anyway, without administrator rights? [Y/N] "
if errorlevel 2 exit /b
echo.

:run
REM --- Launch the GUI and close this window. -------------------------------
REM  The console is not kept open: the tool writes its own log and shows its
REM  own errors, and a black window behind the GUI for a whole migration only
REM  invites somebody to close it.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0UTW-Main.ps1"
exit /b
