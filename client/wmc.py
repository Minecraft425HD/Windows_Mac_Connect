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
STATS_FILE = Path.home() / ".wmc_stats.json"

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
            return {"error": f"HTTP {e.code}: {body}", "http_code": e.code}
    except Exception as e:
        return {"error": str(e)}


# ── Notifications ─────────────────────────────────────────────────────────────

def notify(title: str, message: str):
    try:
        subprocess.run([
            "osascript", "-e",
            f'display notification "{message}" with title "{title}" sound name "Glass"'
        ], capture_output=True, timeout=3)
    except Exception:
        pass


# ── Boot time learning ────────────────────────────────────────────────────────

def load_stats() -> dict:
    if STATS_FILE.exists():
        try:
            return json.loads(STATS_FILE.read_text())
        except Exception:
            pass
    return {"boot_times": []}


def save_boot_time(seconds: int):
    stats = load_stats()
    times = stats.get("boot_times", [])
    times.append(seconds)
    times = times[-10:]  # keep last 10
    stats["boot_times"] = times
    STATS_FILE.write_text(json.dumps(stats))


def estimated_boot_time() -> str:
    stats = load_stats()
    times = stats.get("boot_times", [])
    if not times:
        return "~30–60s"
    avg = int(sum(times) / len(times))
    return f"~{avg}s (Ø letzte {len(times)} Starts)"


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
    spinners = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    start = time.monotonic()
    deadline = start + timeout
    i = 0
    while time.monotonic() < deadline:
        elapsed = int(time.monotonic() - start)
        spin = spinners[i % len(spinners)]
        print(f"\r{spin} Warte auf PC... {elapsed}s  ", end="", flush=True)
        result = api(cfg, "GET", "/status")
        if result.get("pc_online") is True:
            boot_time = int(time.monotonic() - start)
            print(f"\r\033[32m✓\033[0m PC bereit nach {boot_time}s          ")
            return True
        i += 1
        time.sleep(3)
    elapsed = int(time.monotonic() - start)
    print(f"\r\033[31m✗\033[0m Timeout nach {elapsed}s              ")
    return False


def wait_for_sunshine(cfg, timeout: int = 30) -> bool:
    """Wartet bis Sunshine bereit ist. Gibt True zurück wenn erfolgreich."""
    spinners = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    start = time.monotonic()
    deadline = start + timeout
    i = 0

    while time.monotonic() < deadline:
        elapsed = int(time.monotonic() - start)
        spin = spinners[i % len(spinners)]
        print(f"\r{spin} Warte auf Sunshine... {elapsed}s  ", end="", flush=True)

        result = api(cfg, "GET", "/sunshine_ready")

        # Old relay without this endpoint — fall back to a simple 10s wait
        if result.get("http_code") == 404 or (
            "error" in result and "HTTP 404" in result.get("error", "")
        ):
            print(f"\r⠋ Warte auf Sunshine... (fallback)  ", end="", flush=True)
            for j in range(10):
                elapsed2 = int(time.monotonic() - start)
                spin2 = spinners[j % len(spinners)]
                print(f"\r{spin2} Warte auf Sunshine... {elapsed2}s  ", end="", flush=True)
                time.sleep(1)
            total = int(time.monotonic() - start)
            print(f"\r\033[32m✓\033[0m Sunshine bereit nach {total}s          ")
            return True

        if result.get("ok") or result.get("ready") is True:
            total = int(time.monotonic() - start)
            print(f"\r\033[32m✓\033[0m Sunshine bereit nach {total}s          ")
            return True

        i += 1
        time.sleep(2)

    elapsed = int(time.monotonic() - start)
    print(f"\r\033[31m✗\033[0m Sunshine Timeout nach {elapsed}s              ")
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
        print(f"PC wird gestartet… (erwartet: {estimated_boot_time()})")
        boot_start = time.monotonic()
        time.sleep(5)  # kurz warten bevor der erste Ping
        if not wait_for_pc(cfg, timeout=120):
            print("PC antwortet nicht nach 2 Minuten. BIOS Wake-on-LAN aktiviert?")
            sys.exit(1)
        boot_time = int(time.monotonic() - boot_start)
        save_boot_time(boot_time)
        # Poll Sunshine readiness instead of blind sleep
        wait_for_sunshine(cfg, timeout=30)
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
    notify("WMC", "Gaming PC ist bereit — Moonlight startet")
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

    # Tailscale-Verbindungstyp prüfen
    print()
    print("Tailscale-Verbindungsstatus…")
    pc_ip = cfg.get("WMC_PC_TAILSCALE_IP", "")
    try:
        result = subprocess.run(
            ["tailscale", "status"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            print("  \033[33mtailscale status nicht verfügbar\033[0m")
        else:
            output = result.stdout
            # Suche die Zeile mit der PC-IP oder "relay"/"direct" Keywords
            connection_type = None
            relay_host = None
            for line in output.splitlines():
                if pc_ip and pc_ip in line:
                    if "relay" in line.lower():
                        connection_type = "relay"
                        # Extrahiere den Relay-Host wenn vorhanden
                        parts = line.split()
                        for j, p in enumerate(parts):
                            if p == "relay" and j + 1 < len(parts):
                                relay_host = parts[j + 1]
                    elif "direct" in line.lower():
                        connection_type = "direct"
                    break

            if connection_type == "direct":
                print("  \033[32m✓ Tailscale: Direktverbindung (direct)\033[0m — optimale Latenz für Streaming")
            elif connection_type == "relay":
                relay_info = f" via {relay_host}" if relay_host else ""
                print(f"  \033[31m⚠ Tailscale: Relay-Verbindung{relay_info}\033[0m")
                print()
                print("  \033[33mTipp: Relay erhöht die Latenz spürbar. So zur Direktverbindung wechseln:\033[0m")
                print("   1. Firewall-Ausnahme für UDP 41641 auf beiden Geräten prüfen")
                print("   2. Auf dem PC: tailscale up --accept-routes")
                print("   3. Im Tailscale-Admin-Panel: MagicDNS und Subnet Routes prüfen")
                print("   4. Router-UPnP aktivieren oder Port 41641 UDP weiterleiten")
            elif pc_ip:
                print(f"  \033[33m? PC ({pc_ip}) nicht in 'tailscale status' gefunden\033[0m")
                print("  Ist Tailscale auf dem PC aktiv?")
            else:
                # Keine PC-IP konfiguriert — zeige rohe Ausgabe kompakt
                print("  (WMC_PC_TAILSCALE_IP nicht gesetzt — zeige alle Peers)")
                for line in output.splitlines()[1:6]:  # max 5 Zeilen
                    if line.strip():
                        print(f"    {line}")
    except FileNotFoundError:
        print("  \033[33mtailscale nicht gefunden — ist es installiert?\033[0m")
        print("  https://tailscale.com/download")
    except subprocess.TimeoutExpired:
        print("  \033[33mtailscale status Timeout\033[0m")


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
