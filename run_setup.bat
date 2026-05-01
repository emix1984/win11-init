@echo off
chcp 65001 >nul
echo =========================================
echo    正在请求管理员权限并启动初始化脚本
echo =========================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_win11.ps1"
exit
