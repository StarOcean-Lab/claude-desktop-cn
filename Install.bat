@echo off
:: Claude Desktop Windows 3p Portable - Installer Launcher
:: Double-click this file to start the GUI installer.

:: Check if PowerShell is available
where powershell >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell not found. Please install PowerShell 5.1 or later.
    pause
    exit /b 1
)

:: Launch the installer with Bypass execution policy (no permanent system change)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"

if errorlevel 1 (
    echo.
    echo Installer exited with an error. Check the log above.
    pause
)
