#!/usr/bin/env bash
# setup_mac.sh — Run on MacBook
# Installs the wmc CLI tool

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/../client"
INSTALL_PATH="/usr/local/bin/wmc"

echo "=== WMC Mac Client Setup ==="

# Copy script
cp "$CLIENT_DIR/wmc.py" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

# Ensure shebang works
if ! head -1 "$INSTALL_PATH" | grep -q python3; then
    sed -i '' '1s|.*|#!/usr/bin/env python3|' "$INSTALL_PATH"
fi

echo "Installed: $INSTALL_PATH"
echo ""
echo "Run 'wmc config' to set your relay URL and API token."
echo ""
echo "Example:"
echo "  wmc status"
echo "  wmc wake"
echo "  wmc shutdown"
