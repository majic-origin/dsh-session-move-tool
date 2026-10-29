@echo off
rem ===========================================================================
rem  DSH session tool - launcher
rem
rem  Double-click          -> interactive menu
rem  Drag a folder onto it -> list sessions of that workspace
rem  Command line          -> dsh-session.cmd -Repair   /  -Search gif  /  -Top 20
rem
rem  This file is pure ASCII on purpose: cmd.exe decodes a .bat with the OEM
rem  code page, so non-ASCII text here would be garbled. All Chinese output
rem  comes from dsh-session.ps1 (saved as UTF-8 with BOM).
rem
rem  The "keep window open" decision lives in dsh-session.ps1: it pauses for a
rem  keypress when run interactively (double-click / drag) and does NOT pause
rem  when stdin or stdout is redirected (pipe / batch). Only a hard failure is
rem  caught here, as a last resort.
rem ===========================================================================

setlocal
set "SCRIPT=%~dp0dsh-session.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo [ERROR] dsh-session.ps1 not found next to this launcher.
    echo         All three scripts must stay in the same folder.
    echo.
    pause
    exit /b 1
)

set "PS="
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PS=pwsh.exe"
if not defined PS (
    where powershell.exe >nul 2>nul
    if not errorlevel 1 set "PS=powershell.exe"
)
if not defined PS (
    echo.
    echo [ERROR] No PowerShell found on PATH.
    echo         Windows 10/11 ships powershell.exe - check your PATH.
    echo.
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [EXIT] dsh-session.ps1 ended with code %RC%
    echo.
    pause
)

exit /b %RC%
