# Nginx Proxy Manager (NPM) — Setup für Nicht-Sysadmins

Diese Anleitung führt dich Klick für Klick. Du brauchst **keine Linux- oder
nginx-Kenntnisse**. Alle Befehle stehen zum Kopieren bereit, alle UI-Schritte
mit der genauen Beschriftung.

## Was du am Ende hast

- **Eine VM** mit dem Nginx Proxy Manager
- **Web-UI im Browser** auf http://&lt;deine-vm-ip&gt;:81
- Klick-Workflow für neue Sites: Domain + Backend-IP + SSL-Häkchen → fertig
- Eingebauter **Let's Encrypt** (NPM macht das selbst, kein Cert-Sync)
- Eingebauter **Backup-Export** (Settings → Backups)

## Was du vorher brauchst

```
□ Proxmox-Host mit freiem Speicher (~20 GB)
□ 1 freie IP in deinem LAN-Subnetz (z.B. 192.168.1.20)
□ Eine Domain, deren A-Record auf diese VM-IP zeigt — pro Site eine
   (z.B. pihole.beispiel.de, ha.beispiel.de). Falls dein Router NAT macht:
   Port 80 + 443 vom Internet auf die VM-IP weiterleiten.
□ Default-NPM-Passwort merken: admin@example.com / changeme
   → musst du beim ersten Login ändern.
```

## Phase 1 — VM auf Proxmox anlegen

Auf dem **Proxmox-Host** als root in der Proxmox-Shell:

```bash
# Repo holen (git ist auf Proxmox eh vorhanden)
git clone https://github.com/mrckch/Reverse-Proxy-VM.git /opt/repo
cd /opt/repo

# VM anlegen (Defaults sind sinnvoll — 2 vCPU, 2 GB RAM, 20 GB Disk,
# Bridge vmbr0, ISO-Storage 'local'. Anpassbar via Flags, siehe --help)
./scripts/proxmox-create-vm.sh --name npm
```

Das Script lädt bei Bedarf das aktuelle Debian-13-netinstall-ISO (mit
SHA256-Verifikation), legt die VM mit dem passenden Hardware-Profil an
und gibt die nächsten Schritte aus.

In der Proxmox-Web-UI: VM starten, **Debian-13-netinstall** durchklicken:
- Sprache: deutsch (oder englisch, egal)
- „Standard-System" + „SSH-Server" reichen — nichts anderes anhaken
- Single root-Passwort genügt, einen weiteren Benutzer brauchst du nicht

## Phase 2 — Bootstrap in der VM (1 Befehl)

Per SSH oder Proxmox-Konsole **als root**:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/mrckch/Reverse-Proxy-VM.git /opt/npm-bootstrap
cd /opt/npm-bootstrap
./scripts/npm-bootstrap.sh
```

Der Wizard fragt dich:
- **Hostname**: Default „npm" — kannst du so lassen
- **Netzwerk-Interface**: vorausgewählt (das mit der Default-Route)
- **Statische IP**: deine geplante IP, z.B. `192.168.1.20/24`
- **Gateway**: deine Router-IP, z.B. `192.168.1.1`

Bestätige mit „OK". **Wenn die statische IP von der aktuellen abweicht**:
die VM rebootet, du loggst dich nach ~60 s mit der **neuen IP** wieder ein.
Phase B läuft beim Boot **automatisch weiter** — du musst nichts tun, nur
warten und beim Wieder-Einloggen `tail -f /var/log/npm-bootstrap.log`
ausführen falls du den Fortschritt sehen willst.

Phase B installiert (alles automatisch):
1. System-Updates + Basis-Pakete
2. Docker Engine + Docker-Compose-Plugin
3. Firewall (ufw) — erlaubt SSH, 80, 443, 81
4. NPM-Container starten
5. Tägliches Backup, Freitags-Update (17:00), Sicherheitsupdates mit Neustart (Samstag 05:00)

Am Ende zeigt das Script:

```
================================================================
 NPM-Bootstrap abgeschlossen.
================================================================
  Web-UI:    http://192.168.1.20:81
  Default-Login:
      E-Mail:    admin@example.com
      Passwort:  changeme
  *** SOFORT EINLOGGEN UND PASSWORT ÄNDERN! ***
```

## Phase 3 — Erstes Login (Browser)

1. Öffne im Browser: **http://&lt;deine-vm-ip&gt;:81**
2. Login: `admin@example.com` / `changeme`
3. NPM zwingt dich, **sofort** Name + E-Mail + Passwort zu ändern.
   Wähle ein **starkes Passwort** — die Web-UI ist im LAN erreichbar
   und steuert deinen Reverse-Proxy.

## Phase 4 — Erste Site einrichten (Klick-Workflow)

**Beispiel: Pi-hole, das auf 192.168.1.30:80 in deinem LAN läuft, soll
unter `pihole.beispiel.de` mit HTTPS erreichbar sein.**

Voraussetzung: A-Record `pihole.beispiel.de` zeigt auf die NPM-VM-IP
(oder bei NAT: auf deine externe IP, mit Port-Forwarding 80/443 auf die VM).

**Schritte in der NPM-Web-UI:**

1. Oben: **Hosts → Proxy Hosts**
2. Rechts: **Add Proxy Host** klicken
3. Tab **Details**:
   - Domain Names: `pihole.beispiel.de` (Enter drücken nach der Eingabe!)
   - Scheme: `http`
   - Forward Hostname / IP: `192.168.1.30`
   - Forward Port: `80`
   - „Block Common Exploits" anhaken
   - „Websockets Support" anhaken (falls Backend WebSockets nutzt)
4. Tab **SSL**:
   - SSL Certificate: **Request a new SSL Certificate**
   - „Force SSL" anhaken
   - „HTTP/2 Support" anhaken
   - „HSTS Enabled" anhaken
   - E-Mail Address for Let's Encrypt: deine E-Mail
   - „I agree to the Let's Encrypt Terms of Service" anhaken
5. **Save** klicken
6. NPM holt automatisch ein Let's-Encrypt-Cert (5-30 Sekunden)
7. Im Browser: https://pihole.beispiel.de — sollte mit gültigem Cert antworten

**Wenn der SSL-Schritt fehlschlägt** (rote Box):
- A-Record stimmt nicht oder DNS noch nicht propagiert? → `nslookup pihole.beispiel.de` prüfen
- Port 80 nicht öffentlich erreichbar? → Router-NAT prüfen (80 + 443 auf VM-IP)
- Let's Encrypt Rate-Limit (selten)? → 1 h warten

## Phase 5 — Backup einrichten

NPM bietet kein Auto-Backup. Das Bootstrap richtet deshalb ein tägliches
Backup ein. Falls deine VM älter ist, einmalig auf der VM **als root**:

```bash
cd /opt/npm-bootstrap
git pull
./scripts/npm-backup.sh --install
```

Danach läuft jede Nacht um 03:00 ein Backup — ohne dass der Proxy dafür
anhält:

- Ablage: `/var/backups/npm/npm-backup-<Datum>.tar.gz`
- Inhalt: NPM-Konfiguration, Datenbank, alle Zertifikate (keine Logs)
- Es bleiben immer nur die **letzten 14** Backups liegen, ältere werden
  gelöscht. Sind weniger als 2 GB frei, wird gar nicht gesichert — die
  Platte kann durch Backups nicht volllaufen.
- Protokoll: `/var/log/npm-backup.log`

Backup sofort von Hand auslösen:

```bash
npm-backup
```

Die Backups liegen auf der VM selbst. Geht die VM kaputt, sind sie mit
weg — zieh sie regelmäßig auf einen anderen Rechner / NAS.

### Wiederherstellen

```bash
cd /opt/npm
docker compose down
tar xzf /var/backups/npm/npm-backup-<Datum>.tar.gz -C /opt/npm
docker compose up -d
```

## Phase 6 — Updates (VM + NPM)

Der Proxy ist von außen erreichbar — das Freitags-Update (unten) hält ihn
aktuell. Bei einer akuten Lücke kannst du sofort von Hand aktualisieren,
auf der VM **als root**:

```bash
cd /opt/npm-bootstrap
git pull
./scripts/npm-update.sh
```

Das Script erledigt alles in einem Rutsch:
1. Neues NPM-Image laden
2. Backup von Daten + Zertifikaten nach `/root/npm-pre-update-….tar.gz`
   (der Proxy ist dafür wenige Sekunden weg)
3. NPM mit der neuen Version starten und prüfen
4. Debian-Pakete inkl. Kernel und Docker aktualisieren

Am Ende fragt es, ob die VM neu starten soll, falls ein neuer Kernel
installiert wurde (~1 Minute Ausfall). Mit `--reboot` startet es ohne
Rückfrage neu.

### Automatisches Update am Freitag

Das Bootstrap richtet es mit ein. Für ältere VMs einmalig **als root**:

```bash
cd /opt/npm-bootstrap && git pull && ./scripts/npm-image-update.sh --install
```

Danach wird die VM jeden **Freitag um 17:00** aktualisiert:
1. Debian-Pakete inkl. Kernel und Docker
2. Neuestes NPM-Image laden, vorher Backup, Container neu starten und
   prüfen, ob die Web-UI wieder antwortet (der Proxy ist dabei wenige
   Sekunden weg). Gibt es kein neues Image, passiert nichts.

Am Freitag **startet die VM nicht neu** — das passiert am Samstag
(nächster Abschnitt).

Läuft auf der VM schon das Freitags-Update `guest-autoupdate` (per
Ansible), übernimmt das die Debian-Pakete; das Script hängt sich dort
nur fürs NPM-Image ein — nach den Paketen, vor dem Smoketest.

Frühere Versionen dieses Repos haben tägliche Updates mit automatischem
Neustart um 04:30 eingerichtet. `--install` schaltet das ab.

Sofort von Hand: `npm-image-update` · Log: `/var/log/npm-image-update.log`

### Sicherheitsupdates mit Neustart am Samstag

Der Proxy ist das zentrale Einfallstor ins Netz. Deshalb bekommt er
einen festen Termin, an dem Lücken auch per Neustart wirklich
geschlossen werden: **Samstag um 05:00** — da ist kaum etwas los.

Das Bootstrap richtet es mit ein. Für ältere VMs einmalig **als root**:

```bash
cd /opt/npm-bootstrap && git pull && ./scripts/npm-security-updates.sh --install
```

Ablauf: Debian-Sicherheitsupdates einspielen, dann **neu starten, falls
nötig** (neuer Kernel oder Systembibliotheken, ~1 Minute Proxy-Ausfall).
Ein Kernel, den das Freitags-Update installiert hat, wird so spätestens
Samstagfrüh aktiv. Ist nichts zu tun, startet die VM nicht neu.

Sofort von Hand (startet ggf. neu!): `npm-security-updates` ·
Log: `/var/log/npm-security-updates.log`

### Nur NPM aktualisieren

Ohne den Rest (neue Versionen siehe
https://github.com/NginxProxyManager/nginx-proxy-manager/releases):

```bash
cd /opt/npm
docker compose pull
docker compose up -d
```

Daten und Certs bleiben erhalten (liegen im persistenten Volume).

## Häufige Fragen

### Wie viele Sites kann NPM verwalten?

Praktisch unbegrenzt für Homelab — mehrere hundert hostet NPM ohne Probleme.

### Wo liegen die Daten?

- `/opt/npm/data/` — NPM-Konfiguration, SQLite-DB
- `/opt/npm/letsencrypt/` — alle Let's-Encrypt-Zertifikate
- `/opt/npm/docker-compose.yml` — der Container

Beides kannst du backuppen (siehe Phase 5).

### Wie melde ich mich von außerhalb an?

Standardmäßig **gar nicht** — die Web-UI auf Port 81 ist nur im LAN
erreichbar. Das ist die empfohlene Default-Variante: vom Sofa aus
konfigurieren, von außerhalb gar nicht erreichbar.

Wenn du das später ändern willst (z.B. „mal von unterwegs einloggen"):

1. **VPN ins Heimnetz** — empfohlen. Z.B. WireGuard auf dem Router (FritzBox, OPNsense, etc.) oder als eigener Container neben NPM. Damit landest du im LAN und erreichst alles, inkl. NPM-Web-UI.
2. **Tailscale** auf der VM — dafür gibt es ein fertiges Script:
   ```bash
   cd /opt/npm-bootstrap && git pull
   ./scripts/npm-tailscale.sh                                   # nur Tailscale
   ./scripts/npm-tailscale.sh --key "ssh-ed25519 AAAA... name"  # + SSH-Key für root
   ```
   Im Terminal erscheint ein Login-Link — im Browser öffnen und die VM
   freigeben. Danach erreichen alle Geräte mit Tailscale-Client die VM
   über ihre Tailscale-IP (Web-UI auf Port 81, SSH). Komfortabler als
   WireGuard, aber abhängig vom Tailscale-Dienst. DNS der VM bleibt
   unverändert.
3. **Web-UI über NPM selbst publizieren** — wäre möglich (eigener Proxy-Host mit Access-List/Basic-Auth), ist aber für die Admin-Oberfläche eines Reverse-Proxys ein vermeidbares Risiko. Lieber Variante 1 oder 2.

### Was passiert, wenn die VM ausfällt?

Reverse-Proxy ist down, bis die VM wieder läuft (Reboot, Restore aus Backup).
Im Homelab ist das meist akzeptabel — fällt selten vor und die Recovery
ist mit einem Backup eine Frage von Minuten.

Falls du HA willst (mehrere Nodes mit Failover): das ist genau das
ursprüngliche HA-Setup in diesem Repo (Verzeichnisse `nginx/`, `keepalived/`
etc. + `bootstrap.sh`). Deutlich komplexer in Verwaltung — daher nicht
empfohlen wenn du gerade NPM mit Web-UI gewählt hast.

## Troubleshooting

### NPM-Container läuft nicht

```bash
cd /opt/npm
docker compose ps           # Status
docker compose logs npm     # Logs
docker compose restart      # Neustart
```

### „502 Bad Gateway" beim Aufruf einer Site

Das Backend (z.B. Pi-hole) ist nicht erreichbar.
- IP/Port stimmen?
- Backend läuft?
- Firewall am Backend lässt die Verbindung zu?

### SSL-Cert läuft ab

NPM erneuert automatisch (alle 60 Tage). Wenn nicht, manuell:
- Hosts → Proxy Hosts → drei Punkte → SSL → Renew

### „Reset" — alles neu

```bash
cd /opt/npm
docker compose down
rm -rf /opt/npm/data /opt/npm/letsencrypt
docker compose up -d
# UI wieder unter http://<ip>:81 mit Default-Login
```
