#!/usr/bin/env bash
# setup_mac.sh — MacBook
# Installiert wmc CLI + Moonlight Game-Streaming-Client

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/../client"
INSTALL_PATH="/usr/local/bin/wmc"

echo "=== WMC Mac Setup ==="
echo ""

# 1. wmc CLI installieren
echo "[1/3] wmc CLI installieren..."
sudo cp "$CLIENT_DIR/wmc.py" "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"
echo "  Installiert: $INSTALL_PATH"

# 2. Moonlight installieren (Homebrew)
echo ""
echo "[2/3] Moonlight installieren..."
if ! command -v brew &>/dev/null; then
    echo "  Homebrew nicht gefunden. Installieren? [j/N]"
    read -r answer
    if [[ "$answer" =~ ^[jJyY]$ ]]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        echo "  Moonlight kann ohne Homebrew nicht automatisch installiert werden."
        echo "  Manuell: https://moonlight-stream.org"
    fi
fi

if command -v brew &>/dev/null; then
    if brew list --cask moonlight &>/dev/null 2>&1; then
        echo "  Moonlight bereits installiert"
    else
        brew install --cask moonlight
        echo "  Moonlight installiert"
    fi
fi

# 3. Tailscale installieren (falls nicht vorhanden)
echo ""
echo "[3/3] Tailscale prüfen..."
if ! command -v tailscale &>/dev/null && ! [ -d "/Applications/Tailscale.app" ]; then
    echo "  Tailscale nicht gefunden."
    if command -v brew &>/dev/null; then
        echo "  Installieren? [j/N]"
        read -r answer
        if [[ "$answer" =~ ^[jJyY]$ ]]; then
            brew install --cask tailscale
            echo "  Tailscale installiert. Bitte aus den Anwendungen starten und einloggen."
        fi
    else
        echo "  Manuell: https://tailscale.com/download/macos"
    fi
else
    echo "  Tailscale vorhanden"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Setup abgeschlossen!"
echo ""
echo "  Konfiguration:"
echo "    wmc config"
echo "    → Relay URL:  http://<tailscale-ip-des-pi>:8765"
echo "    → API Token:  <aus /etc/wmc/relay.env auf dem Pi>"
echo ""
echo "  Spielen:"
echo "    wmc stream          PC einschalten + Moonlight starten"
echo "    wmc wake            Nur einschalten"
echo "    wmc shutdown        Ausschalten"
echo "═══════════════════════════════════════════════════"
