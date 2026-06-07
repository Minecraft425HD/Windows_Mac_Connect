#!/usr/bin/env bash
# setup_relay.sh — Raspberry Pi 3B/3B+ (Raspberry Pi OS / Debian)
# Erstellt WMC-Relay als systemd-Dienst

set -euo pipefail

INSTALL_DIR=/opt/wmc
ENV_FILE=/etc/wmc/relay.env

echo "=== WMC Relay Setup (Raspberry Pi) ==="
echo ""

# Root-Check
if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausführen:  sudo bash scripts/setup_relay.sh"
    exit 1
fi

# 1. System-Pakete
echo "[1/6] System-Pakete installieren..."
apt-get update -qq
# python3-venv ist auf Pi manchmal nicht dabei; pip3 separat wegen Debian-Eigenheit
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip git curl \
    iputils-ping 2>/dev/null | tail -1

# 2. System-User anlegen
echo "[2/6] System-User 'wmc' anlegen..."
if ! id wmc &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin wmc
    echo "  User 'wmc' erstellt"
else
    echo "  User 'wmc' existiert bereits"
fi

# 3. Dateien installieren
echo "[3/6] Relay-Server installieren..."
mkdir -p "$INSTALL_DIR/relay"

# Quelle: relativ zum Repo-Root (Skript liegt in scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cp "$REPO_ROOT/relay/relay_server.py" "$INSTALL_DIR/relay/"
cp "$REPO_ROOT/relay/requirements.txt" "$INSTALL_DIR/relay/"

# Python-Virtualenv erstellen (Pi 3B ist armv7l — pip-Pakete sind kompatibel)
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/relay/requirements.txt"

chown -R wmc:wmc "$INSTALL_DIR"
echo "  Installiert in $INSTALL_DIR"

# 4. Konfig-Datei erstellen (nur beim ersten Mal)
echo "[4/6] Konfiguration erstellen..."
mkdir -p /etc/wmc
chmod 750 /etc/wmc
chown root:wmc /etc/wmc

if [[ ! -f "$ENV_FILE" ]]; then
    TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    cat > "$ENV_FILE" <<EOF
# WMC Relay Konfiguration
# Anpassen und dann: sudo systemctl restart wmc-relay

WMC_API_TOKEN=$TOKEN
WMC_PC_MAC=AA:BB:CC:DD:EE:FF
WMC_PC_IP=192.168.1.100
WMC_AGENT_PORT=9876
WMC_WOL_BROADCAST=255.255.255.255
WMC_RELAY_PORT=8765
EOF
    chmod 640 "$ENV_FILE"
    chown root:wmc "$ENV_FILE"

    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  API Token (notieren!):                              ║"
    echo "  ║  $TOKEN  ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "  Konfiguration: $ENV_FILE"
    echo "  → Bitte WMC_PC_MAC und WMC_PC_IP eintragen!"
else
    echo "  Konfig bereits vorhanden ($ENV_FILE) — nicht überschrieben"
fi

# 5. systemd-Service
echo "[5/7] Watchdog installieren..."
cp "$REPO_ROOT/relay/watchdog.py" "$INSTALL_DIR/relay/"
mkdir -p /var/log/wmc
chown wmc:wmc /var/log/wmc
cp "$REPO_ROOT/relay/watchdog.service" /etc/systemd/system/wmc-watchdog.service

echo "[6/7] systemd-Services registrieren..."
cat > /etc/systemd/system/wmc-relay.service <<'UNIT'
[Unit]
Description=WMC Relay Server
After=network-online.target
Wants=network-online.target

[Service]
User=wmc
WorkingDirectory=/opt/wmc/relay
EnvironmentFile=/etc/wmc/relay.env
ExecStart=/opt/wmc/venv/bin/gunicorn \
    --bind 0.0.0.0:${WMC_RELAY_PORT:-8765} \
    --workers 1 \
    --timeout 30 \
    relay_server:app
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable wmc-relay wmc-watchdog
systemctl restart wmc-relay
sleep 2
systemctl restart wmc-watchdog

echo "[7/7] Status prüfen..."
FAIL=0
for svc in wmc-relay wmc-watchdog; do
    if systemctl is-active --quiet "$svc"; then
        echo "  ✓ $svc läuft"
    else
        echo "  ✗ $svc fehlgeschlagen:"
        journalctl -u "$svc" -n 10 --no-pager
        FAIL=1
    fi
done
[[ $FAIL -eq 1 ]] && exit 1

# 6. Tailscale installieren (falls nicht vorhanden)
if ! command -v tailscale &>/dev/null; then
    echo ""
    echo ">>> Tailscale nicht gefunden. Installieren? (empfohlen) [j/N]"
    read -r answer
    if [[ "$answer" =~ ^[jJyY]$ ]]; then
        curl -fsSL https://tailscale.com/install.sh | sh
        echo "  Tailscale installiert. Jetzt verbinden:"
        echo "  sudo tailscale up"
    fi
fi

# Tailscale-IP anzeigen (falls aktiv)
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. Konfig bearbeiten:"
echo "     sudo nano $ENV_FILE"
echo "     → WMC_PC_MAC=  (MAC-Adresse des Gaming-PCs)"
echo "     → WMC_PC_IP=   (lokale IP des Gaming-PCs)"
echo "     sudo systemctl restart wmc-relay"
echo ""
if [[ -n "$TAILSCALE_IP" ]]; then
    echo "  2. Relay-URL für wmc config auf dem Mac:"
    echo "     http://$TAILSCALE_IP:8765"
else
    echo "  2. Tailscale verbinden:  sudo tailscale up"
    echo "     Dann Tailscale-IP holen: tailscale ip -4"
    echo "     Relay-URL: http://<tailscale-ip>:8765"
fi
echo ""
echo "  3. MAC-Adresse des Gaming-PCs herausfinden:"
echo "     → Windows: ipconfig /all | findstr 'Physical'"
echo "     → oder: arp -a (vom Pi aus, wenn PC im Netz ist)"
echo "═══════════════════════════════════════════════════════"
