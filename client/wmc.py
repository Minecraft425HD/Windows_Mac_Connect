#!/usr/bin/env python3
"""
wmc — Windows-Mac Connect CLI
Usage:
    wmc status
    wmc wake
    wmc stream      Wake PC + Moonlight starten (niedrigste Latenz)
    wmc shutdown
    wmc sleep
    wmc hibernate
    wmc lock
    wmc ping        Netzwerk-Latenz zum PC messen
    wmc config

Config: ~/.wmc.env  oder Umgebungsvariablen WMC_RELAY_URL, WMC_API_TOKEN
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CONFIG_FILE = Path.home() / ".wmc.env"

# Pfade zu Moonlight auf macOS
MOONLIGHT_PATHS = [
    "/Applications/Moonlight.app",
    str(Path.home() / "Applications/Moonlight.app"),
]


# ── Config ────────────────────────────────────────────────────────────────────

def load_config() -> dict:
    cfg = {}
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip()
    for key in ("WMC_RELAY_URL", "WMC_API_TOKEN", "WMC_PC_TAILSCALE_IP"):
        if key in os.environ:
            cfg[key] = os.environ[key]
    return cfg


def require_config(cfg: dict):
    missing = [k for k in ("WMC_RELAY_URL", "WMC_API_TOKEN") if not cfg.get(k)]
    if missing:
        print(f"Fehlende Konfiguration: {', '.join(missing)}")
        print(f"Ausführen:  wmc config   oder {CONFIG_FILE} bearbeiten")
        sys.exit(1)


# ── API ───────────────────────────────────────────────────────────────────────

def api(cfg: dict, method: str, path: str) -> dict:
    url = cfg["WMC_RELAY_URL"].rstrip("/") + path
    req = urllib.request.Request(
        url,
        method=method,
        headers={
            "Authorization": f"Bearer {cfg['WMC_API_TOKEN']}",
            "Content-Type": "application/json",
        },
        data=b"" if method == "POST" else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            return json.loads(body)
        except Exception:
            return {"error": f"HTTP {e.code}: {body}"}
    except Exception as e:
        return {"error": str(e)}


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_status(cfg):
    result = api(cfg, "GET", "/status")
    if "error" in result:
        print(f"Relay-Fehler: {result['error']}")
        return
    online = result.get("pc_online")
    if online is True:
        print("Gaming-PC:  \033[32mONLINE\033[0m")
    elif online is False:
        print("Gaming-PC:  \033[31mOFFLINE\033[0m")
    else:
        print("Gaming-PC:  UNBEKANNT (PC_IP nicht konfiguriert)")
    print(f"Relay:      {result.get('relay', '?')}")


def cmd_wake(cfg, silent: bool = False) -> bool:
    if not silent:
        print("Wake-on-LAN Magic Packet wird gesendet…")
    result = api(cfg, "POST", "/wake")
    if result.get("ok"):
        if not silent:
            print("Paket gesendet. PC startet in ~30 Sekunden.")
        return True
    else:
        print(f"Fehler: {result.get('error', result)}")
        return False


def wait_for_pc(cfg, timeout: int = 120) -> bool:
    """Wartet bis der PC online ist. Gibt True zurück wenn erfolgreich."""
    print("Warte auf PC", end="", flush=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = api(cfg, "GET", "/status")
        if result.get("pc_online") is True:
            print(" \033[32mONLINE\033[0m")
            return True
        print(".", end="", flush=True)
        time.sleep(3)
    print(" \033[31mTimeout\033[0m")
    return False


def find_moonlight() -> str | None:
    for path in MOONLIGHT_PATHS:
        if os.path.isdir(path):
            return path
    return None


def cmd_stream(cfg):
    """PC einschalten und Moonlight starten — ein Befehl, sofort spielen."""
    print("\033[1mWMC Stream\033[0m — PC einschalten und Moonlight starten")
    print()

    # Status prüfen
    result = api(cfg, "GET", "/status")
    if "error" in result:
        print(f"Relay nicht erreichbar: {result['error']}")
        print("Ist Tailscale aktiv? Läuft der Pi?")
        sys.exit(1)

    pc_online = result.get("pc_online")

    if pc_online is False:
        # PC ist aus — Wake-on-LAN senden
        ok = cmd_wake(cfg, silent=True)
        if not ok:
            sys.exit(1)
        print("PC wird gestartet…")
        time.sleep(5)  # kurz warten bevor der erste Ping
        if not wait_for_pc(cfg, timeout=120):
            print("PC antwortet nicht nach 2 Minuten. BIOS Wake-on-LAN aktiviert?")
            sys.exit(1)
        # Windows braucht nach dem Ping noch ~10s bis Sunshine bereit ist
        print("Warte kurz bis Sunshine bereit ist…")
        time.sleep(10)
    elif pc_online is True:
        print("Gaming-PC ist bereits online.")
    else:
        print("PC-Status unbekannt — starte Moonlight trotzdem…")

    # Moonlight öffnen
    moonlight = find_moonlight()
    if not moonlight:
        print("\033[31mMoonlight nicht gefunden.\033[0m")
        print("Installieren mit:  brew install --cask moonlight")
        print("Oder: bash scripts/setup_mac.sh")
        sys.exit(1)

    # Tailscale-IP des PCs für direkten Moonlight-Start
    pc_ip = cfg.get("WMC_PC_TAILSCALE_IP", "")
    if pc_ip:
        print(f"Moonlight starten → {pc_ip}…")
        subprocess.Popen(["open", "-a", moonlight, "--args", pc_ip])
    else:
        print("Moonlight starten…")
        print("(Tipp: WMC_PC_TAILSCALE_IP in ~/.wmc.env setzen für direkten Start)")
        subprocess.Popen(["open", moonlight])

    print("\033[32mViel Spaß!\033[0m")


def cmd_ping(cfg):
    """Misst die Netzwerk-Latenz zum Relay und schätzt die Streaming-Latenz."""
    import statistics

    url = cfg["WMC_RELAY_URL"].rstrip("/") + "/status"
    samples = []
    print("Latenz-Messung (10 Messungen)…")
    for i in range(10):
        t0 = time.perf_counter()
        try:
            req = urllib.request.Request(
                url,
                headers={"Authorization": f"Bearer {cfg['WMC_API_TOKEN']}"},
            )
            with urllib.request.urlopen(req, timeout=5):
                pass
            rtt = (time.perf_counter() - t0) * 1000
            samples.append(rtt)
            print(f"  [{i+1:2d}] {rtt:6.1f} ms")
        except Exception as e:
            print(f"  [{i+1:2d}] Fehler: {e}")
        time.sleep(0.2)

    if samples:
        mn  = min(samples)
        avg = statistics.mean(samples)
        p95 = sorted(samples)[int(len(samples) * 0.95)]
        print()
        print(f"  Min:  {mn:.1f} ms   (beste Verbindung)")
        print(f"  Avg:  {avg:.1f} ms")
        print(f"  P95:  {p95:.1f} ms   (95% der Zeit darunter)")
        print()
        if mn < 5:
            print("\033[32m  Direktverbindung (Tailscale direct) — optimale Streaming-Latenz\033[0m")
        elif mn < 30:
            print("\033[33m  Gute Verbindung — Streaming problemlos möglich\033[0m")
        else:
            print("\033[31m  Hohe Latenz — prüfe ob Tailscale eine Direct Connection hat\033[0m")
            print("  tailscale status   (sollte 'direct' zeigen, nicht 'relay')")


def cmd_power(cfg, action: str):
    labels = {
        "shutdown":  "Herunterfahren…",
        "sleep":     "Schlafen legen…",
        "hibernate": "Ruhezustand…",
        "lock":      "Bildschirm sperren…",
    }
    print(labels.get(action, f"{action}…"))
    result = api(cfg, "POST", f"/{action}")
    if result.get("ok"):
        print("Befehl vom PC akzeptiert.")
    else:
        print(f"Fehler: {result.get('error', result)}")


def cmd_config():
    print(f"Konfigurationsdatei: {CONFIG_FILE}")
    print()
    relay = input("Relay URL (z.B. http://100.64.0.2:8765): ").strip()
    token = input("API Token: ").strip()
    pc_ip = input("Tailscale-IP des Gaming-PCs (optional, für 'wmc stream'): ").strip()
    if not relay or not token:
        print("Abgebrochen.")
        sys.exit(1)
    lines = [
        f"WMC_RELAY_URL={relay}",
        f"WMC_API_TOKEN={token}",
    ]
    if pc_ip:
        lines.append(f"WMC_PC_TAILSCALE_IP={pc_ip}")
    CONFIG_FILE.write_text("\n".join(lines) + "\n")
    CONFIG_FILE.chmod(0o600)
    print(f"Gespeichert: {CONFIG_FILE}")


USAGE = """
wmc — Windows-Mac Connect

  wmc stream      PC einschalten + Moonlight starten  ← Hauptbefehl
  wmc status      Ist der Gaming-PC online?
  wmc wake        Nur einschalten (Wake-on-LAN)
  wmc ping        Netzwerk-Latenz messen
  wmc shutdown    Herunterfahren
  wmc sleep       Schlafen legen
  wmc hibernate   Ruhezustand (Strom aus, WoL möglich)
  wmc lock        Windows-Bildschirm sperren
  wmc config      Relay-URL und API-Token konfigurieren
"""


def main():
    cfg = load_config()
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print(USAGE)
        return
    cmd = args[0]
    if cmd == "config":
        cmd_config()
        return
    require_config(cfg)
    if cmd == "status":
        cmd_status(cfg)
    elif cmd == "wake":
        cmd_wake(cfg)
    elif cmd == "stream":
        cmd_stream(cfg)
    elif cmd == "ping":
        cmd_ping(cfg)
    elif cmd in ("shutdown", "sleep", "hibernate", "lock"):
        cmd_power(cfg, cmd)
    else:
        print(f"Unbekannter Befehl: {cmd}")
        print(USAGE)
        sys.exit(1)


if __name__ == "__main__":
    main()
