@echo off
:: 设置控制台为 UTF-8 编码，防止中文乱码
chcp 65001 >nul

:: 检查是否具备管理员权限
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo =====================================================
    echo   请求管理员权限中... 请在弹出的窗口中点击 "是"
    echo =====================================================
    powershell Start-Process -FilePath '"%~0"' -Verb RunAs
    exit /b
)

:: 切换到脚本所在目录
cd /d "%~dp0"

echo =====================================================
echo         正在启动 Windows 11 初始化部署引擎
echo =====================================================
echo.

:: 绕过 PowerShell 执行策略限制，直接运行脚本
powershell -NoProfile -ExecutionPolicy Bypass -File "setup_win11.ps1"

echo.
echo =====================================================
echo 部署进程已结束，请查看上面的输出日志。
echo =====================================================
pause
