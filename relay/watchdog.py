"""
WMC Watchdog
Läuft auf dem Raspberry Pi neben dem Relay-Server.
Überwacht den Gaming-PC per Ping und den wmc-relay-Dienst per HTTP.
"""

import logging
import logging.handlers
import os
import subprocess
import time

import urllib.request
import urllib.error

# --- Konfiguration ---
INTERVAL    = int(os.environ.get("WMC_WATCHDOG_INTERVAL", "60"))
RELAY_URL   = os.environ.get("WMC_RELAY_URL", "http://127.0.0.1:8765")
API_TOKEN   = os.environ.get("WMC_API_TOKEN", "")
PC_IP       = os.environ.get("WMC_PC_IP", "")

LOG_PATH    = "/var/log/wmc/watchdog.log"
LOG_MAX     = 1 * 1024 * 1024   # 1 MB
LOG_BACKUPS = 3

# --- Logging ---
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)

handler = logging.handlers.RotatingFileHandler(
    LOG_PATH, maxBytes=LOG_MAX, backupCount=LOG_BACKUPS
)
handler.setFormatter(logging.Formatter("%(asctime)s  %(levelname)-8s  %(message)s"))

log = logging.getLogger("wmc.watchdog")
log.setLevel(logging.INFO)
log.addHandler(handler)
log.addHandler(logging.StreamHandler())


# --- Hilfsfunktionen ---

def ping(ip: str) -> bool:
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "2000", ip],
            capture_output=True,
            timeout=5,
        )
        return result.returncode == 0
    except Exception:
        return False


def relay_is_healthy() -> bool:
    req = urllib.request.Request(
        f"{RELAY_URL}/status",
        headers={"Authorization": f"Bearer {API_TOKEN}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False


def restart_relay():
    log.warning("Starte wmc-relay neu …")
    try:
        subprocess.run(["systemctl", "restart", "wmc-relay"], check=True, timeout=30)
        log.info("wmc-relay erfolgreich neu gestartet.")
    except subprocess.CalledProcessError as e:
        log.error("Neustart von wmc-relay fehlgeschlagen: %s", e)
    except Exception as e:
        log.error("Unerwarteter Fehler beim Neustart: %s", e)


# --- Hauptschleife ---

def main():
    log.info("WMC Watchdog gestartet (Intervall: %ds, PC: %s, Relay: %s)",
             INTERVAL, PC_IP or "nicht konfiguriert", RELAY_URL)

    pc_was_online: bool | None = None
    shutdown_expected = False

    while True:
        # --- PC-Ping ---
        if PC_IP:
            pc_online = ping(PC_IP)
            if pc_online:
                log.info("PC erreichbar (%s).", PC_IP)
                shutdown_expected = False
            else:
                if pc_was_online and not shutdown_expected:
                    log.warning("PC (%s) ist unerwartet offline gegangen!", PC_IP)
                else:
                    log.info("PC nicht erreichbar (%s).", PC_IP)
            pc_was_online = pc_online
        else:
            log.debug("WMC_PC_IP nicht gesetzt – PC-Ping übersprungen.")

        # --- Relay-Health-Check ---
        if relay_is_healthy():
            log.info("wmc-relay antwortet normal.")
        else:
            log.warning("wmc-relay antwortet nicht auf GET /status.")
            restart_relay()

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
