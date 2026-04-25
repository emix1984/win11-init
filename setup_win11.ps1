#Requires -RunAsAdministrator

<#
.SYNOPSIS
    初始化 Windows 11 环境：安装 OpenSSH，创建用户，配置防火墙、RDP、电源策略、杀毒防御与包管理器。
.DESCRIPTION
    采用模块化编程模式重构，将各项功能独立封装为函数，整合所有高效生产环境必需的基础基建。
#>

# ==========================================
# 准备阶段：通用工具与变量
# ==========================================

# 全局错误追踪标志
$global:ErrorsFound = $false

# 打印带颜色的信息
function Write-Color {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}


# ==========================================
# 模块一：OpenSSH 服务管理
# ==========================================
function Install-OpenSSH {
    Write-Color "`n[1/9] 正在安装 OpenSSH 服务和相关组件..." "Yellow"
    try {
        $sshState = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        if ($sshState.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop | Out-Null
        }
        Start-Service sshd -ErrorAction Stop
        Set-Service -Name sshd -StartupType 'Automatic' -ErrorAction Stop

        if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction Stop | Out-Null
        }
        Write-Color " -> OpenSSH 服务安装与启动成功。" "Green"
    } catch {
        Write-Color " -> [异常] 安装/启动 OpenSSH 服务失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}

function Optimize-SSHConfig {
    Write-Color "`n[2/9] 正在优化 SSH 体验配置 (替换为 PowerShell & Keep-Alive)..." "Yellow"
    try {
        $DefaultShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value $DefaultShell -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
        
        $sshConfigFile = "C:\ProgramData\ssh\sshd_config"
        if (Test-Path $sshConfigFile) {
            $configContent = Get-Content $sshConfigFile
            $configContent = $configContent -replace "^\s*#?ClientAliveInterval\s+.*", "ClientAliveInterval 60"
            $configContent = $configContent -replace "^\s*#?ClientAliveCountMax\s+.*", "ClientAliveCountMax 3"
            $configContent = $configContent -replace "^(#?)(Match Group administrators)", "#`$2"
            $configContent = $configContent -replace "^(#?)(\s*AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)", "#`$2"
            $configContent | Set-Content $sshConfigFile -Force
            Restart-Service sshd -ErrorAction SilentlyContinue
        }
        Write-Color " -> SSH 体验优化和 Keep-Alive 配置已应用。" "Green"
    } catch {
        Write-Color " -> [异常] 优化 SSH 配置失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块二：账户与权限管理
# ==========================================
function Setup-SSHUser {
    param([string]$Username, [string]$PasswordString)
    Write-Color "`n[3/9] 正在配置统管本地用户: '$Username'..." "Yellow"
    try {
        $SecurePassword = ConvertTo-SecureString $PasswordString -AsPlainText -Force
        if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
            Write-Color " -> 用户 '$Username' 已存在，正在更新为其重置密码..." "Cyan"
            Get-LocalUser -Name $Username | Set-LocalUser -Password $SecurePassword -ErrorAction Stop
        } else {
            New-LocalUser -Name $Username -Password $SecurePassword -FullName "SSH Access" -Description "用于 SSH 远程访问" -PasswordNeverExpires -ErrorAction Stop | Out-Null
        }
        Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction SilentlyContinue | Out-Null
        Write-Color " -> 用户 '$Username' 账户状态已就绪 (归属 Administrators 组)。" "Green"
    } catch {
        Write-Color " -> [异常] 配置本地用户失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块三：网络与防火墙策略
# ==========================================
function Configure-Firewall {
    Write-Color "`n[4/9] 正在爆发式配置防火墙策略 (开启全端口)..." "Yellow"
    try {
        Remove-NetFirewallRule -DisplayName "ALLOW ALL INBOUND" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "ALLOW ALL INBOUND" -Direction Inbound -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        Write-Color " -> 警告：已强制放行所有入站网络流量！" "Red"
    } catch {
        Write-Color " -> [异常] 配置防火墙规则失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块四：系统电源与休眠策略
# ==========================================
function Optimize-PowerSettings {
    Write-Color "`n[5/9] 正在封锁睡眠策略 (确保挂机环境不掉线)..." "Yellow"
    try {
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c *>&1 | Out-Null
        powercfg /x -standby-timeout-ac 0
        powercfg /x -standby-timeout-dc 0
        powercfg /x -hibernate-timeout-ac 0
        powercfg /x -hibernate-timeout-dc 0
        powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
        powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
        powercfg /setactive SCHEME_CURRENT | Out-Null
        Write-Color " -> 高性能配置已下发，已切断系统环境休眠及笔记本合盖影响！" "Green"
    } catch {
        Write-Color " -> [异常] 调整电源策略失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块五：远程桌面 (RDP) 救砖通道
# ==========================================
function Enable-RemoteDesktop {
    Write-Color "`n[6/9] 正在部署图形化远程控制 (Windows RDP)..." "Yellow"
    try {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -value 0
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
        Write-Color " -> 远程桌面服务已强制开启，3389 端口放行成功。" "Green"
    } catch {
        Write-Color " -> [异常] 开启远程桌面失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块六：禁用 Windows Defender 安全中心
# ==========================================
function Disable-WindowsDefender {
    Write-Color "`n[7/9] 正在瘫痪 Windows Defender 杀毒防御层 (高危)..." "Yellow"
    try {
        if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
            # 1. 尝试直接禁用实时扫描、行为监控与网络拦截
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
            
            # 2. 极致防误杀终极方案：将整个 C 盘根目录及其子目录加入排除名单 (即使防篡改开启，这也极其有效)
            Add-MpPreference -ExclusionPath "C:\" -ErrorAction SilentlyContinue
            
            # 3. 尝试通过组策略彻底干掉 Defender 引擎
            $WD_Policy_Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
            if (!(Test-Path $WD_Policy_Path)) { New-Item -Path $WD_Policy_Path -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $WD_Policy_Path -Name "DisableAntiSpyware" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null

            Write-Color " -> 杀毒引流成功：核心全盘 C: 已脱离监控，实时防御阻隔尝试下发！" "Green"
            Write-Color "    (提示：Windows 11 若有残留拦截，需去界面手动关闭一次『防篡改保护』)" "Cyan"
        } else {
            Write-Color " -> 系统未检测到 Defender 核心组件(或已被精简)，跳过瘫痪注入。" "Green"
        }
    } catch {
        Write-Color " -> [异常] 瘫痪 Defender 进程失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块七：系统减负优化 (核心拦截策略)
# ==========================================
function Optimize-SystemDebloat {
    Write-Color "`n[8/9] 正在减负并清扫环境障碍 (清休眠,解UAC,放行脚本...)" "Yellow"
    try {
        powercfg /h off | Out-Null
        Set-ItemProperty -Path REGISTRY::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System -Name ConsentPromptBehaviorAdmin -Value 0
        Set-ItemProperty -Path REGISTRY::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System -Name PromptOnSecureDesktop -Value 0
        
        try { Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop } catch { Write-Color " -> [提示] Powershell 策略已被更高级别(如组策略)锁定，维持原状..." "Cyan" }

        $WU_AU_Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
        if (!(Test-Path $WU_AU_Path)) { New-Item -Path $WU_AU_Path -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $WU_AU_Path -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

        Write-Color " -> 空间已释放，环境已提纯，无烦人系统级干扰！" "Green"
    } catch {
        Write-Color " -> [异常] 系统减负清扫失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块八：软件环境接管 (Chocolatey & 工具链)
# ==========================================
function Install-PackageManager {
    Write-Color "`n[9/9] 正在构建全局软件生态源工具 (Chocolatey & Curl)..." "Yellow"
    try {
        # 1. 部署 Chocolatey
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Color " -> 检测到已存在 Chocolatey 包环境，跳过安装。" "Cyan"
        } else {
            $env:chocolateyUseWindowsCompression = 'false'
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) *>&1 | Out-Null
            # 刷新当前环境变量以便马上能用 choco
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        }

        # 2. 静默安装最新原版 curl 工具
        Write-Color " -> 正在调用 Choco 安装/更新原生 curl..." "Cyan"
        choco install curl -y --no-progress *>&1 | Out-Null

        # 3. 剥离微软瞎改的 curl 别名，还原本味 (写入全部用户的 PowerShell Profile)
        $globalProfile = $PROFILE.AllUsersAllHosts
        if (!(Test-Path (Split-Path $globalProfile))) { New-Item -ItemType Directory -Path (Split-Path $globalProfile) -Force -ErrorAction SilentlyContinue | Out-Null }
        if (!(Test-Path $globalProfile)) { New-Item -ItemType File -Path $globalProfile -Force -ErrorAction SilentlyContinue | Out-Null }
        
        $profileContent = Get-Content $globalProfile -Raw -ErrorAction SilentlyContinue
        if ($null -eq $profileContent -or $profileContent -notmatch "Remove-Item Alias:curl") {
            Add-Content -Path $globalProfile -Value "`r`n# Restoring native curl behavior`r`nRemove-Item Alias:curl -ErrorAction SilentlyContinue" -Encoding UTF8
        }
        
        Write-Color " -> Chocolatey 安装完毕！原生 Curl 已夺回控制权！" "Green"
    } catch {
        Write-Color " -> [异常] 部署包管理源与工具失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 模块九：每日服务器健康监控广播
# ==========================================
function Install-DailyReport {
    Write-Color "`n[10/10] 正在挂载 Gotify 每日定时监控报告生态..." "Yellow"
    try {
        $DailyReportPath = Join-Path -Path $PSScriptRoot -ChildPath "dailyreport.ps1"
        if (Test-Path $DailyReportPath) {
            & $DailyReportPath -Install | Out-Null
            Write-Color " -> Gotify 监控端已成功驻留！任务引擎接管偶数时段扫描。" "Green"
        } else {
            Write-Color " -> [提示] 未检测到 dailyreport.ps1 伴随安装包，将跳过其部署。" "Cyan"
        }
    } catch {
        Write-Color " -> [异常] 部署 Gotify 服务端节点失败: $_" "Red"
        $global:ErrorsFound = $true
    }
}


# ==========================================
# 结尾模块：系统环境基准自检
# ==========================================
function Verify-SystemHealth {
    Write-Color "`n[+] =========================================" "Cyan"
    Write-Color "[+] 平台模块基准考核最终确认 (Health Check)..." "Cyan"
    Start-Sleep -Seconds 1 
    
    $VerificationFailed = $false
    
    # Check 1: SSH Service
    if ((Get-Service -Name sshd -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Color " [PASS] OpenSSH 核心服务稳定运行。" "Green"
    } else { Write-Color " [FAIL] OpenSSH 服务异常宕机。" "Red"; $VerificationFailed = $true }

    # Check 2: User Status
    if (Get-LocalUser -Name "user" -ErrorAction SilentlyContinue) {
        Write-Color " [PASS] 最高权限账户 'user' 有效。" "Green"
    } else { Write-Color " [FAIL] 目标账户异常。" "Red"; $VerificationFailed = $true }

    # Check 3: RDP Port
    $rdpReg = Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -ErrorAction SilentlyContinue
    if ($rdpReg -and $rdpReg.fDenyTSConnections -eq 0) {
        Write-Color " [PASS] 图形化远程桌面系统接通。" "Green"
    } else { Write-Color " [FAIL] RDP 服务接入异常。" "Red"; $VerificationFailed = $true }
    
    # Check 4: Chocolatey
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Color " [PASS] Chocolatey 取包通道健康！" "Green"
    } else { Write-Color " [WARN] Chocolatey (choco) 环境尚未加载可用。" "Yellow" }
    
    # Check 5: Defender
    if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
        $dfCheck = Get-MpPreference -ErrorAction SilentlyContinue
        if ($dfCheck -and ($dfCheck.DisableRealtimeMonitoring -eq $true -or "C:\" -in $dfCheck.ExclusionPath)) {
            Write-Color " [PASS] Defender 瘫痪/豁免机制已确认生效。" "Green"
        } else { Write-Color " [WARN] Defender 可能正在顽固抵抗拦截 (防篡改开启中)。" "Yellow" }
    } else {
        Write-Color " [PASS] 系统中未检出 Defender 组件，绝对免疫。" "Green"
    }

    return $VerificationFailed
}


# ==========================================
# 生产总线引擎 (Main Flow)
# ==========================================
function Main {
    # 欢迎页与清单预览
    Write-Color "==========================================================" "Cyan"
    Write-Color "     Windows 11 无头自动部署基建包     " "Cyan"
    Write-Color "==========================================================" "Cyan"
    Write-Color "本引擎已被扩容至 10 个流水环节，火力全开自动部署：" "Yellow"
    Write-Color " [1~3] 部署核心级 OpenSSH、优化控制端、挂载超管账户" "Yellow"
    Write-Color " [4~6] 无痕拆毁防火墙、永恒禁止休眠掉线、开通强直连 RDP" "Yellow"
    Write-Color " [7~9] 强杀 Defender、根除所有 UAC 及休眠干扰、预装 Choco" "Yellow"
    Write-Color " [10]  静默灌入 Gotify 每日健康状态汇报监控程序" "Yellow"
    
    # 授权启动
    Write-Color "==========================================================" "Cyan"
    Write-Color "`n>>> [自动模式开启] 轰击指令下发，开始重构环境..." "Cyan"
    
    # 流水线队列
    Install-OpenSSH
    Optimize-SSHConfig
    Setup-SSHUser -Username "user" -PasswordString "1234"
    Configure-Firewall
    Optimize-PowerSettings
    Enable-RemoteDesktop
    Disable-WindowsDefender
    Optimize-SystemDebloat
    Install-PackageManager
    Install-DailyReport
    
    # 收尾
    $checkFailed = Verify-SystemHealth
    
    # 诊断报表输出
    Write-Color "`n===================== 终局报告 ========================" "Cyan"
    if ($global:ErrorsFound -or $checkFailed) {
        Write-Color " 【警告】 突围任务遭遇到异常顽固反制！请仔细筛查拦截日志！" "Red"
    } else {
        Write-Color " 【完成】 基建部署结束，请接管机器！" "Green"
        Write-Color " ----------------------------------------------------" "Cyan"
        Write-Color " 💻 Coder 控制台接入：" "Green"
        Write-Color "      $ ssh user@<本机器内网IP地址>" "Yellow"
        Write-Color " 📺 图形化急救直连：" "Green"
        Write-Color "      使用 Remote Desktop 客服端连接该 IP" "Yellow"
    }
    Write-Color "=======================================================" "Cyan"

    Write-Host "`n长按 Enter 键彻底退出并接管系统..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
}

# 挂载点
Main
