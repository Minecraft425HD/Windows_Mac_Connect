# uninstall_windows.ps1 — Gaming-PC (als Administrator ausführen)
# Macht ALLE Änderungen von setup_windows.ps1 und optimize_windows.ps1 rückgängig

#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"
$WmcDir = "C:\WMC"
$Steps  = 10

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║         WMC Deinstallation — Gaming-PC               ║" -ForegroundColor Red
Write-Host "║  Alle Änderungen werden rückgängig gemacht           ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""
Write-Host "  Folgendes wird entfernt / zurückgesetzt:" -ForegroundColor Yellow
Write-Host "  · WMC Agent (Windows-Dienst)"
Write-Host "  · Sunshine (Game-Streaming)"
Write-Host "  · Auto-Login"
Write-Host "  · Alle WMC Firewall-Regeln"
Write-Host "  · Latenz-Optimierungen (Ultimate Performance, Interrupt Moderation, etc.)"
Write-Host "  · Nagle-Algorithmus wieder aktivieren"
Write-Host "  · Energie-Einstellungen zurücksetzen"
Write-Host "  · Fast Startup wieder aktivieren"
Write-Host "  · Wake-on-LAN Einstellungen zurücksetzen"
Write-Host "  · OpenSSH Server deinstallieren"
Write-Host "  · Tailscale deinstallieren (optional)"
Write-Host "  · WMC-Dateien löschen (C:\WMC)"
Write-Host ""
$confirm = Read-Host "  Wirklich alles deinstallieren? (ja/n)"
if ($confirm -ne "ja") {
    Write-Host "  Abgebrochen." -ForegroundColor Gray
    exit 0
}
Write-Host ""

# ── 1. WMC Agent stoppen und entfernen ───────────────────────────────────────
Write-Host "[1/$Steps] WMC Agent entfernen" -ForegroundColor Yellow
$nssmPath = "$WmcDir\nssm.exe"
if (Test-Path $nssmPath) {
    & $nssmPath stop   WMCAgent 2>$null
    & $nssmPath remove WMCAgent confirm 2>$null
    Write-Host "  OK: WMC Agent Dienst entfernt"
} else {
    Stop-Service WMCAgent -ErrorAction SilentlyContinue
    sc.exe delete WMCAgent 2>$null
    Write-Host "  OK: WMC Agent entfernt (via sc.exe)"
}

# ── 2. Sunshine stoppen und deinstallieren ───────────────────────────────────
Write-Host ""
Write-Host "[2/$Steps] Sunshine deinstallieren" -ForegroundColor Yellow
Stop-Service -Name "SunshineService" -ErrorAction SilentlyContinue

# Uninstaller suchen
$sunshinePaths = @(
    "$env:ProgramFiles\Sunshine\uninstall.exe",
    "${env:ProgramFiles(x86)}\Sunshine\uninstall.exe",
    "$env:LOCALAPPDATA\Sunshine\uninstall.exe"
)
$uninstaller = $sunshinePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($uninstaller) {
    Write-Host "  Deinstalliere Sunshine..." -ForegroundColor Gray
    Start-Process -FilePath $uninstaller -ArgumentList "/S" -Wait
    Write-Host "  OK: Sunshine deinstalliert"
} else {
    # Via winget versuchen
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget uninstall --name "Sunshine" --silent 2>$null
        Write-Host "  OK: Sunshine via winget entfernt"
    } else {
        Write-Host "  Sunshine-Uninstaller nicht gefunden — bitte manuell deinstallieren" -ForegroundColor Yellow
    }
}

# Sunshine-Konfig entfernen
$sunshineConf = "$env:APPDATA\Sunshine"
if (Test-Path $sunshineConf) {
    Remove-Item -Recurse -Force $sunshineConf -ErrorAction SilentlyContinue
    Write-Host "  OK: Sunshine-Konfiguration gelöscht"
}

# ── 3. Auto-Login deaktivieren ────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/$Steps] Auto-Login deaktivieren" -ForegroundColor Yellow
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon"  -Value "0" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
Write-Host "  OK: Auto-Login deaktiviert, gespeichertes Passwort entfernt"

# ── 4. Firewall-Regeln entfernen ──────────────────────────────────────────────
Write-Host ""
Write-Host "[4/$Steps] WMC Firewall-Regeln entfernen" -ForegroundColor Yellow
$rules = @("WMC-SSH", "WMC-Agent", "WMC-Sunshine-TCP", "WMC-Sunshine-UDP")
foreach ($rule in $rules) {
    Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
    Write-Host "  OK: $rule entfernt"
}

# ── 5. Latenz-Optimierungen zurücksetzen ─────────────────────────────────────
Write-Host ""
Write-Host "[5/$Steps] Latenz-Optimierungen zurücksetzen" -ForegroundColor Yellow

# Ultimate Performance Power Plan entfernen und Balanced wiederherstellen
$balancedGuid = "381b4222-f694-41f0-9685-ff5bb260df2e"
powercfg /setactive $balancedGuid 2>$null
# Ultimate Performance Plan entfernen (falls vorhanden)
$ultGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
powercfg /delete $ultGuid 2>$null
Write-Host "  OK: Energieplan → Balanced (Standard)"

# HAGS (Hardware Accelerated GPU Scheduling) deaktivieren
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" `
    -Name "HwSchMode" -Value 1 -Type DWord -ErrorAction SilentlyContinue
Write-Host "  OK: HAGS deaktiviert"

# Interrupt Moderation wieder aktivieren
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -RegistryKeyword "*InterruptModeration" -RegistryValue 1 -ErrorAction SilentlyContinue
}
Write-Host "  OK: Interrupt Moderation wieder aktiviert"

# Visuelle Effekte auf Windows-Standard zurücksetzen
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
    -Name "VisualFXSetting" -Value 0 -ErrorAction SilentlyContinue
Write-Host "  OK: Visuelle Effekte zurückgesetzt"

# ── 6. Nagle-Algorithmus wieder aktivieren ───────────────────────────────────
Write-Host ""
Write-Host "[6/$Steps] Nagle-Algorithmus wieder aktivieren" -ForegroundColor Yellow
$tcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
Remove-ItemProperty -Path $tcpPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $tcpPath -Name "TCPNoDelay"      -ErrorAction SilentlyContinue

$ifPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
if (Test-Path $ifPath) {
    Get-ChildItem $ifPath | ForEach-Object {
        Remove-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $_.PSPath -Name "TCPNoDelay"      -ErrorAction SilentlyContinue
    }
}
Write-Host "  OK: Nagle-Algorithmus aktiv (Windows-Standard)"

# ── 7. Netzwerkadapter-Energiesparmodi wiederherstellen ──────────────────────
Write-Host ""
Write-Host "[7/$Steps] Netzwerkadapter-Einstellungen zurücksetzen" -ForegroundColor Yellow
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    $name = $_.Name
    foreach ($kw in @("*EEE", "EEELinkAdvertisement", "*GreenEthernet",
                      "*SelectiveSuspend", "EnablePME", "*FlowControl")) {
        Set-NetAdapterAdvancedProperty -Name $name `
            -RegistryKeyword $kw -RegistryValue 1 -ErrorAction SilentlyContinue
    }
    Write-Host "  OK: $name → Standard wiederhergestellt"
}

# ── 8. Fast Startup und Ruhezustand zurücksetzen ─────────────────────────────
Write-Host ""
Write-Host "[8/$Steps] Fast Startup und Energieeinstellungen zurücksetzen" -ForegroundColor Yellow
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
    /v HiberbootEnabled /t REG_DWORD /d 1 /f | Out-Null
Write-Host "  OK: Fast Startup wieder aktiviert"

# Wake-on-LAN in Netzwerktreibern zurücksetzen
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    $name = $_.Name
    foreach ($kw in @("WakeOnMagicPacket", "*WakeOnMagicPacket", "*WakeOnPattern")) {
        Set-NetAdapterAdvancedProperty -Name $name `
            -RegistryKeyword $kw -RegistryValue 0 -ErrorAction SilentlyContinue
    }
}
Write-Host "  OK: Wake-on-LAN in Netzwerktreibern deaktiviert"
Write-Host "  Hinweis: BIOS/UEFI-Einstellung muss manuell deaktiviert werden"

# ── 9. OpenSSH Server deinstallieren ─────────────────────────────────────────
Write-Host ""
Write-Host "[9/$Steps] OpenSSH Server deinstallieren" -ForegroundColor Yellow
Stop-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Disabled -ErrorAction SilentlyContinue
Remove-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction SilentlyContinue | Out-Null
Write-Host "  OK: OpenSSH Server deinstalliert"

# ── 10. WMC-Dateien + Tailscale (optional) ────────────────────────────────────
Write-Host ""
Write-Host "[10/$Steps] Aufräumen" -ForegroundColor Yellow

# WMC-Verzeichnis löschen
if (Test-Path $WmcDir) {
    Remove-Item -Recurse -Force $WmcDir -ErrorAction SilentlyContinue
    Write-Host "  OK: C:\WMC gelöscht"
}

# Tailscale — optional
Write-Host ""
$tsChoice = Read-Host "  Tailscale ebenfalls deinstallieren? (j/n)"
if ($tsChoice -match "^[jJyY]") {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget uninstall --id Tailscale.Tailscale --silent 2>$null
        Write-Host "  OK: Tailscale deinstalliert"
    } else {
        Write-Host "  Bitte Tailscale manuell über die Windows-Einstellungen deinstallieren" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Tailscale behalten"
}

# ── Zusammenfassung ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Deinstallation abgeschlossen!" -ForegroundColor Green
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Erledigt:" -ForegroundColor White
Write-Host "  ✓ WMC Agent entfernt"
Write-Host "  ✓ Sunshine deinstalliert"
Write-Host "  ✓ Auto-Login deaktiviert"
Write-Host "  ✓ Firewall-Regeln entfernt"
Write-Host "  ✓ Latenz-Optimierungen zurückgesetzt"
Write-Host "  ✓ Nagle-Algorithmus reaktiviert"
Write-Host "  ✓ Fast Startup reaktiviert"
Write-Host "  ✓ Wake-on-LAN (Treiber) deaktiviert"
Write-Host "  ✓ OpenSSH Server deinstalliert"
Write-Host "  ✓ C:\WMC gelöscht"
Write-Host ""
Write-Host "  Manuell noch nötig:" -ForegroundColor Yellow
Write-Host "  · BIOS/UEFI: Wake on LAN dort ebenfalls deaktivieren"
Write-Host ""
Write-Host "  PC-Neustart empfohlen." -ForegroundColor Cyan
