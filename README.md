# Windows-Mac Connect (WMC)

Gaming-PC vom MacBook steuern und streamen — ein Befehl, sofort spielen.

```
wmc stream
```

Schaltet den PC ein (falls aus), wartet bis er hochgefahren ist, öffnet Moonlight.

---

## Latenz — was realistisch ist

| Wo du bist | Netzwerk-Zusatzlatenz | Spielbar für |
|---|---|---|
| Gleiches Haus (LAN/5GHz) | **2–8 ms** | Alles, auch kompetitiv |
| Gleiche Stadt | **5–20 ms** | Alles |
| Gleiches Land | **10–40 ms** | RPG, Singleplayer, Strategie |
| Europa (DE → UK/FR) | **30–60 ms** | Casual, Singleplayer |
| Interkontinental | **80–200 ms** | Nicht empfohlen |

**Das Limit ist Physik, nicht Software.** Licht in Glasfaser braucht ~5 ms pro 1.000 km — das ist die unveränderliche Untergrenze.

Die Software-Latenz (Encoding, Netzwerk-Stack, Decoding) mit diesem Stack: **< 5 ms** im Heimnetz.

---

## Architektur

```
MacBook
  │  Moonlight (H.265/AV1, Hardware-Decoding)
  │
  │  Tailscale VPN (direkte verschlüsselte Verbindung, kein Umweg)
  │
Raspberry Pi 3B (immer an, LAN)
  ├── WMC Relay → Wake-on-LAN → Gaming-PC (auch wenn aus)
  └── WMC Relay → Agent       → Gaming-PC (shutdown/sleep)
  
Gaming-PC (Windows)
  └── Sunshine (Hardware-Encoding: NVENC / AMF / QuickSync)
```

**Warum Tailscale?** Kein Port-Forwarding, kein DynDNS. Tailscale baut direkte Verbindungen (keine Cloud als Umweg) — das gibt die niedrigste mögliche Latenz über das Internet.

**Warum Sunshine + Moonlight?** Hardware-Encoding auf der GPU: NVIDIA NVENC, AMD AMF oder Intel QuickSync fügen < 1 ms Encoding-Latenz hinzu. Das ist das gleiche Protokoll wie NVIDIA GeForce Experience, nur open source und ohne Beschränkungen.

---

## Voraussetzungen

| Gerät | Details |
|---|---|
| Gaming-PC | Windows 10/11, GPU mit Hardware-Encoder (NVIDIA ab GTX 900, AMD ab RX 400, Intel ab 6. Gen) |
| Raspberry Pi 3B/3B+ | LAN-Kabel, Raspberry Pi OS Lite |
| MacBook | macOS 11+, Tailscale, Moonlight |

---

## Setup

### Schritt 0 — Raspberry Pi OS installieren (falls neu)

1. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) → **Raspberry Pi OS Lite (64-bit)**
2. Im Imager: SSH aktivieren, Benutzername + Passwort setzen
3. LAN-Kabel einstecken, starten
4. `ssh pi@<ip-im-router>`

---

### Schritt 1 — Tailscale überall installieren

Auf **Gaming-PC**, **Raspberry Pi** und **MacBook** — mit **demselben Account** einloggen.

**Download:** https://tailscale.com/download

```bash
# Pi:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4   # notieren, z.B. 100.64.0.2

# Gaming-PC: Installer ausführen, im Browser einloggen
# MacBook: Installer ausführen, im Browser einloggen
```

Jetzt haben alle Geräte eine feste `100.x.x.x`-IP, die sich nie ändert.

---

### Schritt 2 — Gaming-PC einrichten

PowerShell als **Administrator** öffnen:

```powershell
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect
Set-ExecutionPolicy Bypass -Scope Process
.\scripts\setup_windows.ps1
```

Das Skript macht automatisch:
- Wake-on-LAN im Netzwerktreiber aktivieren
- Fast Startup deaktivieren (nötig für WoL nach echtem Shutdown)
- OpenSSH Server aktivieren
- WMC Agent als Windows-Dienst installieren
- **Sunshine installieren und latenzoptimiert konfigurieren** (NVENC/AMF/QuickSync automatisch erkannt)
- Alle nötigen Firewall-Regeln setzen

Am Ende zeigt das Skript die **MAC-Adresse** — notieren.

**Sunshine Web-UI aufrufen** (einmalig, Benutzername + Passwort setzen):
```
https://localhost:47990
```

**BIOS/UEFI:** Wake-on-LAN aktivieren — suche nach:
- *Wake on LAN*
- *Power on by PCI-E/PCIe*
- *ErP Ready* → muss **AUS** sein

---

### Schritt 3 — Raspberry Pi einrichten

```bash
# Per SSH auf dem Pi:
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect
sudo bash scripts/setup_relay.sh
```

Danach Konfiguration bearbeiten:
```bash
sudo nano /etc/wmc/relay.env
```

```env
WMC_API_TOKEN=<automatisch generiert — so lassen>
WMC_PC_MAC=AA:BB:CC:DD:EE:FF     ← MAC des Gaming-PCs
WMC_PC_IP=192.168.1.100           ← lokale IP des Gaming-PCs (im Router nachschauen)
WMC_AGENT_PORT=9876
WMC_WOL_BROADCAST=255.255.255.255
WMC_RELAY_PORT=8765
```

MAC-Adresse des PCs herausfinden (in PowerShell auf dem PC):
```powershell
ipconfig /all | Select-String "Physical"
```

```bash
sudo systemctl restart wmc-relay
sudo systemctl status wmc-relay   # → active (running)
```

---

### Schritt 4 — MacBook einrichten

```bash
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect
bash scripts/setup_mac.sh
```

Installiert automatisch: `wmc` CLI, Moonlight, Tailscale (falls nicht vorhanden).

Konfigurieren:
```bash
wmc config
```
```
Relay URL:               http://100.64.0.2:8765        ← Tailscale-IP des Pi
API Token:               <aus /etc/wmc/relay.env>
Tailscale-IP des PCs:    100.64.0.5                    ← für direkten Moonlight-Start
```

**Moonlight mit Sunshine pairen** (einmalig):
1. Moonlight öffnen
2. PC in der Liste anklicken
3. PIN-Code eingeben → in Sunshine Web-UI (`https://localhost:47990`) bestätigen

---

## Verwendung

```bash
wmc stream      # PC einschalten + Moonlight starten  ← Hauptbefehl
wmc status      # Ist der PC online?
wmc ping        # Latenz messen + Tailscale Direct/Relay prüfen
wmc wake        # Nur einschalten
wmc shutdown    # Herunterfahren
wmc hibernate   # Ruhezustand (WoL möglich, kein Stromverbrauch)
wmc sleep       # Schlafen (schneller aufwachen als hibernate)
wmc lock        # Bildschirm sperren
```

### iPhone Web-UI

Der Relay-Server liefert eine mobile Web-App direkt mit. Im Safari öffnen:

```
http://<tailscale-ip-des-pi>:8765/?token=<API-TOKEN>
```

"Teilen → Zum Home-Bildschirm" — sieht aus und fühlt sich an wie eine native App.

---

## Latenz optimieren

### 0. Windows-Latenz-Optimierung (einmalig, nach setup_windows.ps1)

```powershell
# PowerShell als Administrator:
.\scripts\optimize_windows.ps1
# Danach: PC neu starten!
```

Macht automatisch: Ultimate Performance-Modus, Interrupt Moderation deaktivieren,
NVIDIA Ultra Low Latency, HAGS aktivieren, Nagle-Algorithmus deaktivieren,
NIC-Energiesparmodi ausschalten.

### 1. Tailscale Direct Connection sicherstellen
```bash
tailscale status
# Soll zeigen: direct, nicht relay
```
Falls `relay`: Firewall auf beiden Seiten prüfen. Tailscale funktioniert durch die meisten NATs automatisch.

### 2. Moonlight-Einstellungen
- **Codec:** AV1 (falls GPU es unterstützt) → sonst H.265 → H.264
- **FPS:** so hoch wie dein Monitor kann (120 / 144)
- **Auflösung:** 1080p für geringstes Encoding-Overhead, 1440p wenn Bandbreite reicht
- **Bitrate:** 20–50 Mbps für 1080p, 50–100 Mbps für 1440p

### 3. Windows-seitig
- Spiel im Vollbild (nicht Fenstermodus / Borderless)
- V-Sync im Spiel **aus** — Moonlight hat eigene Frame-Synchronisation
- NVIDIA: "Low Latency Mode" in den NVIDIA Control Panel-Einstellungen → **Ultra**

---

## Fehlerbehebung

**`wmc stream`: PC startet nicht (WoL schlägt fehl)**
1. BIOS Wake-on-LAN aktiviert?
2. PC am Strom? (Laptop: Netzteil angesteckt)
3. Fast Startup aus? → `setup_windows.ps1` nochmal laufen lassen
4. Richtiger `WMC_WOL_BROADCAST`? Bei manchen Routern: `192.168.1.255`

**Moonlight verbindet sich nicht**
1. Sunshine läuft? → `https://localhost:47990` auf dem PC aufrufen
2. Firewall-Ports offen? → `setup_windows.ps1` nochmal laufen lassen
3. Noch nicht gepairt? → Moonlight → PC anklicken → PIN eingeben

**Hohe Latenz / Ruckeln**
```bash
wmc ping   # Relay-Latenz messen
tailscale status   # Direct Connection prüfen
```

**Relay nicht erreichbar**
```bash
# Auf dem Pi:
sudo systemctl status wmc-relay
sudo journalctl -u wmc-relay -n 30
# Tailscale aktiv?
tailscale status
```

---

## Sicherheit

- API-Token sichert alle WMC-Befehle
- Relay-Port nur über Tailscale erreichbar (kein offener Internetport)
- Sunshine-Verbindungen durch Moonlight-Pairing gesichert (RSA-Key-Exchange)
- Tailscale verwendet WireGuard (state-of-the-art Verschlüsselung)
- Config-Dateien: `chmod 600`

---

## Projektstruktur

```
relay/          Relay-Server (Pi — Wake-on-LAN + Agent-Proxy)
agent/          Windows-Dienst (shutdown/sleep/hibernate/lock)
client/         wmc CLI für MacBook
scripts/        Setup-Skripte (Windows, Pi, Mac)
```
