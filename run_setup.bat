@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

:: --- CONFIGURATION ---
:: Set DEBUG_MODE to 1 to show the console and pause for troubleshooting.
:: Set DEBUG_MODE to 0 to run silently in the background.
set DEBUG_MODE=0
:: ---------------------

:: Header (Only shown in Debug Mode)
if "%DEBUG_MODE%"=="1" (
    echo ============================================================
    echo    Windows 11 Headless Initialization Bootstrapper (v2.0)
    echo ============================================================
)

:: Admin Check
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] This script requires Administrative privileges.
    echo Please right-click and "Run as Administrator".
    pause
    exit /b 1
)

:: Execution Logic
if "%DEBUG_MODE%"=="1" (
    echo [INFO] Debug Mode: Visible execution...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_win11.ps1"
    echo.
    echo [FINISH] Deployment process ended. Check setup_win11.log for details.
    pause
) else (
    echo [INFO] Background Mode: Starting hidden process...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0setup_win11.ps1"
)

exit /b 0
