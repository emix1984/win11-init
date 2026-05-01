# Force console output to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Self-elevation mechanism (if not already elevated by bootstrapper)
$isAdmin = [bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process powershell -Verb RunAs -ArgumentList $arguments
    } catch {
        Write-Host "Tip: Elevation cancelled or failed. Press any key to exit..."
    }
    exit
}

# Enable logging
$LogPath = Join-Path -Path $PSScriptRoot -ChildPath "setup_win11.log"

# Function to format messages with timestamps (captured by Transcript)
function Write-Color {
    param([string]$Message, [string]$Color = "White")
    $Timestamp = Get-Date -Format "HH:mm:ss"
    $FormattedMessage = "[$Timestamp] $Message"
    Write-Host $FormattedMessage -ForegroundColor $Color
}

Start-Transcript -Path $LogPath -Append -Force
Write-Color "Starting initialization process." "Cyan"

# Global error tracking
$global:ErrorsFound = $false

# Disable progress bar to speed up downloads
$ProgressPreference = 'SilentlyContinue'

# Module 1: OpenSSH Management
function Install-OpenSSH {
    Write-Color "`n[1/9] Checking OpenSSH components..." "Yellow"
    try {
        # Check if already installed
        if ((Get-Service -Name sshd -ErrorAction SilentlyContinue) -and (Test-Path "C:\Windows\System32\OpenSSH\sshd.exe")) {
            Write-Color " -> OpenSSH is already present and registered." "Cyan"
        } else {
            $msiUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi"
            $msiPath = "$env:TEMP\OpenSSH-Win64-v10.0.0.0.msi"
            
            Write-Color " -> Downloading OpenSSH MSI (v10.0.0.0)..." "Cyan"
            Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -TimeoutSec 60
            
            Write-Color " -> Silent installing OpenSSH..." "Cyan"
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -WindowStyle Hidden -PassThru
            
            if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
                throw "MSI installation failed with exit code: $($process.ExitCode)"
            }
        }

        # Service configuration
        $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if ($sshd) {
            Write-Color " -> Configuring sshd service..." "Cyan"
            Set-Service -Name sshd -StartupType 'Automatic'
            if ($sshd.Status -ne 'Running') { Start-Service sshd }
        }

        # Firewall check
        if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
            Write-Color " -> Adding Firewall rule for SSH (Port 22)..." "Cyan"
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction Stop | Out-Null
        }
        Write-Color " -> OpenSSH setup successful." "Green"
    } catch {
        Write-Color " -> [Error] OpenSSH module failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

function Optimize-SSHConfig {
    Write-Color "`n[2/9] Optimizing SSH environment..." "Yellow"
    try {
        # Set Default Shell to PowerShell
        $DefaultShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $regPath = "HKLM:\SOFTWARE\OpenSSH"
        if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        New-ItemProperty -Path $regPath -Name "DefaultShell" -Value $DefaultShell -PropertyType String -Force | Out-Null
        
        # Edit sshd_config
        $sshConfigFile = "C:\ProgramData\ssh\sshd_config"
        if (Test-Path $sshConfigFile) {
            $configContent = Get-Content $sshConfigFile
            $configContent = $configContent -replace "^\s*#?ClientAliveInterval\s+.*", "ClientAliveInterval 60"
            $configContent = $configContent -replace "^\s*#?ClientAliveCountMax\s+.*", "ClientAliveCountMax 3"
            # Allow administrators to use their own authorized_keys
            $configContent = $configContent -replace "^(#?)(Match Group administrators)", "#`$2"
            $configContent = $configContent -replace "^(#?)(\s*AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)", "#`$2"
            $configContent | Set-Content $sshConfigFile -Force
            Restart-Service sshd -ErrorAction SilentlyContinue
            Write-Color " -> Keep-Alive and Admin-Keys config applied." "Green"
        }
    } catch {
        Write-Color " -> [Error] SSH optimization failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 2: Account Management
function Setup-SSHUser {
    param([string]$Username, [string]$PasswordString)
    Write-Color "`n[3/9] Managing local deployment account: '$Username'..." "Yellow"
    try {
        $SecurePassword = ConvertTo-SecureString $PasswordString -AsPlainText -Force
        if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
            Write-Color " -> User exists, resetting password." "Cyan"
            Set-LocalUser -Name $Username -Password $SecurePassword -ErrorAction Stop
        } else {
            Write-Color " -> Creating new local user." "Cyan"
            New-LocalUser -Name $Username -Password $SecurePassword -FullName "Headless Admin" -Description "Automated SSH Access" -PasswordNeverExpires -ErrorAction Stop | Out-Null
        }
        # Ensure Admin rights
        Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction SilentlyContinue | Out-Null
        Write-Color " -> User '$Username' is fully provisioned." "Green"
    } catch {
        Write-Color " -> [Error] User provisioning failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 3: Firewall Policy
function Configure-Firewall {
    Write-Color "`n[4/9] Applying network access policy..." "Yellow"
    try {
        # Strict mode (recommended but currently allowing all as per user request)
        # New-NetFirewallRule -DisplayName "SSH-ONLY" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22
        
        Remove-NetFirewallRule -DisplayName "ALLOW ALL INBOUND" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "ALLOW ALL INBOUND" -Direction Inbound -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        Write-Color " -> [SECURITY WARNING] All inbound traffic is allowed (Headless Server Mode)." "Red"
    } catch {
        Write-Color " -> [Error] Firewall rule application failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 4: Power & Sleep Policy
function Optimize-PowerSettings {
    Write-Color "`n[5/9] Locking power state for persistent uptime..." "Yellow"
    try {
        # High Performance
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c *>&1 | Out-Null
        # Disable all timeouts
        $params = @("-standby-timeout-ac", "-standby-timeout-dc", "-hibernate-timeout-ac", "-hibernate-timeout-dc")
        foreach ($p in $params) { powercfg /x $p 0 }
        
        # Lid close action (do nothing)
        powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
        powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
        powercfg /setactive SCHEME_CURRENT | Out-Null
        Write-Color " -> Sleep/Hibernate blocked successfully." "Green"
    } catch {
        Write-Color " -> [Error] Power management failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 7: Remote Desktop (RDP)
function Enable-RemoteDesktop {
    Write-Color "`n[7/11] Enabling RDP emergency access..." "Yellow"
    try {
        $tsPath = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
        Set-ItemProperty -Path $tsPath -Name "fDenyTSConnections" -Value 0
        Enable-NetFirewallRule -DisplayGroup "@FirewallAPI.dll,-28752" -ErrorAction SilentlyContinue # Remote Desktop display group
        Write-Color " -> RDP enabled and firewall port 3389 opened." "Green"
    } catch {
        Write-Color " -> [Error] RDP setup failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 8: Windows Defender
function Disable-WindowsDefender {
    Write-Color "`n[8/11] Bypassing Windows Defender (High Risk Mode)..." "Yellow"
    try {
        if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
            # Real-time exclusions
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
            
            # Global exclusion for system drive
            Add-MpPreference -ExclusionPath "C:\" -ErrorAction SilentlyContinue
            
            # Policy keys
            $WD_Policy_Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
            if (!(Test-Path $WD_Policy_Path)) { New-Item -Path $WD_Policy_Path -Force | Out-Null }
            Set-ItemProperty -Path $WD_Policy_Path -Name "DisableAntiSpyware" -Value 1 -PropertyType DWord -Force | Out-Null

            Write-Color " -> Defender realtime monitoring and full disk scanning disabled." "Green"
        }
    } catch {
        Write-Color " -> [Error] Defender module failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 9: System Debloat & UAC
function Optimize-SystemDebloat {
    Write-Color "`n[9/11] Cleaning up system noise..." "Yellow"
    try {
        # Disable Hibernation file to save space
        powercfg /h off | Out-Null
        
        # Disable UAC (Consent Prompt)
        $uacPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        Set-ItemProperty -Path $uacPath -Name "ConsentPromptBehaviorAdmin" -Value 0
        Set-ItemProperty -Path $uacPath -Name "PromptOnSecureDesktop" -Value 0
        
        # Set PowerShell Execution Policy
        try { 
            Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop 
        } catch { 
            Write-Color " -> [Note] Execution Policy locked by GPO." "Cyan" 
        }

        # Prevent auto-reboot on updates
        $WU_AU_Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
        if (!(Test-Path $WU_AU_Path)) { New-Item -Path $WU_AU_Path -Force | Out-Null }
        Set-ItemProperty -Path $WU_AU_Path -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force | Out-Null

        Write-Color " -> UAC silenced and auto-reboot disabled." "Green"
    } catch {
        Write-Color " -> [Error] Debloat module failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 10: Package Management (Chocolatey)
function Install-PackageManager {
    Write-Color "`n[10/11] Provisioning Chocolatey & modern tools..." "Yellow"
    try {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Color " -> Chocolatey is already active." "Cyan"
        } else {
            Write-Color " -> Downloading and installing Chocolatey..." "Cyan"
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            $script = (New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
            Invoke-Expression $script
            
            # Immediate Path refresh
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        }

        # Use Choco to ensure modern curl is present
        Write-Color " -> Ensuring native curl is available via Choco..." "Cyan"
        $chocoPath = if (Get-Command choco -ErrorAction SilentlyContinue) { "choco" } else { "$env:ProgramData\chocolatey\bin\choco.exe" }
        if ((Test-Path $chocoPath) -or (Get-Command choco -ErrorAction SilentlyContinue)) {
            & $chocoPath install curl -y --no-progress | Out-Null
        }

        # Remove Microsoft's curl alias to allow native curl to work correctly
        $globalProfile = $PROFILE.AllUsersAllHosts
        $profileDir = Split-Path $globalProfile
        if (!(Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
        if (!(Test-Path $globalProfile)) { New-Item -ItemType File -Path $globalProfile -Force | Out-Null }
        
        $profileContent = Get-Content $globalProfile -Raw -ErrorAction SilentlyContinue
        if ($null -eq $profileContent -or $profileContent -notmatch "Remove-Item Alias:curl") {
            Add-Content -Path $globalProfile -Value "`r`n# Restoring native curl behavior`r`nRemove-Item Alias:curl -ErrorAction SilentlyContinue" -Encoding UTF8
        }
        
        Write-Color " -> Package management environment is ready." "Green"
    } catch {
        Write-Color " -> [Error] Package manager setup failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 6: IP Helper Service Configuration
function Configure-IPHelper {
    Write-Color "`n[6/11] Configuring IP Helper service..." "Yellow"
    try {
        # 1. Set startup type to Automatic
        Set-Service -Name "iphlpsvc" -StartupType Automatic -ErrorAction Stop

        # 2. Check status and start if necessary
        $service = Get-Service -Name "iphlpsvc"
        if ($service.Status -ne 'Running') {
            Start-Service -Name "iphlpsvc" -ErrorAction Stop
            Write-Color " -> IP Helper service set to Automatic and started." "Green"
        } else {
            Write-Color " -> IP Helper service already running (Startup: Automatic)." "Green"
        }
    } catch {
        Write-Color " -> [Error] IP Helper configuration failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Module 11: Health Report Deployment
function Install-DailyReport {
    Write-Color "`n[11/11] Deploying monitoring agent..." "Yellow"
    try {
        $DailyReportPath = Join-Path -Path $PSScriptRoot -ChildPath "dailyreport.ps1"
        if (Test-Path $DailyReportPath) {
            & $DailyReportPath -Install | Out-Null
            Write-Color " -> Monitoring task registered successfully." "Green"
        } else {
            Write-Color " -> [Note] dailyreport.ps1 not found in script root." "Cyan"
        }
    } catch {
        Write-Color " -> [Error] Monitoring deployment failed: $_" "Red"
        $global:ErrorsFound = $true
    }
}

# Final Verification
function Verify-SystemHealth {
    Write-Color "`n[+] =========================================" "Cyan"
    Write-Color "[+] Running Post-Deployment Health Check..." "Cyan"
    Start-Sleep -Seconds 1 
    
    $VerificationFailed = $false
    
    # 1. SSH
    if ((Get-Service -Name sshd -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Color " [PASS] OpenSSH service is healthy." "Green"
    } else { Write-Color " [FAIL] OpenSSH service not running." "Red"; $VerificationFailed = $true }

    # 2. User
    if (Get-LocalUser -Name "user" -ErrorAction SilentlyContinue) {
        Write-Color " [PASS] Local admin 'user' is active." "Green"
    } else { Write-Color " [FAIL] Target user missing." "Red"; $VerificationFailed = $true }

    # 3. RDP
    $rdpDeny = Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -ErrorAction SilentlyContinue
    if ($rdpDeny -and $rdpDeny.fDenyTSConnections -eq 0) {
        Write-Color " [PASS] RDP emergency access enabled." "Green"
    } else { Write-Color " [FAIL] RDP settings incorrect." "Red"; $VerificationFailed = $true }
    
    # 4. Package Manager
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Color " [PASS] Chocolatey environment verified." "Green"
    } else { Write-Color " [WARN] Chocolatey not found in current PATH." "Yellow" }

    # 5. IP Helper
    if ((Get-Service -Name iphlpsvc -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Color " [PASS] IP Helper service is active." "Green"
    } else { Write-Color " [WARN] IP Helper service is not running." "Yellow" }

    # 6. Monitoring Push Test
    Write-Color " [INFO] Testing Gotify notification push..." "Cyan"
    try {
        $DailyReportPath = Join-Path -Path $PSScriptRoot -ChildPath "dailyreport.ps1"
        if (Test-Path $DailyReportPath) {
            & $DailyReportPath -ErrorAction Stop | Out-Null
            Write-Color " [PASS] Gotify test push successful." "Green"
        } else {
            Write-Color " [FAIL] dailyreport.ps1 not found for testing." "Red"
            $VerificationFailed = $true
        }
    } catch {
        Write-Color " [FAIL] Gotify test push failed: $_" "Red"
        $VerificationFailed = $true
    }

    return $VerificationFailed
}

# Main Execution
function Main {
    Write-Color "==========================================================" "Cyan"
    Write-Color "     Windows 11 Optimal Initializer v2.0     " "Cyan"
    Write-Color "==========================================================" "Cyan"
    
    Install-OpenSSH
    Optimize-SSHConfig
    Setup-SSHUser -Username "user" -PasswordString "1234"
    Configure-Firewall
    Optimize-PowerSettings
    Configure-IPHelper
    Enable-RemoteDesktop
    Disable-WindowsDefender
    Optimize-SystemDebloat
    Install-PackageManager
    Install-DailyReport
    
    # Final Cleanup
    Write-Color "`n[+] Cleaning up temporary installation files..." "Cyan"
    $msiPath = "$env:TEMP\OpenSSH-Win64-v10.0.0.0.msi"
    if (Test-Path $msiPath) { Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue }
    
    $checkFailed = Verify-SystemHealth
    
    Write-Color "`n===================== Final Summary ========================" "Cyan"
    if ($global:ErrorsFound -or $checkFailed) {
        Write-Color " [!] WARNING: Deployment encountered minor issues." "Red"
        Write-Color "     Check $LogPath for details." "Yellow"
    } else {
        Write-Color " [OK] SUCCESS: System is fully optimized." "Green"
    }
    Write-Color "=======================================================" "Cyan"
}

# Execute
Main
Write-Color "Initialization process completed." "Cyan"
Stop-Transcript -ErrorAction SilentlyContinue
