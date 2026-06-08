﻿# setup_windows.ps1 - Gaming-PC (als Administrator ausführen)
# Richtet vollautomatisch ein:
#   Wake-on-LAN - OpenSSH - Python - WMC Agent - Sunshine - Auto-Login - Tailscale

#Requires -RunAsAdministrator

param(
    [string]$AgentPort = "9876",
    [string]$BindHost  = "0.0.0.0"
)

$ErrorActionPreference = "Continue"
$WmcDir   = "C:\WMC"
$AgentDir = "$WmcDir\agent"
$Steps    = 8

New-Item -ItemType Directory -Force -Path $WmcDir | Out-Null

Write-Host ""
Write-Host "+======================================================+" -ForegroundColor Cyan
Write-Host "|         WMC Windows Setup - Gaming-PC                |" -ForegroundColor Cyan
Write-Host "|  Wake-on-LAN - Streaming - Fernsteuerung             |" -ForegroundColor Cyan
Write-Host "+======================================================+" -ForegroundColor Cyan
Write-Host ""

# -- 1. Wake-on-LAN ------------------------------------------------------------
Write-Host "[1/$Steps] Wake-on-LAN aktivieren" -ForegroundColor Yellow
Write-Host "  Damit der PC per Netzwerk eingeschaltet werden kann."
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    $name = $_.Name
    foreach ($kw in @("WakeOnMagicPacket", "*WakeOnMagicPacket", "*WakeOnPattern")) {
        Set-NetAdapterAdvancedProperty -Name $name `
            -RegistryKeyword $kw -RegistryValue 1 -ErrorAction SilentlyContinue
    }
    Write-Host "  OK: $name"
}
powercfg /hibernate on 2>$null
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
    /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
Write-Host "  Fast Startup deaktiviert (erforderlich fur WoL nach Shutdown)"

# -- 2. OpenSSH ----------------------------------------------------------------
Write-Host ""
Write-Host "[2/$Steps] OpenSSH Server" -ForegroundColor Yellow
Write-Host "  Ermoeglicht sichere Verbindungen vom MacBook."
$ssh = Get-WindowsCapability -Online -Name "OpenSSH.Server*"
if ($ssh.State -ne "Installed") {
    Write-Host "  Installiere OpenSSH..." -ForegroundColor Gray
    Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "WMC-SSH" -DisplayName "WMC SSH" `
    -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
Write-Host "  OK: OpenSSH Server laeuft"

# -- 3. Python ----------------------------------------------------------------
Write-Host ""
Write-Host "[3/$Steps] Python" -ForegroundColor Yellow
Write-Host "  Benoetigt fuer den WMC Agent (Hintergrunddienst)."
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "  Python nicht gefunden -- installiere via winget..." -ForegroundColor Gray
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Python.Python.3.12 --silent --accept-package-agreements `
            --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
                    [System.Environment]::GetEnvironmentVariable("Path","User")
    } else {
        Write-Host "  winget nicht verfuegbar." -ForegroundColor Red
        Write-Host "  Bitte Python 3.10+ von https://python.org manuell installieren" -ForegroundColor Red
        Write-Host "  Dann dieses Skript neu starten." -ForegroundColor Red
        exit 1
    }
}
Write-Host "  OK: $((python --version 2>&1))"

# -- 4. WMC Agent -------------------------------------------------------------
Write-Host ""
Write-Host "[4/$Steps] WMC Agent installieren" -ForegroundColor Yellow
Write-Host "  Empfaengt Fernbefehle: Herunterfahren, Schlafen, Sperren."
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
Copy-Item -Force "$PSScriptRoot\..\agent\agent.py" "$AgentDir\agent.py"

# Wrapper-Skript damit Task Scheduler den Agent ohne Fenster startet
$wrapperContent = "@echo off`r`nset WMC_AGENT_PORT=$AgentPort`r`nset WMC_AGENT_BIND=$BindHost`r`npython `"$AgentDir\agent.py`" >> `"C:\WMC\agent.log`" 2>&1"
Set-Content -Path "$AgentDir\start_agent.bat" -Value $wrapperContent -Encoding ASCII

# Task Scheduler (kein externer Download noetig)
$pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pythonExe) { $pythonExe = "python" }

$action  = New-ScheduledTaskAction -Execute $pythonExe `
               -Argument "`"$AgentDir\agent.py`"" `
               -WorkingDirectory $AgentDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3 `
               -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$envPath  = [System.Environment]::GetEnvironmentVariable("PATH","Machine")

Unregister-ScheduledTask -TaskName "WMCAgent" -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "WMCAgent" -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description "WMC Remote Agent" `
    -ErrorAction SilentlyContinue | Out-Null

# Umgebungsvariablen fuer den Task setzen
$task = Get-ScheduledTask -TaskName "WMCAgent" -ErrorAction SilentlyContinue
if ($task) {
    $task.Principal.RunLevel = "Highest"
    $envVars = @("WMC_AGENT_PORT=$AgentPort", "WMC_AGENT_BIND=$BindHost")
    # Umgebungsvariablen via Registry setzen (Task Scheduler liest SYSTEM-Env)
    [System.Environment]::SetEnvironmentVariable("WMC_AGENT_PORT", $AgentPort, "Machine")
    [System.Environment]::SetEnvironmentVariable("WMC_AGENT_BIND", $BindHost, "Machine")
    Start-ScheduledTask -TaskName "WMCAgent" -ErrorAction SilentlyContinue
    Write-Host "  OK: WMC Agent als geplanter Task registriert (Port $AgentPort)"
} else {
    Write-Host "  WARNUNG: Task Scheduler Registrierung fehlgeschlagen" -ForegroundColor Yellow
    Write-Host "  Agent manuell starten: python $AgentDir\agent.py" -ForegroundColor Yellow
}

New-NetFirewallRule -Name "WMC-Agent" -DisplayName "WMC Agent" `
    -Direction Inbound -Protocol TCP -LocalPort $AgentPort -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null

# -- 5. Sunshine ---------------------------------------------------------------
Write-Host ""
Write-Host "[5/$Steps] Sunshine Game-Streaming" -ForegroundColor Yellow
Write-Host "  Uebertraegt Bild + Ton mit niedrigster Latenz (Hardware-Encoding)."

$gpu     = (Get-WmiObject Win32_VideoController | Select-Object -First 1).Caption
$encoder = "software"
if ($gpu -match "NVIDIA")         { $encoder = "nvenc" }
elseif ($gpu -match "AMD|Radeon") { $encoder = "amdvce" }
elseif ($gpu -match "Intel")      { $encoder = "quicksync" }
Write-Host "  GPU erkannt: $gpu  (Encoder: $encoder)"

try {
    $release = Invoke-RestMethod "https://api.github.com/repos/LizardByte/Sunshine/releases/latest"
    $asset   = $release.assets | Where-Object { $_.name -match "sunshine-windows.*\.exe$" } `
                                | Select-Object -First 1
    if ($asset) {
        Write-Host "  Lade $($asset.name)..." -ForegroundColor Gray
        $inst = "$WmcDir\sunshine_setup.exe"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $inst
        Start-Process -FilePath $inst -ArgumentList "/S" -Wait
        Remove-Item $inst -ErrorAction SilentlyContinue
        Write-Host "  OK: Sunshine installiert"
    }
} catch {
    Write-Host "  Download fehlgeschlagen. Manuell: https://github.com/LizardByte/Sunshine/releases" -ForegroundColor Red
}

$confDir = "$env:APPDATA\Sunshine"
New-Item -ItemType Directory -Force -Path $confDir | Out-Null
@"
encoder = $encoder
fps = [30, 60, 90, 120]
resolutions = [1280x720, 1920x1080, 2560x1440, 3840x2160]
nvenc_preset = p1
nvenc_twopass = disabled
nvenc_rc = cbr
amdvce_quality = speed
qsv_preset = veryfast
hevc_mode = 2
av1_mode = 2
audio_sink =
gamepad = ds4
address_family = both
"@ | Set-Content -Encoding UTF8 "$confDir\sunshine.conf"

New-NetFirewallRule -Name "WMC-Sunshine-TCP" -DisplayName "WMC Sunshine TCP" `
    -Direction Inbound -Protocol TCP -LocalPort @(47984,47989,47990,48010) -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -Name "WMC-Sunshine-UDP" -DisplayName "WMC Sunshine UDP" `
    -Direction Inbound -Protocol UDP -LocalPort @(47998,47999,48000,48002,48010) -Action Allow `
    -ErrorAction SilentlyContinue | Out-Null
Start-Service -Name "SunshineService" -ErrorAction SilentlyContinue
Write-Host "  OK: Sunshine konfiguriert und gestartet"

# -- 6. Latenz-Optimierungen ---------------------------------------------------
Write-Host ""
Write-Host "[6/$Steps] Latenz-Optimierungen" -ForegroundColor Yellow
Write-Host "  Ultimate Performance, Interrupt Moderation off, HAGS, Nagle off."
if (Test-Path "$PSScriptRoot\optimize_windows.ps1") {
    try {
        & "$PSScriptRoot\optimize_windows.ps1"
    } catch {
        Write-Host "  Teilweise fehlgeschlagen (unkritisch): $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "  optimize_windows.ps1 nicht gefunden -- uebersprungen" -ForegroundColor Gray
}

# -- 7. Auto-Login -------------------------------------------------------------
Write-Host ""
Write-Host "[7/$Steps] Auto-Login einrichten" -ForegroundColor Yellow
Write-Host "  Damit Windows nach Wake-on-LAN automatisch einloggt und Sunshine startet."
Write-Host ""
Write-Host "  WICHTIG: Jeder mit physischem Zugang kann sich ohne Passwort anmelden." -ForegroundColor Yellow
Write-Host "  Nur aktivieren wenn der PC sicher aufgestellt ist (z.B. Zuhause)." -ForegroundColor Yellow
Write-Host ""
$alChoice = Read-Host "  Auto-Login aktivieren? (j/n)"
if ($alChoice -match "^[jJyY]") {
    $user    = $env:USERNAME
    $domain  = if ($env:USERDOMAIN -eq $env:COMPUTERNAME) { "." } else { $env:USERDOMAIN }
    $secPass = Read-Host "  Windows-Passwort fuer '$user'" -AsSecureString
    $bstr    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
    $plain   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $alZip = "$WmcDir\AutoLogon.zip"
    $alDir = "$WmcDir\AutoLogon"
    Write-Host "  Lade Sysinternals AutoLogon..." -ForegroundColor Gray
    Invoke-WebRequest -Uri "https://download.sysinternals.com/files/AutoLogon.zip" -OutFile $alZip
    Expand-Archive -Path $alZip -DestinationPath $alDir -Force
    Remove-Item $alZip -ErrorAction SilentlyContinue
    $alExe = if (Test-Path "$alDir\Autologon64.exe") { "$alDir\Autologon64.exe" } else { "$alDir\Autologon.exe" }
    Start-Process -FilePath $alExe -ArgumentList "/AcceptEula", $user, $domain, $plain -Wait -NoNewWindow
    $plain = $null

    $check = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
    if ($check -eq "1") {
        Write-Host "  OK: Auto-Login aktiv fuer: $user"
    } else {
        Write-Host "  Konnte nicht verifiziert werden -- bitte manuell pruefen" -ForegroundColor Red
    }
} else {
    Write-Host "  Uebersprungen. Hinweis: Moonlight kann nicht streamen solange Windows am Anmeldebildschirm ist." -ForegroundColor Gray
}

# -- 8. Tailscale --------------------------------------------------------------
Write-Host ""
Write-Host "[8/$Steps] Tailscale (sicheres VPN)" -ForegroundColor Yellow
Write-Host "  Verbindet PC, Raspberry Pi und MacBook ueber das Internet ohne Port-Forwarding."
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    Write-Host "  Installiere Tailscale via winget..." -ForegroundColor Gray
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Tailscale.Tailscale --silent --accept-package-agreements `
            --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
                    [System.Environment]::GetEnvironmentVariable("Path","User")
        Write-Host "  OK: Tailscale installiert"
    } else {
        Write-Host "  Manuell: https://tailscale.com/download/windows" -ForegroundColor Yellow
    }
} else {
    Write-Host "  OK: Tailscale bereits installiert"
}
Write-Host "  Tailscale starten und mit deinem Account einloggen!" -ForegroundColor Cyan

# -- Zusammenfassung -----------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Setup abgeschlossen!" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  MAC-Adresse (fuer den Raspberry Pi notieren):" -ForegroundColor White
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } `
    | Select-Object Name, MacAddress | Format-Table -AutoSize
Write-Host "  Lokale IP-Adresse:" -ForegroundColor White
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -ne "WellKnown" } `
    | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize
Write-Host ""
Write-Host "  Naechste Schritte:" -ForegroundColor White
Write-Host "  1. BIOS/UEFI: Wake on LAN aktivieren"
Write-Host "     Neustart -> Entf/F2 -> 'Wake on LAN' oder 'Power on by PCIe'"
Write-Host "  2. Tailscale starten und mit Account einloggen"
Write-Host "  3. Sunshine Web-UI: Benutzername + Passwort setzen"
Write-Host "     https://localhost:47990"
Write-Host "  4. PC neu starten (damit alle Optimierungen greifen)"
Write-Host ""
Write-Host "  Weiter mit: Raspberry Pi einrichten (setup_relay.sh)" -ForegroundColor Cyan
