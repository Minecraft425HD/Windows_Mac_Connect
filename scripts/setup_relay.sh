#!/usr/bin/env bash
# setup_relay.sh — Raspberry Pi 3B/3B+ (Raspberry Pi OS / Debian)
# Richtet WMC Relay + Watchdog als systemd-Dienste ein

set -euo pipefail

INSTALL_DIR=/opt/wmc
ENV_FILE=/etc/wmc/relay.env
STEPS=7

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║      WMC Relay Setup — Raspberry Pi                 ║"
echo "║  Relay · Watchdog · Wake-on-LAN · Tailscale         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausfuehren:  sudo bash scripts/setup_relay.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── 1. System-Pakete ──────────────────────────────────────────────────────────
echo "[1/$STEPS] System-Pakete installieren"
echo "  Python, pip, git, ping — alles was der Relay-Server braucht."
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip git curl iputils-ping 2>/dev/null \
    | grep -E "upgrade|install|already" || true
echo "  OK: Pakete aktuell"

# ── 2. System-User ────────────────────────────────────────────────────────────
echo ""
echo "[2/$STEPS] System-User 'wmc' anlegen"
echo "  Laeuft als eigener Benutzer ohne Login-Rechte (Sicherheit)."
if ! id wmc &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin wmc
    echo "  OK: User 'wmc' erstellt"
else
    echo "  OK: User 'wmc' existiert bereits"
fi

# ── 3. Relay + Watchdog installieren ─────────────────────────────────────────
echo ""
echo "[3/$STEPS] Relay-Server + Watchdog installieren"
echo "  relay_server.py: empfaengt Befehle (Wake, Shutdown, etc.)"
echo "  watchdog.py:     ueberwacht den Relay und startet ihn neu falls noetig"
mkdir -p "$INSTALL_DIR/relay"
cp "$REPO_ROOT/relay/relay_server.py" "$INSTALL_DIR/relay/"
cp "$REPO_ROOT/relay/watchdog.py"     "$INSTALL_DIR/relay/"
cp "$REPO_ROOT/relay/requirements.txt" "$INSTALL_DIR/relay/"
mkdir -p /var/log/wmc
chown wmc:wmc /var/log/wmc

echo "  Erstelle Python-Virtualenv (kann 1-2 Minuten dauern)..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/relay/requirements.txt"
chown -R wmc:wmc "$INSTALL_DIR"
echo "  OK: Installiert in $INSTALL_DIR"

# ── 4. Konfiguration ──────────────────────────────────────────────────────────
echo ""
echo "[4/$STEPS] Konfiguration"
echo "  Erstellt API-Token und fragt MAC-Adresse + IP des Gaming-PCs ab."
mkdir -p /etc/wmc
chmod 750 /etc/wmc
chown root:wmc /etc/wmc

if [[ ! -f "$ENV_FILE" ]]; then
    TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

    # Interaktiv: MAC-Adresse und PC-IP abfragen
    echo ""
    echo "  Bitte die folgenden Angaben zum Gaming-PC eingeben."
    echo "  (Auf dem Gaming-PC in PowerShell: ipconfig /all)"
    echo ""
    read -rp "  MAC-Adresse des Gaming-PCs (z.B. AA:BB:CC:DD:EE:FF): " PC_MAC
    read -rp "  Lokale IP-Adresse des Gaming-PCs (z.B. 192.168.1.100): " PC_IP
    # Fallback auf Platzhalter wenn leer
    PC_MAC="${PC_MAC:-AA:BB:CC:DD:EE:FF}"
    PC_IP="${PC_IP:-192.168.1.100}"

    cat > "$ENV_FILE" <<EOF
# WMC Relay Konfiguration
# Aendern und dann: sudo systemctl restart wmc-relay wmc-watchdog

WMC_API_TOKEN=$TOKEN
WMC_PC_MAC=$PC_MAC
WMC_PC_IP=$PC_IP
WMC_AGENT_PORT=9876
WMC_WOL_BROADCAST=255.255.255.255
WMC_RELAY_PORT=8765
EOF
    chmod 640 "$ENV_FILE"
    chown root:wmc "$ENV_FILE"

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  API Token — NOTIEREN (wird spaeter fuer 'wmc config'  │"
    echo "  │  auf dem MacBook benoetigt):                            │"
    echo "  │                                                         │"
    echo "  │  $TOKEN  │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
else
    echo "  OK: Konfig bereits vorhanden ($ENV_FILE)"
    TOKEN=$(grep WMC_API_TOKEN "$ENV_FILE" | cut -d= -f2)
fi

# ── 5. systemd-Services ───────────────────────────────────────────────────────
echo ""
echo "[5/$STEPS] systemd-Services registrieren"
echo "  Relay und Watchdog starten automatisch beim Boot."

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

cp "$REPO_ROOT/relay/watchdog.service" /etc/systemd/system/wmc-watchdog.service

systemctl daemon-reload
systemctl enable wmc-relay wmc-watchdog
systemctl restart wmc-relay
sleep 2
systemctl restart wmc-watchdog

# ── 6. Services pruefen ───────────────────────────────────────────────────────
echo ""
echo "[6/$STEPS] Services pruefen"
FAIL=0
for svc in wmc-relay wmc-watchdog; do
    if systemctl is-active --quiet "$svc"; then
        echo "  OK: $svc laeuft"
    else
        echo "  FEHLER: $svc nicht aktiv — Logs:"
        journalctl -u "$svc" -n 15 --no-pager
        FAIL=1
    fi
done
[[ $FAIL -eq 1 ]] && exit 1

# ── 7. Tailscale ──────────────────────────────────────────────────────────────
echo ""
echo "[7/$STEPS] Tailscale (sicheres Internet-VPN)"
echo "  Verbindet Pi, Gaming-PC und MacBook — kein Port-Forwarding noetig."
if ! command -v tailscale &>/dev/null; then
    echo "  Installiere Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    echo ""
    echo "  Tailscale verbinden (Link im Browser oeffnen):"
    echo "  sudo tailscale up"
    echo ""
    read -rp "  Jetzt verbinden? Startet Browser-Login. (j/n): " ts_answer
    if [[ "$ts_answer" =~ ^[jJyY]$ ]]; then
        tailscale up --accept-routes || true
    fi
else
    echo "  OK: Tailscale bereits installiert"
fi

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

# ── Zusammenfassung ───────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Setup abgeschlossen!"
echo "══════════════════════════════════════════════════════"
echo ""
if [[ -n "$TAILSCALE_IP" ]]; then
    echo "  Relay-URL fuer 'wmc config' auf dem MacBook:"
    echo "    http://$TAILSCALE_IP:8765"
    echo ""
    echo "  API Token fuer 'wmc config':"
    echo "    $TOKEN"
else
    echo "  Tailscale noch nicht verbunden."
    echo "  Nach dem Verbinden:"
    echo "    tailscale ip -4     -> zeigt Relay-URL-IP"
    echo "    Relay-URL: http://<tailscale-ip>:8765"
    echo ""
    echo "  API Token fuer 'wmc config':"
    echo "    $TOKEN"
fi
echo ""
echo "  Konfig nachtraeglich aendern:"
echo "    sudo nano $ENV_FILE"
echo "    sudo systemctl restart wmc-relay"
echo ""
echo "  Weiter mit: MacBook einrichten (setup_mac.sh)"
