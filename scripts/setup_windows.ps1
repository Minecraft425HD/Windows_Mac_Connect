# setup_windows.ps1 — Run on Gaming Notebook (as Administrator)
# Enables Wake-on-LAN, installs WMC Agent as a Windows service

#Requires -RunAsAdministrator

param(
    [string]$AgentPort = "9876",
    [string]$BindHost  = "0.0.0.0"
)

$ErrorActionPreference = "Stop"
$InstallDir = "C:\WMC\agent"

Write-Host "=== WMC Windows Setup ===" -ForegroundColor Cyan

# 1. Enable Wake-on-LAN in network adapter settings
Write-Host "`n[1/5] Enabling Wake-on-LAN on network adapters..." -ForegroundColor Yellow
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    $adapter = $_
    try {
        # Enable magic packet wake
        $pnpDevice = $adapter | Get-PnpDevice
        Set-NetAdapterAdvancedProperty -Name $adapter.Name `
            -RegistryKeyword "WakeOnMagicPacket" -RegistryValue 1 -ErrorAction SilentlyContinue
        Set-NetAdapterAdvancedProperty -Name $adapter.Name `
            -RegistryKeyword "*WakeOnMagicPacket" -RegistryValue 1 -ErrorAction SilentlyContinue
        Write-Host "  OK: $($adapter.Name)"
    } catch {
        Write-Host "  Skipped $($adapter.Name): $_" -ForegroundColor Gray
    }
}

# 2. Allow WoL through Windows power settings (don't cut power on shutdown)
Write-Host "`n[2/5] Configuring power plan for Wake-on-LAN..." -ForegroundColor Yellow
# Fast Startup must be OFF for WoL from full shutdown to work
powercfg /hibernate on
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
    /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
Write-Host "  Fast Startup disabled (required for WoL)"

# 3. Enable OpenSSH server (built into Windows 10/11)
Write-Host "`n[3/5] Enabling OpenSSH Server..." -ForegroundColor Yellow
$sshFeature = Get-WindowsCapability -Online -Name "OpenSSH.Server*"
if ($sshFeature.State -ne "Installed") {
    Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd -ErrorAction SilentlyContinue
# Allow SSH through firewall
New-NetFirewallRule -Name "WMC-SSH" -DisplayName "WMC SSH" `
    -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
Write-Host "  OpenSSH Server enabled"

# 4. Install WMC Agent
Write-Host "`n[4/5] Installing WMC Agent..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force "$PSScriptRoot\..\agent\agent.py" "$InstallDir\agent.py"

# Check Python
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "  Python not found. Install Python 3.10+ from python.org" -ForegroundColor Red
    Write-Host "  Then re-run this script." -ForegroundColor Red
    exit 1
}

# Install NSSM (Non-Sucking Service Manager) if not present
$nssmPath = "C:\WMC\nssm.exe"
if (-not (Test-Path $nssmPath)) {
    Write-Host "  Downloading NSSM..." -ForegroundColor Gray
    $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $nssmZip = "C:\WMC\nssm.zip"
    Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip
    Expand-Archive -Path $nssmZip -DestinationPath "C:\WMC\nssm_tmp"
    Copy-Item "C:\WMC\nssm_tmp\nssm-2.24\win64\nssm.exe" $nssmPath
    Remove-Item -Recurse -Force "C:\WMC\nssm_tmp", $nssmZip
}

# Register as Windows service
& $nssmPath stop WMCAgent 2>$null
& $nssmPath remove WMCAgent confirm 2>$null
& $nssmPath install WMCAgent (Get-Command python).Source "$InstallDir\agent.py"
& $nssmPath set WMCAgent AppEnvironmentExtra "WMC_AGENT_PORT=$AgentPort" "WMC_AGENT_BIND=$BindHost"
& $nssmPath set WMCAgent Start SERVICE_AUTO_START
& $nssmPath set WMCAgent AppStdout "C:\WMC\agent.log"
& $nssmPath set WMCAgent AppStderr "C:\WMC\agent_err.log"
Start-Service WMCAgent

Write-Host "  WMC Agent installed and running on port $AgentPort"

# 5. Open firewall for agent
Write-Host "`n[5/5] Opening firewall for WMC Agent..." -ForegroundColor Yellow
New-NetFirewallRule -Name "WMC-Agent" -DisplayName "WMC Agent" `
    -Direction Inbound -Protocol TCP -LocalPort $AgentPort -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
Write-Host "  Firewall rule added for port $AgentPort"

Write-Host "`n=== Setup Complete ===" -ForegroundColor Green
Write-Host "PC MAC address (needed for relay config):"
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object Name, MacAddress | Format-Table
Write-Host ""
Write-Host "IMPORTANT: Also enable Wake-on-LAN in your BIOS/UEFI settings!" -ForegroundColor Magenta
Write-Host "  Look for: 'Wake on LAN', 'Power on by PCI-E', or similar" -ForegroundColor Magenta
