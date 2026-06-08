# optimize_windows.ps1 — Latenz-Optimierung fuer Gaming & Streaming (als Administrator ausfuehren)
#Requires -RunAsAdministrator

$ErrorActionPreference = "SilentlyContinue"
$Changes = [System.Collections.Generic.List[string]]::new()
$Warnings = [System.Collections.Generic.List[string]]::new()

Write-Host "=== Windows Latenz-Optimierung ===" -ForegroundColor Cyan
Write-Host "Ausfuehren als: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Gray
Write-Host ""

# ── 1. Ultimate Performance Power Plan ───────────────────────────────────────
Write-Host "[1/7] Ultimate Performance Power Plan..." -ForegroundColor Yellow

$ultGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
$existingPlan = powercfg /list 2>$null | Select-String $ultGuid
if (-not $existingPlan) {
    powercfg /duplicatescheme $ultGuid 2>$null | Out-Null
}

$activateResult = powercfg /setactive $ultGuid 2>$null
if ($LASTEXITCODE -eq 0) {
    $Changes.Add("Power Plan: Ultimate Performance aktiviert")
    Write-Host "  OK" -ForegroundColor Green
} else {
    $Warnings.Add("Power Plan: Ultimate Performance konnte nicht aktiviert werden")
    Write-Host "  WARNUNG: Aktivierung fehlgeschlagen" -ForegroundColor Red
}

# ── 2. Interrupt Moderation deaktivieren ─────────────────────────────────────
Write-Host "[2/7] Interrupt Moderation deaktivieren..." -ForegroundColor Yellow

$activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
$imCount = 0
foreach ($adapter in $activeAdapters) {
    Set-NetAdapterAdvancedProperty -Name $adapter.Name `
        -RegistryKeyword "*InterruptModeration" -RegistryValue 0 -ErrorAction SilentlyContinue
    if ($?) { $imCount++ }
}
if ($imCount -gt 0) {
    $Changes.Add("Interrupt Moderation: auf $imCount Adapter(n) deaktiviert")
    Write-Host "  OK ($imCount Adapter)" -ForegroundColor Green
} else {
    $Warnings.Add("Interrupt Moderation: kein kompatibler Adapter gefunden")
    Write-Host "  WARNUNG: Kein kompatibler Adapter" -ForegroundColor DarkYellow
}

# ── 3. NVIDIA Ultra Low Latency ───────────────────────────────────────────────
Write-Host "[3/7] NVIDIA Ultra Low Latency..." -ForegroundColor Yellow

$nvidiaSmiPaths = @(
    "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
    "C:\Windows\System32\nvidia-smi.exe"
)
$nvidiaSmi = $nvidiaSmiPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($nvidiaSmi) {
    & $nvidiaSmi --gpu-reset-applications-clocks 2>$null | Out-Null
    $Changes.Add("NVIDIA: Ultra Low Latency via nvidia-smi konfiguriert")
    Write-Host "  OK (nvidia-smi)" -ForegroundColor Green
} else {
    # Registry-Fallback: alle NVIDIA-Adapter-Klassen-Schlussel
    $nvidiaClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    $nvidiaKeyFound = $false

    Get-ChildItem -Path $nvidiaClassPath -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($props.ProviderName -like "*NVIDIA*" -or $props.DriverDesc -like "*NVIDIA*") {
            Set-ItemProperty -Path $_.PSPath -Name "PerfLevelSrc"          -Value 0x00002222 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $_.PSPath -Name "PowerMizerEnable"      -Value 0x00000001 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $_.PSPath -Name "PowerMizerLevel"       -Value 0x00000001 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $_.PSPath -Name "PowerMizerLevelAC"     -Value 0x00000001 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $_.PSPath -Name "NvCplUseGlobalSettings" -Value 0x00000000 -Type DWord -ErrorAction SilentlyContinue
            $nvidiaKeyFound = $true
        }
    }

    if ($nvidiaKeyFound) {
        $Changes.Add("NVIDIA: Ultra Low Latency via Registry gesetzt")
        Write-Host "  OK (Registry)" -ForegroundColor Green
    } else {
        $Warnings.Add("NVIDIA: Kein NVIDIA-Adapter in Registry gefunden")
        Write-Host "  WARNUNG: Kein NVIDIA-Adapter gefunden" -ForegroundColor DarkYellow
    }
}

# ── 4. Visuelle Effekte deaktivieren ─────────────────────────────────────────
Write-Host "[4/7] Windows visuelle Effekte reduzieren..." -ForegroundColor Yellow

$visualFxPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
if (-not (Test-Path $visualFxPath)) {
    New-Item -Path $visualFxPath -Force | Out-Null
}
Set-ItemProperty -Path $visualFxPath -Name "VisualFXSetting" -Value 2 -Type DWord -ErrorAction SilentlyContinue

# Animationen via SystemParametersInfo-Aequivalent in Registry
$dwmPath = "HKCU:\Software\Microsoft\Windows\DWM"
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay"        -Value "0"    -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "DragFullWindows"      -Value "0"    -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -ErrorAction SilentlyContinue

$animInfoPath = "HKCU:\Control Panel\Desktop"
# ANIMATIONINFO-Struktur: cbSize=36, iMinAnimate=0
$animBytes = [byte[]](0x24,0,0,0, 0,0,0,0)
Set-ItemProperty -Path $animInfoPath -Name "UserPreferencesMask" `
    -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary -ErrorAction SilentlyContinue

$Changes.Add("Visuelle Effekte: Animationen und Uebergaenge deaktiviert")
Write-Host "  OK" -ForegroundColor Green

# ── 5. Hardware-accelerated GPU Scheduling (HAGS) ─────────────────────────────
Write-Host "[5/7] Hardware-accelerated GPU Scheduling (HAGS)..." -ForegroundColor Yellow

$graphicsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
if (-not (Test-Path $graphicsPath)) {
    New-Item -Path $graphicsPath -Force | Out-Null
}
Set-ItemProperty -Path $graphicsPath -Name "HwSchMode" -Value 2 -Type DWord -ErrorAction SilentlyContinue

if ($?) {
    $Changes.Add("HAGS: Hardware GPU Scheduling aktiviert (HwSchMode=2)")
    Write-Host "  OK" -ForegroundColor Green
} else {
    $Warnings.Add("HAGS: Registrierungsschluessel konnte nicht gesetzt werden")
    Write-Host "  WARNUNG: Setzen fehlgeschlagen" -ForegroundColor Red
}

# ── 6. Nagle-Algorithmus deaktivieren ─────────────────────────────────────────
Write-Host "[6/7] Nagle-Algorithmus deaktivieren (TcpAckFrequency / TCPNoDelay)..." -ForegroundColor Yellow

$ifacesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
$nagleCount = 0

Get-ChildItem -Path $ifacesPath -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
    if ($props.IPAddress -or $props.DhcpIPAddress) {
        Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $_.PSPath -Name "TCPNoDelay"      -Value 1 -Type DWord -ErrorAction SilentlyContinue
        $nagleCount++
    }
}

# Globale TCP-Parameter
$tcpParamsPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
Set-ItemProperty -Path $tcpParamsPath -Name "TCPNoDelay"       -Value 1 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path $tcpParamsPath -Name "TcpAckFrequency"  -Value 1 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path $tcpParamsPath -Name "DisableTaskOffload" -Value 0 -Type DWord -ErrorAction SilentlyContinue

if ($nagleCount -gt 0) {
    $Changes.Add("Nagle-Algorithmus: auf $nagleCount Interface(s) deaktiviert")
    Write-Host "  OK ($nagleCount Interfaces)" -ForegroundColor Green
} else {
    $Warnings.Add("Nagle: Keine konfigurierten Netzwerkschnittstellen gefunden")
    Write-Host "  WARNUNG: Keine Interfaces gefunden" -ForegroundColor DarkYellow
}

# ── 7. Netzwerkadapter auf maximale Leistung ──────────────────────────────────
Write-Host "[7/7] Netzwerkadapter — maximale Leistung..." -ForegroundColor Yellow

$perfKeywords = @(
    "*EEE",                    # Energy Efficient Ethernet
    "*GreenEthernet",          # Green Ethernet
    "*PowerSavingMode",
    "EEELinkAdvertisement",
    "*AutoPowerSaveModeEnabled",
    "*NicAutoPowerSaver",
    "EnablePME",
    "*WakeOnMagicPacket",
    "*WakeOnPattern",
    "EnableWakeOnLan",
    "AutoDisableGigabit",
    "ReduceSpeedOnPowerDown",
    "SelectiveSuspend",
    "*SelectiveSuspend",
    "EnableSelectiveSuspend",
    "ULPMode",
    "FlowControl",
    "*FlowControl"
)

$perfAdapterCount = 0
foreach ($adapter in $activeAdapters) {
    $anySet = $false
    foreach ($kw in $perfKeywords) {
        $current = Get-NetAdapterAdvancedProperty -Name $adapter.Name `
            -RegistryKeyword $kw -ErrorAction SilentlyContinue
        if ($current) {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name `
                -RegistryKeyword $kw -RegistryValue 0 -ErrorAction SilentlyContinue
            $anySet = $true
        }
    }
    if ($anySet) { $perfAdapterCount++ }
}

if ($perfAdapterCount -gt 0) {
    $Changes.Add("Netzwerkadapter: Energiesparmodi auf $perfAdapterCount Adapter(n) deaktiviert")
    Write-Host "  OK ($perfAdapterCount Adapter)" -ForegroundColor Green
} else {
    Write-Host "  INFO: Keine Energiespar-Eigenschaften gefunden (Adapter bereits optimal)" -ForegroundColor Gray
}

# ── Zusammenfassung ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " ZUSAMMENFASSUNG" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($Changes.Count -gt 0) {
    Write-Host ""
    Write-Host "Erfolgreich angewendet:" -ForegroundColor Green
    foreach ($c in $Changes) {
        Write-Host "  [+] $c" -ForegroundColor Green
    }
}

if ($Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnungen / nicht angewendet:" -ForegroundColor DarkYellow
    foreach ($w in $Warnings) {
        Write-Host "  [!] $w" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host " NEUSTART ERFORDERLICH" -ForegroundColor Magenta
Write-Host " Bitte Windows neu starten, damit alle Aenderungen" -ForegroundColor Magenta
Write-Host " wirksam werden (HAGS, Treiber, Registry-Werte)." -ForegroundColor Magenta
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""
