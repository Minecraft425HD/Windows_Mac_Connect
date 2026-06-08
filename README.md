# Windows-Mac Connect (WMC)

Gaming-PC vom MacBook steuern und streamen — ein Befehl, sofort spielen.

```
wmc stream
```

Schaltet den PC ein (falls aus), wartet bis er hochgefahren ist, öffnet Moonlight automatisch.

---

## Latenz — was realistisch ist

| Wo du bist | Netzwerk-Zusatzlatenz | Spielbar für |
|---|---|---|
| Gleiches Haus (LAN/5GHz) | **2–8 ms** | Alles, auch kompetitiv |
| Gleiche Stadt | **5–20 ms** | Alles |
| Gleiches Land | **10–40 ms** | RPG, Singleplayer, Strategie |
| Europa (DE → UK/FR) | **30–60 ms** | Casual, Singleplayer |
| Interkontinental | **80–200 ms** | Nicht empfohlen |

**Das Limit ist Physik, nicht Software.** Licht in Glasfaser braucht ~5 ms pro 1.000 km.  
Die Software-Latenz (Encoding + Netzwerk-Stack + Decoding) mit diesem Stack: **< 5 ms** im Heimnetz.

---

## Wie es funktioniert

```
MacBook
  │  wmc stream → prüft Status → weckt PC falls aus → öffnet Moonlight
  │
  │  Tailscale VPN (verschlüsselt, direkte Verbindung, kein Cloud-Umweg)
  │
Raspberry Pi 3B  ← immer eingeschaltet, LAN-Kabel
  ├── Relay-Server  → sendet Wake-on-LAN lokal  → Gaming-PC startet
  ├── Relay-Server  → leitet Befehle weiter      → shutdown / sleep / lock
  └── Watchdog      → überwacht Relay, startet neu falls nötig

Gaming-PC (Windows)
  ├── Sunshine       → Hardware-Encoding (NVENC / AMF / QuickSync), < 1 ms
  └── WMC Agent      → empfängt Befehle (shutdown, sleep, hibernate, lock)
```

**Tailscale** baut direkte WireGuard-Tunnel zwischen allen Geräten — kein Port-Forwarding, kein DynDNS, funktioniert weltweit aus jedem Netz.

**Sunshine + Moonlight** nutzen Hardware-Encoding direkt auf der GPU. Das ist das gleiche Protokoll wie NVIDIAs GameStream, nur open source und ohne Einschränkungen.

---

## Voraussetzungen

| Gerät | Anforderungen |
|---|---|
| Gaming-PC | Windows 10/11, GPU mit Hardware-Encoder (NVIDIA ab GTX 900 / AMD ab RX 400 / Intel ab 6. Gen) |
| Raspberry Pi 3B/3B+ | LAN-Kabel, Raspberry Pi OS Lite (64-bit) |
| MacBook | macOS 11+ |

Alle Software wird von den Setup-Skripten automatisch installiert.

---

## Setup

### Schritt 0 — Raspberry Pi OS installieren (nur wenn Pi noch neu)

1. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) → **Raspberry Pi OS Lite (64-bit)**
2. Im Imager vor dem Flashen: SSH aktivieren, Benutzername + Passwort setzen
3. MicroSD in Pi, LAN-Kabel einstecken, starten
4. IP im Router nachschauen, dann: `ssh pi@<ip>`

---

### Schritt 1 — Gaming-PC einrichten

PowerShell als **Administrator** öffnen:

```powershell
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect
Set-ExecutionPolicy Bypass -Scope Process
.\scripts\setup_windows.ps1
```

**Was das Skript automatisch macht (8 Schritte):**
1. Wake-on-LAN im Netzwerktreiber + Fast Startup deaktivieren
2. OpenSSH Server installieren und starten
3. Python installieren (via `winget`, falls nicht vorhanden)
4. WMC Agent als Windows-Dienst installieren
5. Sunshine installieren, GPU erkennen (NVENC/AMF/QuickSync), latenzoptimiert konfigurieren
6. Latenz-Optimierungen: Ultimate Performance, Interrupt Moderation off, HAGS, Nagle off
7. Auto-Login einrichten (Sysinternals AutoLogon) — fragt nach Passwort
8. Tailscale installieren (via `winget`)

Am Ende zeigt das Skript **MAC-Adresse** und **lokale IP** — beides für den Pi notieren.

**Einmalig nach dem Setup:**
- **BIOS/UEFI:** Wake-on-LAN aktivieren → Neustart → Entf/F2 → suche: *Wake on LAN* oder *Power on by PCIe* (*ErP Ready* muss AUS sein)
- **Tailscale:** starten und mit Account einloggen
- **Sunshine Web-UI:** `https://localhost:47990` → Benutzername + Passwort setzen
- **PC neu starten** (damit Latenz-Optimierungen greifen)

---

### Schritt 2 — Raspberry Pi einrichten

```bash
# Per SSH auf dem Pi:
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect
sudo bash scripts/setup_relay.sh
```

**Was das Skript automatisch macht (7 Schritte):**
1. System-Pakete installieren (Python, pip, git, ping)
2. System-User `wmc` anlegen (läuft ohne Login-Rechte)
3. Relay-Server + Watchdog installieren (Python-Virtualenv)
4. Konfiguration erstellen — **fragt interaktiv nach MAC und IP des Gaming-PCs**
5. systemd-Services registrieren (Autostart beim Boot)
6. Services prüfen (gibt Fehler-Logs aus falls etwas nicht stimmt)
7. Tailscale installieren und verbinden

Am Ende zeigt das Skript **Relay-URL** und **API-Token** — beides für den Mac notieren.

---

### Schritt 3 — MacBook einrichten

```bash
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect
bash scripts/setup_mac.sh
```

**Was das Skript automatisch macht (4 Schritte):**
1. `wmc` CLI installieren (`/usr/local/bin/wmc`)
2. Moonlight installieren (via Homebrew)
3. Tailscale installieren und starten
4. `wmc config` direkt aufrufen (gibt Relay-URL und Token ein)

**Moonlight mit Sunshine pairen** (einmalig, danach nie wieder nötig):
1. Moonlight öffnen
2. Gaming-PC in der Liste anklicken
3. PIN eingeben
4. Auf dem Gaming-PC: `https://localhost:47990` → PIN bestätigen

---

## Verwendung

```bash
wmc stream      # PC einschalten + Moonlight starten  ← Hauptbefehl
wmc status      # Ist der Gaming-PC online?
wmc wake        # Nur einschalten (Wake-on-LAN)
wmc ping        # Latenz messen + Tailscale Direct/Relay prüfen
wmc shutdown    # Herunterfahren
wmc hibernate   # Ruhezustand (kein Strom, WoL weiterhin möglich)
wmc sleep       # Schlafen (schneller aufwachen als Ruhezustand)
wmc lock        # Windows-Bildschirm sperren
wmc profiles    # Alle konfigurierten Profile anzeigen
wmc config      # Standardprofil konfigurieren
```

### Mehrere PCs (Profile)

```bash
# Profil anlegen:
wmc -p büro config
wmc -p gaming config

# Verwenden:
wmc -p gaming stream
wmc -p büro shutdown

# Alle Profile anzeigen:
wmc profiles
```

Profile werden in `~/.wmc/profiles/<name>.env` gespeichert.

### iPhone Web-UI

Der Relay-Server liefert eine mobile Web-App direkt mit. Einmalig im Safari öffnen:

```
http://<tailscale-ip-des-pi>:8765/?token=<API-TOKEN>
```

Beim ersten Aufruf mit Token wird eine 30-Tage-Session-Cookie gesetzt — danach reicht die URL ohne Token. "Teilen → Zum Home-Bildschirm" speichert sie als App-Icon.

---

## `wmc stream` — was intern passiert

```
1. Relay-Status abfragen
2. Falls PC offline → Wake-on-LAN Magic Packet senden
3. Warten bis PC antwortet (Live-Spinner mit Sekunden-Zähler)
   → Zeigt geschätzte Boot-Zeit basierend auf den letzten Starts
4. Warten bis Sunshine bereit ist (Port 47990 offen)
5. macOS-Benachrichtigung "Gaming PC ist bereit"
6. Moonlight starten (direkt mit PC-Tailscale-IP)
```

---

## Fehlerbehebung

**PC startet nicht nach `wmc wake` / `wmc stream`**
1. BIOS Wake-on-LAN aktiviert? (Neustart → Entf/F2)
2. PC am Strom? (Gaming-Laptop: Netzteil einstecken)
3. Fast Startup aus? → `setup_windows.ps1` nochmal ausführen
4. Falscher Broadcast? → in `/etc/wmc/relay.env`: `WMC_WOL_BROADCAST=192.168.1.255`

**Moonlight verbindet sich nicht**
1. Sunshine läuft? → `https://localhost:47990` auf dem PC aufrufen
2. Noch nicht gepairt? → Moonlight → PC anklicken → PIN eingeben
3. Firewall-Ports fehlen? → `setup_windows.ps1` nochmal ausführen

**Relay nicht erreichbar (`wmc status` schlägt fehl)**
```bash
# Auf dem Pi:
sudo systemctl status wmc-relay wmc-watchdog
sudo journalctl -u wmc-relay -n 30
tailscale status   # Ist Tailscale verbunden?
```

**Tailscale zeigt "relay" statt "direct"**
```bash
wmc ping   # zeigt Direct/Relay und gibt Tipps
```
Meist reicht: Router-Firewall UDP-Port 41641 freigeben, oder einfach warten (Tailscale wechselt automatisch).

**Auto-Login funktioniert nicht / Moonlight zeigt Anmeldebildschirm**
→ `setup_windows.ps1` nochmal ausführen, Schritt 7 (Auto-Login) erneut durchführen.

---

## Sicherheit

| Komponente | Schutz |
|---|---|
| WMC API | Bearer-Token (32 Byte, zufällig generiert) |
| iPhone Web-UI | Session-Cookie (30 Tage), kein Token im Browser-Verlauf nach erstem Login |
| Relay-Port | Nur über Tailscale erreichbar — kein offener Internet-Port |
| Streaming | Moonlight-Pairing mit RSA-Key-Exchange |
| VPN | WireGuard (Tailscale) — modernste Verschlüsselung |
| Konfig-Dateien | `chmod 640` / `600` |

---

## Projektstruktur

```
relay/
  relay_server.py   Relay-Server: Wake-on-LAN, Befehle, iPhone Web-UI
  watchdog.py       Überwacht Relay, startet bei Fehler neu
  relay.service     systemd-Unit für den Relay-Server
  watchdog.service  systemd-Unit für den Watchdog
  requirements.txt  Python-Abhängigkeiten (Flask, gunicorn)

agent/
  agent.py          Windows-Dienst: shutdown / sleep / hibernate / lock / sunshine_status

client/
  wmc.py            MacBook CLI: stream / wake / status / ping / profiles / config

scripts/
  setup_windows.ps1   Vollautomatisches Setup für den Gaming-PC (8 Schritte)
  setup_relay.sh      Vollautomatisches Setup für den Raspberry Pi (7 Schritte)
  setup_mac.sh        Vollautomatisches Setup für das MacBook (4 Schritte)
  optimize_windows.ps1  Latenz-Optimierungen (wird von setup_windows.ps1 aufgerufen)
```
