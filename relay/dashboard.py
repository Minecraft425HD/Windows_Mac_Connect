#!/usr/bin/env python3
"""
WMC Dashboard — Terminal-UI für den Raspberry Pi
Startet automatisch beim SSH-Login und zeigt Live-Status.

Steuerung:
  w  Wake-on-LAN (PC einschalten)
  s  Shutdown
  z  Sleep
  h  Hibernate
  l  Lock
  r  Relay neu starten
  q  Beenden (zurück zur Shell)
"""

import curses
import json
import os
import socket
import subprocess
import time
import urllib.request
import urllib.error
from datetime import datetime

# Konfig aus /etc/wmc/relay.env laden
def load_env(path="/etc/wmc/relay.env"):
    env = {}
    try:
        for line in open(path).read().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip()
    except Exception:
        pass
    return env

ENV = load_env()
API_TOKEN    = ENV.get("WMC_API_TOKEN", "")
PC_MAC       = ENV.get("WMC_PC_MAC", "?")
PC_MACS      = [m.strip() for m in PC_MAC.split(",") if m.strip()]
PC_IP        = ENV.get("WMC_PC_IP", "")
RELAY_PORT   = int(ENV.get("WMC_RELAY_PORT", "8765"))
AGENT_PORT   = int(ENV.get("WMC_AGENT_PORT", "9876"))
WOL_BROADCAST = ENV.get("WMC_WOL_BROADCAST", "255.255.255.255")
RELAY_URL    = f"http://127.0.0.1:{RELAY_PORT}"

LOG: list[tuple[str, str]] = []   # (zeit, nachricht)
REFRESH_INTERVAL = 5              # Sekunden zwischen Auto-Refresh


def log(msg: str, level: str = "info"):
    ts = datetime.now().strftime("%H:%M:%S")
    LOG.append((ts, msg))
    if len(LOG) > 50:
        LOG.pop(0)


def relay_api(method: str, path: str) -> dict:
    url = RELAY_URL + path
    req = urllib.request.Request(
        url, method=method,
        headers={"Authorization": f"Bearer {API_TOKEN}",
                 "Content-Type": "application/json"},
        data=b"" if method == "POST" else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=4) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}


def agent_cmd(cmd: str) -> str:
    if not PC_IP:
        return "PC_IP nicht konfiguriert"
    try:
        with socket.create_connection((PC_IP, AGENT_PORT), timeout=4) as s:
            s.sendall((cmd + "\n").encode())
            return s.recv(256).decode().strip()
    except Exception as e:
        return f"Fehler: {e}"


def send_wol():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for mac in PC_MACS:
            mac_bytes = bytes.fromhex(mac.replace(":", "").replace("-", ""))
            packet = b"\xff" * 6 + mac_bytes * 16
            s.sendto(packet, (WOL_BROADCAST, 9))


def pc_ping() -> bool:
    if not PC_IP:
        return None
    try:
        r = subprocess.run(
            ["ping", "-c", "1", "-W", "1500", PC_IP],
            capture_output=True, timeout=3
        )
        return r.returncode == 0
    except Exception:
        return False


def get_status() -> dict:
    result = relay_api("GET", "/status")
    result["sunshine"] = agent_cmd("sunshine_status") if result.get("pc_online") else "—"
    result["tailscale_ip"] = subprocess.run(
        ["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=3
    ).stdout.strip() if os.path.exists("/usr/bin/tailscale") else "—"
    return result


def draw(stdscr, status: dict, last_refresh: float, action_msg: str):
    stdscr.erase()
    h, w = stdscr.getmaxyx()

    # ── Farben ───────────────────────────────────────────────────────────────
    curses.init_pair(1, curses.COLOR_GREEN,   curses.COLOR_BLACK)  # online
    curses.init_pair(2, curses.COLOR_RED,     curses.COLOR_BLACK)  # offline / fehler
    curses.init_pair(3, curses.COLOR_CYAN,    curses.COLOR_BLACK)  # titel / info
    curses.init_pair(4, curses.COLOR_YELLOW,  curses.COLOR_BLACK)  # warnung
    curses.init_pair(5, curses.COLOR_BLACK,   curses.COLOR_WHITE)  # header-bg
    curses.init_pair(6, curses.COLOR_WHITE,   curses.COLOR_BLACK)  # normal
    curses.init_pair(7, curses.COLOR_MAGENTA, curses.COLOR_BLACK)  # key-hints

    GREEN  = curses.color_pair(1) | curses.A_BOLD
    RED    = curses.color_pair(2) | curses.A_BOLD
    CYAN   = curses.color_pair(3) | curses.A_BOLD
    YELLOW = curses.color_pair(4)
    HEADER = curses.color_pair(5) | curses.A_BOLD
    NORMAL = curses.color_pair(6)
    KEY    = curses.color_pair(7)

    def safe_addstr(y, x, text, attr=NORMAL):
        if 0 <= y < h and 0 <= x < w:
            try:
                stdscr.addstr(y, x, text[:w - x], attr)
            except curses.error:
                pass

    # ── Header ───────────────────────────────────────────────────────────────
    title = " WMC Dashboard — Raspberry Pi "
    stdscr.attron(HEADER)
    stdscr.addstr(0, 0, " " * w)
    safe_addstr(0, (w - len(title)) // 2, title, HEADER)
    stdscr.attroff(HEADER)

    ts = datetime.now().strftime("%H:%M:%S")
    safe_addstr(0, w - len(ts) - 2, ts, HEADER)

    # ── Status-Block ──────────────────────────────────────────────────────────
    row = 2
    safe_addstr(row, 2, "STATUS", CYAN)
    row += 1
    safe_addstr(row, 2, "─" * (w - 4), NORMAL)
    row += 1

    pc_online = status.get("pc_online")
    if pc_online is True:
        safe_addstr(row, 4, "Gaming-PC   ", NORMAL)
        safe_addstr(row, 16, "● ONLINE", GREEN)
        safe_addstr(row, 25, f"  {PC_IP}", NORMAL)
    elif pc_online is False:
        safe_addstr(row, 4, "Gaming-PC   ", NORMAL)
        safe_addstr(row, 16, "○ OFFLINE", RED)
    else:
        safe_addstr(row, 4, "Gaming-PC   ", NORMAL)
        safe_addstr(row, 16, "? UNBEKANNT", YELLOW)
    row += 1

    sunshine = status.get("sunshine", "—")
    sunshine_color = GREEN if sunshine == "ready" else (YELLOW if sunshine == "starting" else RED)
    safe_addstr(row, 4, "Sunshine    ", NORMAL)
    safe_addstr(row, 16, f"{'● ' if sunshine == 'ready' else '○ '}{sunshine}", sunshine_color)
    row += 1

    relay_ok = "error" not in status
    safe_addstr(row, 4, "Relay       ", NORMAL)
    safe_addstr(row, 16, "● läuft" if relay_ok else "○ Fehler", GREEN if relay_ok else RED)
    row += 1

    ts_ip = status.get("tailscale_ip", "—")
    safe_addstr(row, 4, "Tailscale   ", NORMAL)
    safe_addstr(row, 16, ts_ip if ts_ip else "nicht verbunden",
                GREEN if ts_ip and ts_ip != "—" else RED)
    row += 1

    safe_addstr(row, 4, "PC MAC      ", NORMAL)
    safe_addstr(row, 16, " | ".join(PC_MACS) if PC_MACS else "?", NORMAL)
    row += 2

    # ── Steuerung ─────────────────────────────────────────────────────────────
    safe_addstr(row, 2, "STEUERUNG", CYAN)
    row += 1
    safe_addstr(row, 2, "─" * (w - 4), NORMAL)
    row += 1

    keys = [
        ("[W]", "Wake-on-LAN",  "PC einschalten"),
        ("[S]", "Shutdown",     "PC herunterfahren"),
        ("[Z]", "Sleep",        "PC schlafen legen"),
        ("[H]", "Hibernate",    "PC Ruhezustand"),
        ("[L]", "Lock",         "Bildschirm sperren"),
        ("[R]", "Relay",        "Relay-Service neu starten"),
        ("[Q]", "Beenden",      "Zurück zur Shell"),
    ]
    col2 = 22
    for key, name, desc in keys:
        if row >= h - 5:
            break
        safe_addstr(row, 4, key, KEY)
        safe_addstr(row, 8, f"{name:<12}", NORMAL | curses.A_BOLD)
        safe_addstr(row, col2, desc, NORMAL)
        row += 1
    row += 1

    # ── Aktions-Meldung ───────────────────────────────────────────────────────
    if action_msg:
        safe_addstr(row, 2, f"→ {action_msg}", YELLOW)
        row += 1
    row += 1

    # ── Log ───────────────────────────────────────────────────────────────────
    log_lines = max(0, h - row - 2)
    if log_lines > 0 and LOG:
        safe_addstr(row, 2, "LOG", CYAN)
        row += 1
        safe_addstr(row, 2, "─" * (w - 4), NORMAL)
        row += 1
        for ts_l, msg in LOG[-(log_lines):]:
            if row >= h - 1:
                break
            safe_addstr(row, 4, f"{ts_l}  {msg}", NORMAL)
            row += 1

    # ── Footer ────────────────────────────────────────────────────────────────
    next_refresh = int(REFRESH_INTERVAL - (time.monotonic() - last_refresh))
    footer = f" Refresh in {max(0, next_refresh)}s | [F5] Jetzt | [Q] Beenden "
    stdscr.attron(HEADER)
    try:
        stdscr.addstr(h - 1, 0, " " * w)
        stdscr.addstr(h - 1, 0, footer[:w])
    except curses.error:
        pass
    stdscr.attroff(HEADER)

    stdscr.refresh()


def main(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.noecho()
    curses.cbreak()
    stdscr.keypad(True)
    stdscr.nodelay(True)
    stdscr.timeout(250)

    status       = {}
    action_msg   = ""
    action_clear = 0.0
    last_refresh = 0.0   # sofort beim Start laden

    log("Dashboard gestartet")

    while True:
        now = time.monotonic()

        # Auto-Refresh
        if now - last_refresh >= REFRESH_INTERVAL:
            try:
                status = get_status()
                last_refresh = now
                log("Status aktualisiert")
            except Exception as e:
                log(f"Refresh-Fehler: {e}", "error")
                last_refresh = now

        # Aktionsmeldung nach 4s löschen
        if action_msg and now > action_clear:
            action_msg = ""

        draw(stdscr, status, last_refresh, action_msg)

        # Tastatureingabe
        try:
            key = stdscr.getch()
        except Exception:
            key = -1

        if key == -1:
            continue

        ch = chr(key).lower() if 32 <= key <= 126 else ""

        if ch == "q":
            break

        elif key == curses.KEY_F5 or ch == "f":
            log("Manueller Refresh...")
            status = get_status()
            last_refresh = time.monotonic()
            action_msg   = "Status aktualisiert"
            action_clear = time.monotonic() + 3

        elif ch == "w":
            try:
                send_wol()
                action_msg = f"Wake-on-LAN gesendet → {', '.join(PC_MACS)}"
                log(action_msg)
            except Exception as e:
                action_msg = f"WoL Fehler: {e}"
                log(action_msg, "error")
            action_clear = time.monotonic() + 5

        elif ch == "s":
            resp = agent_cmd("shutdown")
            action_msg = f"Shutdown: {resp}"
            log(action_msg)
            action_clear = time.monotonic() + 5

        elif ch == "z":
            resp = agent_cmd("sleep")
            action_msg = f"Sleep: {resp}"
            log(action_msg)
            action_clear = time.monotonic() + 5

        elif ch == "h":
            resp = agent_cmd("hibernate")
            action_msg = f"Hibernate: {resp}"
            log(action_msg)
            action_clear = time.monotonic() + 5

        elif ch == "l":
            resp = agent_cmd("lock")
            action_msg = f"Lock: {resp}"
            log(action_msg)
            action_clear = time.monotonic() + 5

        elif ch == "r":
            try:
                subprocess.run(["systemctl", "restart", "wmc-relay"], timeout=5)
                action_msg = "Relay neu gestartet"
                log(action_msg)
                time.sleep(1)
                status = get_status()
                last_refresh = time.monotonic()
            except Exception as e:
                action_msg = f"Fehler: {e}"
            action_clear = time.monotonic() + 4


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
    print("\nWMC Dashboard beendet. Tippe 'wmc-dash' zum Neustart.")
