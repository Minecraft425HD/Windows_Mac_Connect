"""
WMC Windows Agent
Runs as a Windows service on the gaming notebook.
Listens for commands from the relay server (over Tailscale / local network).
Install with: python agent.py install  (requires pywin32)
"""

import os
import socket
import subprocess
import sys
import threading
import time

AGENT_PORT = int(os.environ.get("WMC_AGENT_PORT", "9876"))
BIND_HOST  = os.environ.get("WMC_AGENT_BIND", "0.0.0.0")

# Commands mapped to Windows shell actions
COMMANDS = {
    "shutdown":  ["shutdown", "/s", "/t", "10", "/c", "WMC remote shutdown"],
    "reboot":    ["shutdown", "/r", "/t", "10", "/c", "WMC remote reboot"],
    "sleep":     ["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"],
    "hibernate": ["shutdown", "/h"],
    "lock":      ["rundll32.exe", "user32.dll,LockWorkStation"],
    "cancel":    ["shutdown", "/a"],
}


def handle_client(conn: socket.socket, addr):
    try:
        data = conn.recv(64).decode().strip().lower()
        if data == "ping":
            conn.sendall(b"pong\n")
            return
        if data in COMMANDS:
            subprocess.Popen(COMMANDS[data], shell=False)
            conn.sendall(f"ok: executing {data}\n".encode())
        else:
            conn.sendall(b"error: unknown command\n")
    except Exception as e:
        try:
            conn.sendall(f"error: {e}\n".encode())
        except Exception:
            pass
    finally:
        conn.close()


def run_server():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((BIND_HOST, AGENT_PORT))
        srv.listen(4)
        print(f"WMC Agent listening on {BIND_HOST}:{AGENT_PORT}", flush=True)
        while True:
            try:
                conn, addr = srv.accept()
                t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
                t.start()
            except Exception as e:
                print(f"Accept error: {e}", flush=True)
                time.sleep(1)


# --- Windows Service wrapper (optional, requires pywin32) ---

def _install_as_service():
    try:
        import win32serviceutil
        print("Use the PowerShell installer script (scripts/setup_windows.ps1) for service installation.")
    except ImportError:
        print("pywin32 not installed — run as a plain process or use NSSM.")
    sys.exit(0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "install":
        _install_as_service()
    run_server()
