# Windows-Mac Connect (WMC)

Steuere deinen Gaming-PC vom MacBook aus — auch über das Internet, ohne Heimnetzwerk. Einschalten, ausschalten, schlafen legen: stabil wie die PS5-Fernsteuerung.

---

## Wie es funktioniert

```
MacBook (wmc CLI)
    │
    │  HTTPS über Tailscale (verschlüsselt, kein offener Port nötig)
    ▼
Relay-Server (Raspberry Pi / NAS / alter PC — immer an)
    │
    ├── Wake-on-LAN ──────────────► Gaming-PC (auch wenn ausgeschaltet)
    │
    └── TCP → WMC Agent ──────────► Gaming-PC (wenn eingeschaltet)
                                      shutdown / sleep / hibernate / lock
```

**Warum ein Relay-Gerät?**  
Der Gaming-PC ist ausgeschaltet — er kann keine Pakete empfangen. Ein immer-aktives Gerät im selben Netz (Raspberry Pi, NAS, Router mit Linux) sendet das Wake-on-LAN-Paket lokal. Genau das macht auch die PS5: Sony hat immer einen kleinen Chip aktiv.

**Warum Tailscale?**  
Kein Port-Forwarding, kein DynDNS, kein offener Port ins Internet. Tailscale baut einen sicheren Mesh-VPN-Tunnel zwischen MacBook und Relay — egal ob du im Heimnetzwerk, im Café oder im Ausland bist.

---

## Voraussetzungen

| Gerät | Rolle |
|---|---|
| Gaming-Notebook (Windows 10/11) | Zielgerät — wird ferngesteuert |
| Raspberry Pi / NAS / alter PC | Relay — muss immer laufen |
| MacBook | Steuergerät |

---

## Schritt-für-Schritt-Setup

### 1. Tailscale auf allen Geräten installieren

Auf **allen drei Geräten** (Gaming-PC, Relay, MacBook):

```
https://tailscale.com/download
```

Mit demselben Account anmelden. Danach hat jedes Gerät eine feste `100.x.x.x`-IP, die immer erreichbar ist — egal wo du bist.

---

### 2. Gaming-PC vorbereiten (Windows)

**a) BIOS/UEFI:** Wake-on-LAN aktivieren  
   Suche nach: *Wake on LAN*, *Power on by PCI-E/PCIe*, *ErP Ready* (muss AUS sein)

**b) Setup-Skript als Administrator ausführen:**

```powershell
# PowerShell als Administrator
Set-ExecutionPolicy Bypass -Scope Process
.\scripts\setup_windows.ps1
```

Das Skript:
- Aktiviert Wake-on-LAN im Netzwerktreiber
- Deaktiviert Fast Startup (nötig für WoL vom echten Ausschalten)
- Aktiviert OpenSSH Server
- Installiert den WMC Agent als Windows-Dienst

**c) MAC-Adresse notieren** — das Skript zeigt sie am Ende an (z.B. `AA:BB:CC:DD:EE:FF`)

**d) Tailscale-IP des Gaming-PCs notieren** (z.B. `100.64.0.5`)

---

### 3. Relay-Gerät einrichten (Raspberry Pi / Linux)

```bash
# Repo klonen
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect

# Setup (als root)
sudo bash scripts/setup_relay.sh
```

Danach `/etc/wmc/relay.env` bearbeiten:

```bash
sudo nano /etc/wmc/relay.env
```

```env
WMC_API_TOKEN=<generierter-token-aus-setup>   # NICHT ändern, nur notieren!
WMC_PC_MAC=AA:BB:CC:DD:EE:FF                  # MAC-Adresse des Gaming-PCs
WMC_PC_IP=192.168.1.100                        # Lokale IP des Gaming-PCs
WMC_AGENT_PORT=9876
WMC_WOL_BROADCAST=255.255.255.255
WMC_RELAY_PORT=8765
```

Dienst neu starten:
```bash
sudo systemctl restart wmc-relay
```

**Relay-URL für den Client:** `http://<tailscale-ip-des-relay>:8765`  
Beispiel: `http://100.64.0.2:8765`

> **Wichtig:** Der Relay-Port 8765 muss NICHT im Router freigegeben werden.  
> Tailscale erledigt das. Der Port ist nur über Tailscale erreichbar.

---

### 4. MacBook einrichten

```bash
git clone https://github.com/minecraft425hd/windows_mac_connect.git
cd windows_mac_connect
bash scripts/setup_mac.sh

# Konfigurieren
wmc config
# Relay URL: http://100.64.0.2:8765   (Tailscale-IP des Relay)
# API Token:  <token aus /etc/wmc/relay.env>
```

---

## Verwendung

```bash
wmc status      # Ist der Gaming-PC an?
wmc wake        # Einschalten (Wake-on-LAN)
wmc shutdown    # Herunterfahren
wmc sleep       # Schlafen legen (Ruhezustand)
wmc hibernate   # Ruhezustand (Festplatte, kein Stromverbrauch)
wmc lock        # Windows-Bildschirm sperren
```

### Typischer Ablauf

```bash
# Abends den PC einschalten vom Sofa / Zug / Café:
wmc wake
# Warten bis er hochgefahren ist (~30s):
wmc status
# Später wieder ausschalten:
wmc shutdown
```

---

## Internet-Betrieb (ohne Heimnetzwerk)

Tailscale verbindet MacBook und Relay über das Internet — vollautomatisch, ohne Port-Forwarding. Die Verbindung funktioniert:

- Im Heimnetzwerk (direkte Verbindung)
- Unterwegs über Mobilfunk
- Im Hotel, Café, überall

**Voraussetzung:** Das Relay-Gerät muss eingeschaltet sein und Internet haben.

---

## Wake-on-LAN: Was funktioniert

| Zustand des PCs | WoL möglich? | Hinweis |
|---|---|---|
| Ausgeschaltet (Kaltstart) | ✅ Ja | Fast Startup muss deaktiviert sein |
| Schlafen (Sleep/S3) | ✅ Ja | Standard |
| Ruhezustand (Hibernate/S4) | ✅ Ja | |
| Ausgeschaltet (Fast Startup an) | ❌ Nein | Deshalb deaktivieren wir es |

---

## Sicherheit

- Alle Befehle sind mit einem API-Token gesichert
- Der Relay-Port ist nur über Tailscale erreichbar (kein offener Internetport)
- Der WMC Agent auf Windows lauscht nur auf Tailscale-IP (empfohlen: `WMC_AGENT_BIND=100.x.x.x`)
- Token in Dateien mit `chmod 600` gespeichert

---

## Fehlerbehebung

**`wmc wake` sendet Paket, PC startet nicht:**
1. BIOS Wake-on-LAN aktiviert? (Neustart → BIOS prüfen)
2. Fast Startup deaktiviert? (`setup_windows.ps1` nochmal laufen lassen)
3. PC ist am Stromnetz? (Laptop: muss angesteckt sein)
4. Richtiger WOL_BROADCAST? Bei manchen Routern: `192.168.1.255`

**`wmc status` zeigt "Relay: error":**
1. Tailscale auf MacBook und Relay aktiv? (`tailscale status`)
2. Relay-Dienst läuft? (`sudo systemctl status wmc-relay`)
3. Relay-URL korrekt? (`wmc config` nochmal)

**Agent nicht erreichbar (shutdown/sleep schlägt fehl):**
1. Gaming-PC an? (`wmc status`)
2. WMC Agent läuft? (Windows: `Get-Service WMCAgent`)
3. Tailscale-IP des PCs korrekt in `relay.env`? (`WMC_PC_IP`)

---

## Projektstruktur

```
relay/          Relay-Server (Flask, läuft auf Pi/NAS)
agent/          Windows-Agent (Python-Dienst auf Gaming-PC)
client/         Mac CLI-Tool (wmc)
scripts/        Setup-Skripte für alle drei Geräte
```
