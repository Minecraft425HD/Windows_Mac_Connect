#!/usr/bin/env bash
# setup_relay.sh — Run on Raspberry Pi / always-on Linux device
# Creates user, installs dependencies, registers systemd service

set -euo pipefail

INSTALL_DIR=/opt/wmc
ENV_FILE=/etc/wmc/relay.env

echo "=== WMC Relay Setup ==="

# 1. Create system user
if ! id wmc &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin wmc
    echo "Created system user: wmc"
fi

# 2. Install Python deps
apt-get install -y python3 python3-venv python3-pip --quiet

# 3. Copy files
mkdir -p "$INSTALL_DIR/relay"
cp relay/relay_server.py "$INSTALL_DIR/relay/"
cp relay/requirements.txt "$INSTALL_DIR/relay/"

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/relay/requirements.txt"

chown -R wmc:wmc "$INSTALL_DIR"

# 4. Create env file
mkdir -p /etc/wmc
chmod 700 /etc/wmc

if [[ ! -f "$ENV_FILE" ]]; then
    TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    cat > "$ENV_FILE" <<EOF
WMC_API_TOKEN=$TOKEN
WMC_PC_MAC=AA:BB:CC:DD:EE:FF
WMC_PC_IP=192.168.1.100
WMC_AGENT_PORT=9876
WMC_WOL_BROADCAST=255.255.255.255
WMC_RELAY_PORT=8765
EOF
    chmod 600 "$ENV_FILE"
    echo ""
    echo ">>> Generated API token: $TOKEN"
    echo ">>> Edit $ENV_FILE and set WMC_PC_MAC and WMC_PC_IP"
    echo ""
fi

# 5. Install and start service
cp relay/relay.service /etc/systemd/system/wmc-relay.service
systemctl daemon-reload
systemctl enable --now wmc-relay
echo "Service status:"
systemctl status wmc-relay --no-pager

echo ""
echo "=== Setup complete ==="
echo "Relay listens on 127.0.0.1:8765 (access via Tailscale or reverse proxy)"
