# set_mode.ps1 — Gaming-PC (als Administrator ausführen)
# Wechselt zwischen Stream-Modus und Lokal-Modus
#
# Streammodus:  Sunshine aktiv, Ultimate Performance, Netzwerk optimiert
# Lokalmodus:   Sunshine pausiert (spart Ressourcen), Balanced-Plan

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory)]
    [ValidateSet("stream", "lokal", "status")]
    [string]$Modus
)

$ErrorActionPreference = "Continue"

$BALANCED_GUID     = "381b4222-f694-41f0-9685-ff5bb260df2e"
$PERFORMANCE_GUID  = "e9a42b02-d5df-448d-aa00-03f14749eb61"  # Ultimate Performance
$MODE_FILE         = "C:\WMC\current_mode.txt"

function Get-CurrentMode {
    if (Test-Path $MODE_FILE) { return (Get-Content $MODE_FILE).Trim() }
    # Ableiten aus Sunshine-Status
    $svc = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { return "stream" }
    return "lokal"
}

function Write-Mode($m) {
    New-Item -ItemType Directory -Force -Path "C:\WMC" | Out-Null
    Set-Content -Path $MODE_FILE -Value $m
}

# ── Status anzeigen ──────────────────────────────────────────────────────────
if ($Modus -eq "status") {
    $current = Get-CurrentMode
    $svc     = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    $plan    = (powercfg /getactivescheme) -replace ".*GUID: ([a-f0-9-]+).*", '$1'

    Write-Host ""
    Write-Host "  Aktueller Modus: " -NoNewline
    if ($current -eq "stream") {
        Write-Host "STREAMMODUS" -ForegroundColor Cyan
    } else {
        Write-Host "LOKALMODUS" -ForegroundColor Green
    }
    Write-Host "  Sunshine:        $(if ($svc -and $svc.Status -eq 'Running') { 'aktiv' } else { 'pausiert' })"
    Write-Host "  Energieplan:     $(if ($plan -eq $PERFORMANCE_GUID) { 'Ultimate Performance' } else { 'Standard' })"
    Write-Host ""
    exit 0
}

# ── Streammodus ───────────────────────────────────────────────────────────────
if ($Modus -eq "stream") {
    Write-Host ""
    Write-Host "  Wechsle zu STREAMMODUS..." -ForegroundColor Cyan
    Write-Host ""

    # Sunshine starten
    Write-Host "  [1/3] Sunshine starten..."
    $svc = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    if ($svc) {
        Start-Service -Name "SunshineService" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $svc.Refresh()
        if ($svc.Status -eq "Running") {
            Write-Host "        OK: Sunshine laeuft"
        } else {
            Write-Host "        FEHLER: Sunshine konnte nicht gestartet werden" -ForegroundColor Red
        }
    } else {
        Write-Host "        Sunshine nicht installiert — setup_windows.ps1 ausfuehren" -ForegroundColor Yellow
    }

    # Ultimate Performance aktivieren
    Write-Host "  [2/3] Energieplan: Ultimate Performance..."
    $exists = powercfg /list | Select-String $PERFORMANCE_GUID
    if (-not $exists) {
        powercfg /duplicatescheme $PERFORMANCE_GUID 2>$null
    }
    powercfg /setactive $PERFORMANCE_GUID 2>$null
    Write-Host "        OK: Ultimate Performance aktiv"

    # Netzwerk-Optimierungen sicherstellen (Nagle aus, Interrupt Moderation aus)
    Write-Host "  [3/3] Netzwerk auf Streaming optimieren..."
    $tcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    Set-ItemProperty -Path $tcpPath -Name "TcpAckFrequency" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $tcpPath -Name "TCPNoDelay"      -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        Set-NetAdapterAdvancedProperty -Name $_.Name `
            -RegistryKeyword "*InterruptModeration" -RegistryValue 0 -ErrorAction SilentlyContinue
    }
    Write-Host "        OK: Netzwerk optimiert"

    Write-Mode "stream"

    Write-Host ""
    Write-Host "  STREAMMODUS aktiv." -ForegroundColor Cyan
    Write-Host "  Sunshine ist bereit — 'wmc stream' auf dem MacBook starten." -ForegroundColor Cyan
    Write-Host ""
}

# ── Lokalmodus ────────────────────────────────────────────────────────────────
if ($Modus -eq "lokal") {
    Write-Host ""
    Write-Host "  Wechsle zu LOKALMODUS..." -ForegroundColor Green
    Write-Host ""

    # Sunshine pausieren
    Write-Host "  [1/3] Sunshine pausieren..."
    $svc = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Stop-Service -Name "SunshineService" -ErrorAction SilentlyContinue
        Write-Host "        OK: Sunshine pausiert (spart GPU/CPU Ressourcen)"
    } else {
        Write-Host "        OK: Sunshine war bereits inaktiv"
    }

    # Balanced-Plan aktivieren
    Write-Host "  [2/3] Energieplan: Balanced..."
    powercfg /setactive $BALANCED_GUID 2>$null
    Write-Host "        OK: Balanced-Plan aktiv"

    # Netzwerk-Optimierungen zurücksetzen (nicht nötig beim lokalen Spielen)
    Write-Host "  [3/3] Netzwerk-Einstellungen zurücksetzen..."
    $tcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    Remove-ItemProperty -Path $tcpPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $tcpPath -Name "TCPNoDelay"      -ErrorAction SilentlyContinue
    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        Set-NetAdapterAdvancedProperty -Name $_.Name `
            -RegistryKeyword "*InterruptModeration" -RegistryValue 1 -ErrorAction SilentlyContinue
    }
    Write-Host "        OK: Netzwerk-Einstellungen Standard"

    Write-Mode "lokal"

    Write-Host ""
    Write-Host "  LOKALMODUS aktiv." -ForegroundColor Green
    Write-Host "  PC fuer direktes Spielen optimiert." -ForegroundColor Green
    Write-Host ""
}
