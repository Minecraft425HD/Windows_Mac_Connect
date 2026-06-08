"""
WMC Relay Server
Runs on an always-on home device (Raspberry Pi, NAS, etc.)
Receives authenticated commands from the internet and acts locally.
"""

import os
import secrets as _secrets
import socket
import struct
import subprocess
import time
from functools import wraps

from flask import Flask, request, jsonify, make_response, redirect

app = Flask(__name__)

# --- Config (set via environment variables) ---
API_TOKEN = os.environ["WMC_API_TOKEN"]         # shared secret, min 32 chars
PC_MAC    = os.environ["WMC_PC_MAC"]            # e.g. "AA:BB:CC:DD:EE:FF" or comma-separated for WLAN+LAN
PC_MACS   = [m.strip() for m in PC_MAC.split(",") if m.strip()]
PC_IP     = os.environ.get("WMC_PC_IP", "")    # for status ping (optional but recommended)
PC_AGENT_PORT = int(os.environ.get("WMC_AGENT_PORT", "9876"))
WOL_BROADCAST = os.environ.get("WMC_WOL_BROADCAST", "255.255.255.255")
WOL_PORT       = int(os.environ.get("WMC_WOL_PORT", "9"))

# --- Session store ---
_SESSIONS: dict[str, float] = {}   # token -> expiry timestamp
SESSION_TTL = 60 * 60 * 24 * 30   # 30 days


def _new_session_cookie() -> str:
    return _secrets.token_hex(32)


def _session_valid(token: str) -> bool:
    expiry = _SESSIONS.get(token)
    if expiry is None:
        return False
    if time.time() > expiry:
        _SESSIONS.pop(token, None)
        return False
    return True


def _create_session() -> str:
    tok = _new_session_cookie()
    _SESSIONS[tok] = time.time() + SESSION_TTL
    return tok


# --- Auth ---

def require_token(f):
    """Auth decorator for API routes (CLI + web UI).
    Accepts: wmc_session cookie OR Bearer header token.
    """
    @wraps(f)
    def wrapper(*args, **kwargs):
        # 1. Session cookie (set by web UI login flow)
        cookie = request.cookies.get("wmc_session", "")
        if cookie and _session_valid(cookie):
            return f(*args, **kwargs)
        # 2. Bearer token (CLI)
        auth = request.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        if token and token == API_TOKEN:
            return f(*args, **kwargs)
        return jsonify({"error": "Unauthorized"}), 401
    return wrapper


def require_session_or_token(f):
    """Auth decorator for the web UI GET / route.
    Handles session cookies, ?token= param, and login form.
    """
    @wraps(f)
    def wrapper(*args, **kwargs):
        # 1. Valid session cookie -> serve page
        cookie = request.cookies.get("wmc_session", "")
        if cookie and _session_valid(cookie):
            return f(*args, **kwargs)

        # 2. POST /?login=1 — handle login form submission
        if request.method == "POST" and request.args.get("login") == "1":
            form_token = request.form.get("token", "")
            if form_token == API_TOKEN:
                session_tok = _create_session()
                resp = make_response(redirect("/", 302))
                resp.set_cookie(
                    "wmc_session", session_tok,
                    max_age=SESSION_TTL, httponly=True,
                    samesite="Lax", secure=False  # set secure=True if behind HTTPS
                )
                return resp
            return _login_page("Falsches Passwort."), 401

        # 3. ?token= query param OR Bearer header -> create session and serve
        query_token = request.args.get("token", "")
        auth = request.headers.get("Authorization", "")
        bearer_token = auth[7:] if auth.startswith("Bearer ") else ""
        candidate = query_token or bearer_token
        if candidate == API_TOKEN:
            session_tok = _create_session()
            resp = make_response(f(*args, **kwargs))
            resp.set_cookie(
                "wmc_session", session_tok,
                max_age=SESSION_TTL, httponly=True,
                samesite="Lax", secure=False
            )
            return resp

        # 4. Nothing valid -> show login page
        return _login_page(), 200
    return wrapper


LOGIN_HTML = """<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <title>Gaming PC – Anmelden</title>
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    :root {{
      --bg: #0f0f13;
      --surface: #1c1c24;
      --border: #2e2e3e;
      --text: #e8e8f0;
      --muted: #888899;
      --blue: #3b82f6;
      --red: #ef4444;
    }}
    body {{
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      min-height: 100dvh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 24px;
    }}
    .card {{
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 20px;
      padding: 32px 28px;
      width: 100%;
      max-width: 360px;
      display: flex;
      flex-direction: column;
      gap: 20px;
    }}
    h1 {{ font-size: 1.3rem; font-weight: 700; letter-spacing: -0.4px; }}
    .error {{ color: var(--red); font-size: 0.9rem; }}
    label {{ font-size: 0.8rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; display: block; margin-bottom: 6px; }}
    input[type=password] {{
      width: 100%;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      color: var(--text);
      font-size: 1rem;
      padding: 12px 14px;
      outline: none;
    }}
    input[type=password]:focus {{ border-color: var(--blue); }}
    button[type=submit] {{
      width: 100%;
      background: var(--blue);
      color: #fff;
      border: none;
      border-radius: 12px;
      padding: 14px;
      font-size: 1rem;
      font-weight: 600;
      cursor: pointer;
      -webkit-tap-highlight-color: transparent;
    }}
    button[type=submit]:active {{ opacity: 0.8; }}
  </style>
</head>
<body>
  <div class="card">
    <h1>&#127918; Gaming PC</h1>
    {error_html}
    <form method="POST" action="/?login=1">
      <label for="tok">Passwort</label>
      <input type="password" id="tok" name="token" autocomplete="current-password" autofocus>
      <br><br>
      <button type="submit">Anmelden</button>
    </form>
  </div>
</body>
</html>"""


def _login_page(error: str = "") -> str:
    error_html = f'<div class="error">{error}</div>' if error else ""
    return LOGIN_HTML.format(error_html=error_html)


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


# --- Mobile Web UI ---

MOBILE_HTML = """<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="Gaming PC">
  <title>Gaming PC</title>
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    :root {{
      --bg: #0f0f13;
      --surface: #1c1c24;
      --border: #2e2e3e;
      --text: #e8e8f0;
      --muted: #888899;
      --green: #22c55e;
      --red: #ef4444;
      --yellow: #f59e0b;
      --blue: #3b82f6;
      --purple: #8b5cf6;
    }}
    body {{
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      min-height: 100dvh;
      padding: env(safe-area-inset-top, 16px) 16px env(safe-area-inset-bottom, 16px);
      display: flex;
      flex-direction: column;
      gap: 16px;
      max-width: 480px;
      margin: 0 auto;
    }}
    header {{
      padding-top: 8px;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }}
    h1 {{ font-size: 1.4rem; font-weight: 700; letter-spacing: -0.5px; }}
    .status-card {{
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 20px;
      display: flex;
      align-items: center;
      gap: 14px;
    }}
    .status-dot {{
      width: 14px; height: 14px;
      border-radius: 50%;
      flex-shrink: 0;
      transition: background 0.4s;
    }}
    .status-dot.online  {{ background: var(--green); box-shadow: 0 0 8px var(--green); }}
    .status-dot.offline {{ background: var(--red);   box-shadow: 0 0 8px var(--red); }}
    .status-dot.unknown {{ background: var(--yellow); }}
    .status-text {{ flex: 1; }}
    .status-label {{ font-size: 0.8rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }}
    .status-value {{ font-size: 1.1rem; font-weight: 600; margin-top: 2px; }}
    .refresh-btn {{
      background: none; border: 1px solid var(--border);
      color: var(--muted); border-radius: 8px;
      padding: 6px 10px; font-size: 0.85rem; cursor: pointer;
      flex-shrink: 0;
    }}
    .refresh-btn:active {{ opacity: 0.6; }}
    .section-title {{
      font-size: 0.75rem; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.08em;
      padding: 0 4px;
    }}
    .btn-grid {{
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
    }}
    .btn-grid .btn-wide {{ grid-column: 1 / -1; }}
    button.action {{
      min-height: 64px;
      border: none; border-radius: 14px;
      font-size: 1rem; font-weight: 600;
      cursor: pointer;
      display: flex; flex-direction: column;
      align-items: center; justify-content: center;
      gap: 4px;
      transition: opacity 0.15s, transform 0.1s;
      -webkit-tap-highlight-color: transparent;
    }}
    button.action:active {{ opacity: 0.75; transform: scale(0.97); }}
    button.action .icon {{ font-size: 1.4rem; }}
    button.action .label {{ font-size: 0.85rem; font-weight: 600; }}
    .btn-wake     {{ background: linear-gradient(135deg, #166534, #15803d); color: #bbf7d0; }}
    .btn-shutdown {{ background: linear-gradient(135deg, #7f1d1d, #991b1b); color: #fecaca; }}
    .btn-sleep    {{ background: linear-gradient(135deg, #1e3a5f, #1d4ed8); color: #bfdbfe; }}
    .btn-hibernate{{ background: linear-gradient(135deg, #312e81, #4338ca); color: #e0e7ff; }}
    .btn-lock     {{ background: linear-gradient(135deg, #292524, #44403c); color: #d6d3d1; }}
    .toast {{
      position: fixed; bottom: calc(env(safe-area-inset-bottom, 16px) + 16px);
      left: 50%; transform: translateX(-50%);
      background: #1c1c24; border: 1px solid var(--border);
      color: var(--text); border-radius: 12px;
      padding: 12px 20px; font-size: 0.95rem;
      white-space: nowrap;
      opacity: 0; pointer-events: none;
      transition: opacity 0.25s;
      z-index: 100;
    }}
    .toast.show {{ opacity: 1; }}
    .timer {{ font-size: 0.75rem; color: var(--muted); text-align: right; padding: 0 4px; }}
  </style>
</head>
<body>
  <header>
    <h1>&#127918; Gaming PC</h1>
  </header>

  <div class="status-card">
    <div class="status-dot unknown" id="dot"></div>
    <div class="status-text">
      <div class="status-label">Status</div>
      <div class="status-value" id="status-value">Lade…</div>
    </div>
    <button class="refresh-btn" onclick="refreshStatus()">&#8635; Neu</button>
  </div>

  <div class="section-title">Steuerung</div>

  <div class="btn-grid">
    <button class="action btn-wake btn-wide" onclick="doAction('/wake','Einschalten…')">
      <span class="icon">&#9889;</span>
      <span class="label">Einschalten</span>
    </button>
    <button class="action btn-sleep" onclick="doAction('/sleep','Schlafen…')">
      <span class="icon">&#128164;</span>
      <span class="label">Schlafen</span>
    </button>
    <button class="action btn-hibernate" onclick="doAction('/hibernate','Ruhezustand…')">
      <span class="icon">&#10052;</span>
      <span class="label">Ruhezustand</span>
    </button>
    <button class="action btn-lock" onclick="doAction('/lock','Sperren…')">
      <span class="icon">&#128274;</span>
      <span class="label">Sperren</span>
    </button>
    <button class="action btn-shutdown btn-wide" onclick="doAction('/shutdown','Herunterfahren…')">
      <span class="icon">&#128308;</span>
      <span class="label">Herunterfahren</span>
    </button>
  </div>

  <div class="timer" id="timer">Aktualisierung in 10s</div>

  <div class="toast" id="toast"></div>

  <script>
    const BASE = window.location.origin;

    function showToast(msg, duration = 3000) {{
      const t = document.getElementById("toast");
      t.textContent = msg;
      t.classList.add("show");
      clearTimeout(t._tid);
      t._tid = setTimeout(() => t.classList.remove("show"), duration);
    }}

    async function refreshStatus() {{
      try {{
        const r = await fetch(BASE + "/status", {{
          credentials: "include"
        }});
        const d = await r.json();
        const dot = document.getElementById("dot");
        const val = document.getElementById("status-value");
        dot.className = "status-dot";
        if (d.pc_online === true) {{
          dot.classList.add("online");
          val.textContent = "Online";
        }} else if (d.pc_online === false) {{
          dot.classList.add("offline");
          val.textContent = "Offline";
        }} else {{
          dot.classList.add("unknown");
          val.textContent = "Unbekannt";
        }}
      }} catch(e) {{
        showToast("Fehler: " + e.message);
      }}
    }}

    async function doAction(path, label) {{
      showToast(label, 5000);
      try {{
        const r = await fetch(BASE + path, {{
          method: "POST",
          credentials: "include"
        }});
        const d = await r.json();
        if (d.ok) {{
          showToast("&#10003; Befehl gesendet");
          setTimeout(refreshStatus, 3000);
        }} else {{
          showToast("Fehler: " + (d.error || "unbekannt"));
        }}
      }} catch(e) {{
        showToast("Netzwerkfehler: " + e.message);
      }}
    }}

    // Auto-refresh every 10 seconds with countdown
    let countdown = 10;
    function tick() {{
      const el = document.getElementById("timer");
      if (countdown <= 0) {{
        countdown = 10;
        refreshStatus();
      }}
      el.textContent = "Aktualisierung in " + countdown + "s";
      countdown--;
    }}
    refreshStatus();
    setInterval(tick, 1000);
  </script>
</body>
</html>"""


@app.route("/", methods=["GET", "POST"])
@require_session_or_token
def mobile_ui():
    return MOBILE_HTML, 200, {"Content-Type": "text/html; charset=utf-8"}


# --- Routes ---

@app.route("/status", methods=["GET"])
@require_token
def status():
    online = pc_is_online(PC_IP)
    sunshine_ready = False
    if PC_IP and online:
        try:
            result = forward_to_agent("sunshine_status")
            sunshine_ready = result.get("response", "").strip() == "ready"
        except Exception:
            sunshine_ready = False
    return jsonify({
        "pc_online": online,
        "pc_ip": PC_IP or "not configured",
        "relay": "ok",
        "sunshine_ready": sunshine_ready,
    })


@app.route("/wake", methods=["POST"])
@require_token
def wake():
    try:
        # If PC is already online (Modern Standby), wake the display via agent
        if PC_IP and pc_is_online(PC_IP):
            try:
                forward_to_agent("wake_display")
            except Exception:
                pass
            return jsonify({"ok": True, "message": "Display woken (PC was already online)", "macs": PC_MACS})
        # PC is off -> send WoL magic packet
        for mac in PC_MACS:
            send_wol(mac)
        return jsonify({"ok": True, "message": "Magic packet sent", "macs": PC_MACS})
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


@app.route("/sunshine_ready", methods=["GET"])
@require_token
def sunshine_ready():
    result = forward_to_agent("sunshine_status")
    ready = result.get("response", "").strip() == "ready"
    return jsonify({"ready": ready})


if __name__ == "__main__":
    port = int(os.environ.get("WMC_RELAY_PORT", "8765"))
    # In production use a proper WSGI server (gunicorn) + TLS termination
    app.run(host="0.0.0.0", port=port, debug=False)
