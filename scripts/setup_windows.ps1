# setup_windows.ps1 — Gaming-PC (als Administrator ausführen)
# Richtet ein: Wake-on-LAN, WMC Agent, Sunshine Game-Streaming

#Requires -RunAsAdministrator

param(
    [string]$AgentPort = "9876",
    [string]$BindHost  = "0.0.0.0"
)

$ErrorActionPreference = "Stop"
$WmcDir    = "C:\WMC"
$AgentDir  = "$WmcDir\agent"
$NssmPath  = "$WmcDir\nssm.exe"

Write-Host "=== WMC Windows Setup ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $WmcDir | Out-Null

# ── 1. Wake-on-LAN ────────────────────────────────────────────────────────────
Write-Host "`n[1/6] Wake-on-LAN aktivieren..." -ForegroundColor Yellow
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    $name = $_.Name
    foreach ($kw in @("WakeOnMagicPacket", "*WakeOnMagicPacket", "*WakeOnPattern")) {
        Set-NetAdapterAdvancedProperty -Name $name `
            -RegistryKeyword $kw -RegistryValue 1 -ErrorAction SilentlyContinue
    }
    # "Allow the computer to wake this device" in Gerätemanager
    $pnp = Get-PnpDeviceProperty -InstanceId (Get-NetAdapterHardwareInfo -Name $name `
        -ErrorAction SilentlyContinue).PnPDeviceID -KeyName DEVPKEY_Device_WakeFromD0 `
        -ErrorAction SilentlyContinue
    Write-Host "  OK: $name"
}

# Fast Startup deaktivieren (sonst kein WoL nach echtem Shutdown)
powercfg /hibernate on
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
    /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
Write-Host "  Fast Startup deaktiviert"

# ── 2. OpenSSH ────────────────────────────────────────────────────────────────
Write-Host "`n[2/6] OpenSSH Server einrichten..." -ForegroundColor Yellow
$ssh = Get-WindowsCapability -Online -Name "OpenSSH.Server*"
if ($ssh.State -ne "Installed") {
    Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "WMC-SSH" -DisplayName "WMC SSH" `
    -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
Write-Host "  OpenSSH Server läuft"

# ── 3. Python / NSSM ──────────────────────────────────────────────────────────
Write-Host "`n[3/6] Abhängigkeiten prüfen..." -ForegroundColor Yellow
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "  Python nicht gefunden!" -ForegroundColor Red
    Write-Host "  Bitte Python 3.10+ von python.org installieren, dann neu starten." -ForegroundColor Red
    exit 1
}
Write-Host "  Python: $((python --version 2>&1))"

if (-not (Test-Path $NssmPath)) {
    Write-Host "  NSSM wird heruntergeladen..." -ForegroundColor Gray
    $zip = "$WmcDir\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath "$WmcDir\nssm_tmp"
    Copy-Item "$WmcDir\nssm_tmp\nssm-2.24\win64\nssm.exe" $NssmPath
    Remove-Item -Recurse -Force "$WmcDir\nssm_tmp", $zip
}

# ── 4. WMC Agent ──────────────────────────────────────────────────────────────
Write-Host "`n[4/6] WMC Agent installieren..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
Copy-Item -Force "$PSScriptRoot\..\agent\agent.py" "$AgentDir\agent.py"

& $NssmPath stop   WMCAgent 2>$null
& $NssmPath remove WMCAgent confirm 2>$null
& $NssmPath install WMCAgent (Get-Command python).Source "$AgentDir\agent.py"
& $NssmPath set WMCAgent AppEnvironmentExtra "WMC_AGENT_PORT=$AgentPort" "WMC_AGENT_BIND=$BindHost"
& $NssmPath set WMCAgent Start SERVICE_AUTO_START
& $NssmPath set WMCAgent AppStdout "C:\WMC\agent.log"
& $NssmPath set WMCAgent AppStderr "C:\WMC\agent_err.log"
Start-Service WMCAgent

New-NetFirewallRule -Name "WMC-Agent" -DisplayName "WMC Agent" `
    -Direction Inbound -Protocol TCP -LocalPort $AgentPort -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
Write-Host "  WMC Agent läuft auf Port $AgentPort"

# ── 5. Sunshine Game-Streaming ────────────────────────────────────────────────
Write-Host "`n[5/6] Sunshine installieren..." -ForegroundColor Yellow

# Aktuelle Version von GitHub Releases holen
$release = Invoke-RestMethod "https://api.github.com/repos/LizardByte/Sunshine/releases/latest"
$asset   = $release.assets | Where-Object { $_.name -match "sunshine-windows.*\.exe$" } | Select-Object -First 1

if (-not $asset) {
    Write-Host "  Sunshine-Asset nicht gefunden — bitte manuell von https://github.com/LizardByte/Sunshine/releases installieren" -ForegroundColor Red
} else {
    $sunshineInstaller = "$WmcDir\sunshine_setup.exe"
    Write-Host "  Lade $($asset.name) herunter..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $sunshineInstaller
    # Silent-Install
    Start-Process -FilePath $sunshineInstaller -ArgumentList "/S" -Wait
    Remove-Item $sunshineInstaller -ErrorAction SilentlyContinue
    Write-Host "  Sunshine installiert"

    # Latenz-optimierte Sunshine-Konfiguration schreiben
    $sunshineConf = "$env:APPDATA\Sunshine\sunshine.conf"
    $confDir      = Split-Path $sunshineConf
    New-Item -ItemType Directory -Force -Path $confDir | Out-Null

    # GPU-Encoder ermitteln
    $gpu = (Get-WmiObject Win32_VideoController | Select-Object -First 1).Caption
    $encoder = "software"
    if ($gpu -match "NVIDIA") { $encoder = "nvenc" }
    elseif ($gpu -match "AMD|Radeon") { $encoder = "amdvce" }
    elseif ($gpu -match "Intel") { $encoder = "quicksync" }
    Write-Host "  GPU erkannt: $gpu → Encoder: $encoder"

    @"
# WMC Sunshine Konfiguration — latenzoptimiert
# Encoder: $encoder (automatisch ermittelt)
encoder = $encoder

# Auflösung & Framerate
fps = [30, 60, 90, 120]
resolutions = [1280x720, 1920x1080, 2560x1440, 3840x2160]

# Niedrigste Latenz: kein B-Frame-Delay, kein Rate-Control-Overhead
nvenc_preset = p1
nvenc_twopass = disabled
nvenc_rc = cbr
amdvce_quality = speed
qsv_preset = veryfast

# Codec-Priorität: AV1 > H.265 > H.264 (bessere Qualität bei gleichem Bitrate)
hevc_mode = 2
av1_mode = 2

# Audio-Latenz minimieren
audio_sink =

# Gamepad
gamepad = ds4

# Netzwerk — auf allen Interfaces lauschen (Tailscale + LAN)
address_family = both
"@ | Set-Content -Encoding UTF8 $sunshineConf

    Write-Host "  Latenzoptimierte Konfiguration geschrieben: $sunshineConf"

    # Sunshine-Firewall-Ports öffnen (TCP + UDP)
    $tcpPorts = @(47984, 47989, 47990, 48010)
    $udpPorts = @(47998, 47999, 48000, 48002, 48010)
    New-NetFirewallRule -Name "WMC-Sunshine-TCP" -DisplayName "WMC Sunshine TCP" `
        -Direction Inbound -Protocol TCP -LocalPort $tcpPorts -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -Name "WMC-Sunshine-UDP" -DisplayName "WMC Sunshine UDP" `
        -Direction Inbound -Protocol UDP -LocalPort $udpPorts -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  Firewall-Regeln gesetzt (TCP + UDP)"

    # Sunshine als Dienst starten
    Start-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    Write-Host "  Sunshine-Dienst gestartet"
}

# ── 6. Zusammenfassung ────────────────────────────────────────────────────────
Write-Host "`n[6/6] GPU-Treiber und BIOS-Erinnerung..." -ForegroundColor Yellow
Write-Host "  Stelle sicher dass dein GPU-Treiber aktuell ist (GeForce Experience / AMD Software)"
Write-Host "  Für NVIDIA: Hardware-Encoding (NVENC) ist ab GTX 900 Serie verfügbar"

Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Setup abgeschlossen!" -ForegroundColor Green
Write-Host ""
Write-Host "  MAC-Adresse (für Relay-Konfiguration):" -ForegroundColor White
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } `
    | Select-Object Name, MacAddress | Format-Table -AutoSize
Write-Host ""
Write-Host "  Nächste Schritte:" -ForegroundColor White
Write-Host "  1. BIOS: Wake on LAN / Power on by PCIe aktivieren"
Write-Host "  2. Sunshine Web-UI öffnen: https://localhost:47990"
Write-Host "     (Benutzername + Passwort beim ersten Start setzen)"
Write-Host "  3. Auf dem Mac: wmc stream"
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
