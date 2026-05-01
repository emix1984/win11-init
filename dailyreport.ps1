<#
.SYNOPSIS
    Gotify 每日服务器监控推送脚本及安装程序。

.DESCRIPTION
    运行 .\dailyreport.ps1 会立刻发送当前服务器的监控报告到 Gotify。
    运行 .\dailyreport.ps1 -Install 会将自身复制到 C:\Windows\scripts\ 并注册一个系统定时任务，使得每隔两小时自动报告一次。
#>

Param(
    [switch]$Install,
    [string]$GotifyUrl = $env:GOTIFY_URL,
    [string]$Device = $env:GOTIFY_DEVICE
)

# 提供默认值以便向后兼容
if ([string]::IsNullOrWhiteSpace($GotifyUrl)) {
    $GotifyUrl = "https://gotify.lararu.dev/message?token=AnDQOf5fr5BIcaq"
}
if ([string]::IsNullOrWhiteSpace($Device)) {
    $Device = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "Win11lts-envy" }
}

$ErrorActionPreference = "Stop"

# ==========================================
# 步骤 A：如果是带有 -Install 参数的执行，则进入安装过程
# ==========================================
if ($Install) {
    # 获取当前执行的脚本自己的绝对路径
    $SourceScript = $PSCommandPath

    if (-not (Test-Path -Path $SourceScript)) {
        Write-Warning "无法定位当前脚本自身。"
        exit
    }

    # 目标存放目录与路径
    $TargetDir = "C:\Windows\scripts"
    $ScriptPath = Join-Path -Path $TargetDir -ChildPath "dailyreport.ps1"

    # 1. 检查并创建目录
    if (-not (Test-Path -Path $TargetDir)) {
        Write-Host "检测到目标目录 $TargetDir 不存在，正在创建..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    }

    # 2. 复制当前脚本到系统目录 (允许覆盖)
    Write-Host "正在将自身复制至: $ScriptPath" -ForegroundColor Cyan
    Copy-Item -Path $SourceScript -Destination $ScriptPath -Force

    # 3. 注册系统任务计划
    $TaskName = "Gotify_Daily_Health_Report"

    # 定义触发器：从每天 00:00 开始，每隔 2 小时重复一次（偶数时间）
    $Trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
    $Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
    $Trigger.Repetition = $Repetition

    # 定义操作：静默运行新位置的 PowerShell 脚本，并将当前配置通过参数传入
    $ArgsStr = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -GotifyUrl `"$GotifyUrl`" -Device `"$Device`""
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $ArgsStr

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host "任务 [$TaskName] 已存在，正在覆盖更新..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $TaskName -Trigger $Trigger -Action $Action -Description "每天偶数时间推送系统健康报告到 Gotify" -User "SYSTEM" -RunLevel Highest | Out-Null

    Write-Host "✅ 安装与任务设定成功！" -ForegroundColor Green
    Write-Host "新脚本已停靠在: $ScriptPath`n每天每隔 2 小时（偶数整点）将自动运行。" -ForegroundColor Cyan

    # 安装完成后退出，不再执行下方的实际推送逻辑
    exit
}

# ==========================================
# 步骤 B：非安装模式，执行原有的收集数据和推送的报告逻辑
# ==========================================

# --- 配置 ---
# $GotifyUrl 和 $Device 现在由 Param 块处理，支持参数和环境变量输入

# --- 1. 获取运行时间 ---
$Uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$UptimeStr = "{0}天 {1}小时 {2}分钟" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

# --- 2. 获取内存信息 ---
$OS = Get-CimInstance Win32_OperatingSystem
$UsedMem = [Math]::Round(($OS.TotalVisibleMemorySize - $OS.FreePhysicalMemory) / 1MB, 2)
$TotalMem = [Math]::Round($OS.TotalVisibleMemorySize / 1MB, 2)

# --- 3. 获取磁盘空间 (C盘) ---
$Disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$FreeDisk = [Math]::Round($Disk.FreeSpace / 1GB, 2)
$TotalDisk = [Math]::Round($Disk.Size / 1GB, 2)

# --- 4. 获取 CPU 负载 (WMI/CIM 更稳定，不受系统语言包影响) ---
$CpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$CpuLoad = [Math]::Round($CpuLoad, 1)

# --- 5. 获取公网 IP ---
$PublicIP = try { (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5) } catch { "获取失败" }

# --- 构建消息内容 ---
$Title = "📊 $Device 每日健康报"
$Msg = @"
⏰ 报告时间: $(Get-Date -Format 'HH:mm:ss')
⏱️ 已连续运行: $UptimeStr
🌐 当前公网 IP: $PublicIP

💻 系统资源占用:
- CPU 负载: $CpuLoad %
- 内存使用: $UsedMem / $TotalMem GB
- C 盘剩余: $FreeDisk / $TotalDisk GB

✅ 系统自检完成，目前运行平稳。
"@

# --- 发送请求 ---
$Body = @{
    title    = $Title
    message  = $Msg
    priority = 5
} | ConvertTo-Json -Compress

try {
    Invoke-RestMethod -Uri $GotifyUrl -Method Post -Body $Body -ContentType "application/json; charset=utf-8"
} catch {
    "Error at $(Get-Date): $_" | Out-File -FilePath "$PSScriptRoot\report_error.log" -Append
}
