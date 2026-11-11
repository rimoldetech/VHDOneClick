@echo off
:: Thin launcher for running the scripts directly. The release exe does not use this.
:: fltmc needs admin and works even when the Server service is disabled (net session does not).
setlocal
fltmc >nul 2>&1
if errorlevel 1 (
    echo [ERROR] This must be run as Administrator.
    echo         Right-click VHDOneClick-Entrypoint.bat and choose "Run as administrator".
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VHDOneClick-Main.ps1" %*
exit /b %errorlevel%
