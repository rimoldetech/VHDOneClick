@echo off
:: Check for Admin rights (Required for mounting disks)
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell.exe -ExecutionPolicy Bypass -File "%~dp0VHDOneClick-Main.ps1"
) else (
    echo [ERROR] This script must be "Run as Administrator".
    pause
)