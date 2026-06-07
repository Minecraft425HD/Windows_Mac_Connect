#!/usr/bin/env python3
"""
wmc — Windows-Mac Connect CLI
Usage:
    wmc status
    wmc wake
    wmc shutdown
    wmc sleep
    wmc hibernate
    wmc lock
    wmc config

Config is read from ~/.wmc.env or environment variables.
"""

import os
import sys
import json
import urllib.request
import urllib.error
from pathlib import Path

CONFIG_FILE = Path.home() / ".wmc.env"


def load_config() -> dict:
    cfg = {}
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip()
    # Environment overrides file
    for key in ("WMC_RELAY_URL", "WMC_API_TOKEN"):
        if key in os.environ:
            cfg[key] = os.environ[key]
    return cfg


def require_config(cfg: dict):
    missing = [k for k in ("WMC_RELAY_URL", "WMC_API_TOKEN") if not cfg.get(k)]
    if missing:
        print(f"Missing config: {', '.join(missing)}")
        print(f"Run:  wmc config   or edit {CONFIG_FILE}")
        sys.exit(1)


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


def cmd_status(cfg):
    result = api(cfg, "GET", "/status")
    online = result.get("pc_online")
    if online is True:
        print("Gaming-PC: \033[32mONLINE\033[0m")
    elif online is False:
        print("Gaming-PC: \033[31mOFFLINE\033[0m")
    else:
        print("Gaming-PC: UNKNOWN (PC_IP not configured on relay)")
    relay = result.get("relay", "?")
    print(f"Relay:     {relay}")


def cmd_wake(cfg):
    print("Sending Wake-on-LAN magic packet…")
    result = api(cfg, "POST", "/wake")
    if result.get("ok"):
        print("Magic packet sent. PC should boot within ~30 seconds.")
    else:
        print(f"Error: {result.get('error', result)}")


def cmd_power(cfg, action: str):
    labels = {
        "shutdown":  "Shutting down",
        "sleep":     "Putting to sleep",
        "hibernate": "Hibernating",
        "lock":      "Locking screen",
    }
    print(f"{labels.get(action, action)}…")
    result = api(cfg, "POST", f"/{action}")
    if result.get("ok"):
        print("Command accepted by PC.")
    else:
        print(f"Error: {result.get('error', result)}")


def cmd_config():
    print(f"Config file: {CONFIG_FILE}")
    relay = input("Relay URL (e.g. https://relay.example.com or http://100.x.x.x:8765): ").strip()
    token = input("API token (shared secret): ").strip()
    if not relay or not token:
        print("Aborted.")
        sys.exit(1)
    CONFIG_FILE.write_text(f"WMC_RELAY_URL={relay}\nWMC_API_TOKEN={token}\n")
    CONFIG_FILE.chmod(0o600)
    print(f"Saved to {CONFIG_FILE}")


USAGE = """
wmc — Windows-Mac Connect

  wmc status      Check if gaming PC is online
  wmc wake        Send Wake-on-LAN (turn on from off/hibernate)
  wmc shutdown    Shut down the gaming PC
  wmc sleep       Put the gaming PC to sleep
  wmc hibernate   Hibernate the gaming PC
  wmc lock        Lock the Windows screen
  wmc config      Set relay URL and API token
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
    elif cmd in ("shutdown", "sleep", "hibernate", "lock"):
        cmd_power(cfg, cmd)
    else:
        print(f"Unknown command: {cmd}")
        print(USAGE)
        sys.exit(1)


if __name__ == "__main__":
    main()
