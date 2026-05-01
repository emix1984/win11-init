<#
.SYNOPSIS
    Gotify daily server monitoring push script and installer v2.0.
.DESCRIPTION
    Improved version with top process tracking and multi-source IP detection.
#>

Param(
    [switch]$Install,
    [string]$GotifyUrl = $env:GOTIFY_URL,
    [string]$Device = $env:GOTIFY_DEVICE
)

# Configuration Defaults
if ([string]::IsNullOrWhiteSpace($GotifyUrl)) {
    $GotifyUrl = "https://gotify.lararu.dev/message?token=AnDQOf5fr5BIcaq"
}
if ([string]::IsNullOrWhiteSpace($Device)) {
    $Device = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "Win11lts-Envy" }
}

$ErrorActionPreference = "Stop"

# --- Module: Installation ---
if ($Install) {
    $SourceScript = $PSCommandPath
    $TargetDir = "C:\Windows\scripts"
    $ScriptPath = Join-Path -Path $TargetDir -ChildPath "dailyreport.ps1"

    if (-not (Test-Path -Path $TargetDir)) {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    }

    Write-Host "[INFO] Copying monitoring script to system directory..." -ForegroundColor Cyan
    Copy-Item -Path $SourceScript -Destination $ScriptPath -Force

    $TaskName = "Gotify_Daily_Health_Report"
    $Trigger = New-ScheduledTaskTrigger -Daily -At "00:00"
    # Repeat every 2 hours
    $Trigger.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition

    $ArgsStr = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -GotifyUrl `"$GotifyUrl`" -Device `"$Device`""
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $ArgsStr

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $TaskName -Trigger $Trigger -Action $Action -Description "Automated System Health Report" -User "SYSTEM" -RunLevel Highest | Out-Null

    Write-Host "[OK] Monitoring task registered (Every 2 Hours)." -ForegroundColor Green
    exit
}

# --- Module: Data Collection ---

# 1. System Uptime
$Uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$UptimeStr = "{0}d {1}h {2}m" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

# 2. Memory & CPU
$OS = Get-CimInstance Win32_OperatingSystem
$UsedMem = [Math]::Round(($OS.TotalVisibleMemorySize - $OS.FreePhysicalMemory) / 1MB, 2)
$TotalMem = [Math]::Round($OS.TotalVisibleMemorySize / 1MB, 2)
$CpuLoad = [Math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)

# 3. Disk Space (C:)
$Disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$FreeDisk = [Math]::Round($Disk.FreeSpace / 1GB, 2)
$TotalDisk = [Math]::Round($Disk.Size / 1GB, 2)

# 4. Top Processes (New Feature)
$TopProcesses = Get-Process | Sort-Object CPU -Descending | Select-Object -First 3 | ForEach-Object {
    "$($_.ProcessName) ($([Math]::Round($_.WorkingSet64 / 1MB, 1)) MB)"
}
$TopProcStr = $TopProcesses -join ", "

# 5. Public IP with Fallback (New Feature)
$IPSources = @("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")
$PublicIP = "Unknown"
foreach ($Source in $IPSources) {
    try {
        $PublicIP = (Invoke-RestMethod -Uri $Source -TimeoutSec 5).Trim()
        if ($PublicIP -match '^\d{1,3}(\.\d{1,3}){3}$') { break }
    } catch { continue }
}

# 6. Local IP Address (New Feature)
$LocalIPs = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
    $_.InterfaceAlias -match "Ethernet|Wi-Fi|vEthernet" -and 
    $_.IPAddress -notlike "169.254.*" 
}).IPAddress
$LocalIPStr = if ($LocalIPs) { $LocalIPs -join ", " } else { "Unknown" }

# --- Module: Reporting ---

$Title = "Health Report: $Device"
$Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$Msg = @"
### System Status (@ $Timestamp)
- **Uptime**: $UptimeStr
- **Public IP**: $PublicIP
- **Local IP**: $LocalIPStr

### Resource Usage
- **CPU**: $CpuLoad %
- **RAM**: $UsedMem / $TotalMem GB
- **Disk (C:)**: $FreeDisk / $TotalDisk GB Free

### Top Processes (by Memory)
$TopProcStr

---
*Automatic check-in complete.*
"@

$Body = @{
    title    = $Title
    message  = $Msg
    priority = 5
    extras   = @{ "client::display" = @{ "contentType" = "text/markdown" } }
} | ConvertTo-Json -Compress

try {
    Invoke-RestMethod -Uri $GotifyUrl -Method Post -Body $Body -ContentType "application/json; charset=utf-8"
} catch {
    $ErrLog = Join-Path -Path $PSScriptRoot -ChildPath "report_error.log"
    "[$Timestamp] Error: $_" | Out-File -FilePath $ErrLog -Append
}
