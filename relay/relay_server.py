"""
WMC Relay Server
Runs on an always-on home device (Raspberry Pi, NAS, etc.)
Receives authenticated commands from the internet and acts locally.
"""

import os
import socket
import struct
import subprocess
import time
from functools import wraps

from flask import Flask, request, jsonify

app = Flask(__name__)

# --- Config (set via environment variables) ---
API_TOKEN = os.environ["WMC_API_TOKEN"]         # shared secret, min 32 chars
PC_MAC    = os.environ["WMC_PC_MAC"]            # e.g. "AA:BB:CC:DD:EE:FF"
PC_IP     = os.environ.get("WMC_PC_IP", "")    # for status ping (optional but recommended)
PC_AGENT_PORT = int(os.environ.get("WMC_AGENT_PORT", "9876"))
WOL_BROADCAST = os.environ.get("WMC_WOL_BROADCAST", "255.255.255.255")
WOL_PORT       = int(os.environ.get("WMC_WOL_PORT", "9"))


# --- Auth ---

def require_token(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != API_TOKEN:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return wrapper


# --- Wake-on-LAN ---

def _build_magic_packet(mac: str) -> bytes:
    mac_bytes = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(mac_bytes) != 6:
        raise ValueError("Invalid MAC address")
    return b"\xff" * 6 + mac_bytes * 16


def send_wol(mac: str, broadcast: str = WOL_BROADCAST, port: int = WOL_PORT):
    packet = _build_magic_packet(mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(packet, (broadcast, port))


# --- PC reachability check ---

def pc_is_online(ip: str, timeout: float = 1.5) -> bool:
    if not ip:
        return None  # unknown
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", str(int(timeout * 1000)), ip],
            capture_output=True, timeout=timeout + 1
        )
        return result.returncode == 0
    except Exception:
        return False


def forward_to_agent(command: str) -> dict:
    """Send a command string to the Windows agent over TCP."""
    if not PC_IP:
        return {"error": "PC_IP not configured"}
    try:
        with socket.create_connection((PC_IP, PC_AGENT_PORT), timeout=5) as s:
            s.sendall((command + "\n").encode())
            response = s.recv(256).decode().strip()
        return {"ok": True, "response": response}
    except Exception as e:
        return {"error": str(e)}


# --- Routes ---

@app.route("/status", methods=["GET"])
@require_token
def status():
    online = pc_is_online(PC_IP)
    return jsonify({
        "pc_online": online,
        "pc_ip": PC_IP or "not configured",
        "relay": "ok",
    })


@app.route("/wake", methods=["POST"])
@require_token
def wake():
    try:
        send_wol(PC_MAC)
        return jsonify({"ok": True, "message": "Magic packet sent", "mac": PC_MAC})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/shutdown", methods=["POST"])
@require_token
def shutdown():
    result = forward_to_agent("shutdown")
    return jsonify(result), 200 if result.get("ok") else 502


@app.route("/sleep", methods=["POST"])
@require_token
def sleep_pc():
    result = forward_to_agent("sleep")
    return jsonify(result), 200 if result.get("ok") else 502


@app.route("/hibernate", methods=["POST"])
@require_token
def hibernate():
    result = forward_to_agent("hibernate")
    return jsonify(result), 200 if result.get("ok") else 502


@app.route("/lock", methods=["POST"])
@require_token
def lock():
    result = forward_to_agent("lock")
    return jsonify(result), 200 if result.get("ok") else 502


if __name__ == "__main__":
    port = int(os.environ.get("WMC_RELAY_PORT", "8765"))
    # In production use a proper WSGI server (gunicorn) + TLS termination
    app.run(host="0.0.0.0", port=port, debug=False)
