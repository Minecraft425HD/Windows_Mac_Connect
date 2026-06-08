#!/usr/bin/env bash
# setup_mac.sh — MacBook
# Installiert: wmc CLI · Moonlight · Tailscale · fuehrt 'wmc config' durch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/../client"
INSTALL_PATH="/usr/local/bin/wmc"
STEPS=4

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         WMC Mac Setup — MacBook                     ║"
echo "║  wmc CLI · Moonlight · Tailscale                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. wmc CLI ────────────────────────────────────────────────────────────────
echo "[1/$STEPS] wmc CLI installieren"
echo "  Der Hauptbefehl: wmc stream, wmc wake, wmc shutdown, ..."
sudo cp "$CLIENT_DIR/wmc.py" "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"
echo "  OK: wmc installiert -> $INSTALL_PATH"
echo "  Verfuegbare Befehle: wmc stream / wake / shutdown / sleep / status / ping"

# ── 2. Homebrew + Moonlight ───────────────────────────────────────────────────
echo ""
echo "[2/$STEPS] Moonlight installieren"
echo "  Game-Streaming-Client — uebertraegt Bild + Ton vom Gaming-PC."

if ! command -v brew &>/dev/null; then
    echo "  Homebrew (Mac-Paketmanager) nicht gefunden — wird installiert..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Homebrew PATH fuer Apple Silicon und Intel
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi

if command -v brew &>/dev/null; then
    if brew list --cask moonlight &>/dev/null 2>&1; then
        echo "  OK: Moonlight bereits installiert"
    else
        echo "  Installiere Moonlight..."
        brew install --cask moonlight
        echo "  OK: Moonlight installiert"
    fi
else
    echo "  Homebrew nicht verfuegbar — Moonlight manuell installieren:"
    echo "  https://moonlight-stream.org"
fi

# ── 3. Tailscale ─────────────────────────────────────────────────────────────
echo ""
echo "[3/$STEPS] Tailscale pruefen"
echo "  VPN-Tunnel zum Raspberry Pi und Gaming-PC — funktioniert weltweit."

TAILSCALE_OK=false
if command -v tailscale &>/dev/null || [[ -d "/Applications/Tailscale.app" ]]; then
    echo "  OK: Tailscale bereits installiert"
    TAILSCALE_OK=true
else
    echo "  Tailscale nicht gefunden."
    if command -v brew &>/dev/null; then
        echo "  Installiere Tailscale..."
        brew install --cask tailscale
        echo "  OK: Tailscale installiert"
        TAILSCALE_OK=true
    else
        echo "  Manuell: https://tailscale.com/download/macos"
    fi
fi

if [[ "$TAILSCALE_OK" == true ]]; then
    # App starten falls noch nicht aktiv
    if ! tailscale status &>/dev/null 2>&1; then
        open "/Applications/Tailscale.app" 2>/dev/null || true
        echo "  Tailscale gestartet — bitte im Menu-Bar einloggen"
        echo "  (Mit demselben Account wie auf Pi und Gaming-PC!)"
        sleep 3
    else
        echo "  Tailscale laeuft"
    fi
fi

# ── 4. wmc konfigurieren ──────────────────────────────────────────────────────
echo ""
echo "[4/$STEPS] wmc konfigurieren"
echo "  Relay-URL und API Token eingeben (vom Raspberry Pi Setup)."
echo ""
echo "  Benoetigt:"
echo "    Relay-URL:  http://<tailscale-ip-des-pi>:8765"
echo "    API Token:  wurde am Ende von setup_relay.sh angezeigt"
echo "                (auch lesbar mit: sudo cat /etc/wmc/relay.env auf dem Pi)"
echo ""
read -rp "  Jetzt konfigurieren? (j/n): " cfg_answer
if [[ "$cfg_answer" =~ ^[jJyY]$ ]]; then
    wmc config
else
    echo "  Spaeter konfigurieren mit: wmc config"
fi

# ── Zusammenfassung ───────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Setup abgeschlossen!"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Einmalig: Moonlight mit Sunshine pairen"
echo "    1. Moonlight oeffnen"
echo "    2. Gaming-PC in der Liste anklicken"
echo "    3. PIN eingeben"
echo "    4. Auf dem Gaming-PC: https://localhost:47990 -> PIN bestaetigen"
echo ""
echo "  Danach fuer immer:"
echo "    wmc stream      -> PC einschalten + Moonlight starten"
echo "    wmc shutdown    -> PC ausschalten"
echo "    wmc status      -> Ist der PC an?"
echo "    wmc ping        -> Latenz messen"
echo ""
echo "  iPhone: http://<relay-ip>:8765  im Safari"
echo "          -> 'Zum Home-Bildschirm' -> App-Icon"
