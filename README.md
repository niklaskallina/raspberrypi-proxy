# raspberrypi-proxy

Eigenständiger HTTPS-Proxy (Caddy in Docker) für einen Raspberry Pi oder Server. Er nimmt alle Anfragen auf Port 80 und 443 an und verteilt sie nach Adresse auf die Webseiten: die [Burix Zeiterfassung](https://github.com/niklaskallina/zeiterfassung) und beliebige weitere. Jede Webseite bekommt automatisch ein eigenes HTTPS-Zertifikat.

Der Proxy läuft unabhängig von den Anwendungen. Wird eine Anwendung aktualisiert oder angehalten, laufen die anderen Webseiten weiter.

```
proxy/                      dieser Ordner (Raspberry Pi: /mnt/zeiterfassung/proxy, Server: /opt/proxy)
  proxy.sh                  Verwaltung
  docker-compose.yml        Caddy
  Caddyfile.oeffentlich     Modus „oeffentlich“: Zertifikate von Let's Encrypt
  Caddyfile.lokal           Modus „lokal“: Firmennetz, eigene Zertifizierungsstelle
  .env                      Einstellungen dieses Geräts          ┐
  seiten/                   eine Datei pro Webseite (*.caddy)    │ nicht im Repository,
  dateien/                  HTML-Dateien, je Webseite ein Ordner │ bleiben bei Updates erhalten
  daten/                    Zertifikate                          ┘
```

Anwendungen in Docker hängen sich an das Docker-Netz `web` und sind dort für den Proxy unter ihrem Namen erreichbar. Sie brauchen keine eigenen Ports.

## Einrichten

Mit der Zeiterfassung passiert das automatisch: Ihr Skript `deploy/proxy-anbinden.sh` klont dieses Repository in den Nachbarordner der App, richtet den Proxy ein und trägt die Zeiterfassung ein.

Von Hand (Docker muss installiert sein):

```bash
git clone https://github.com/niklaskallina/raspberrypi-proxy.git /opt/proxy
cd /opt/proxy
# öffentlich erreichbar (Port 80/443 aus dem Internet, Zertifikate von Let's Encrypt)
sudo bash proxy.sh einrichten --modus oeffentlich --email it@beispiel.de
# oder nur im Firmennetz (eigene Zertifizierungsstelle)
sudo bash proxy.sh einrichten --modus lokal --email it@beispiel.de --standard-adresse 192.168.178.50
```

Im Modus `lokal` müssen die Geräte einmal das Stammzertifikat installieren: `http://<IP-Adresse>/zertifikat`.

## Webseiten verwalten

```bash
cd /opt/proxy   # bzw. /mnt/zeiterfassung/proxy

# Einfache Webseite aus HTML-Dateien (danach Dateien nach dateien/www.beispiel.de/ kopieren)
sudo bash proxy.sh hinzufuegen www.beispiel.de

# An einen Docker-Container im Netz „web“ weiterleiten (Name:Port)
sudo bash proxy.sh hinzufuegen cloud.beispiel.de --weiterleiten nextcloud:80

# An ein Programm weiterleiten, das direkt auf dem Gerät auf Port 8080 läuft
sudo bash proxy.sh hinzufuegen tool.beispiel.de --weiterleiten 8080

sudo bash proxy.sh liste
sudo bash proxy.sh entfernen www.beispiel.de   # Dateien bleiben liegen
sudo bash proxy.sh neu-laden                   # nach eigener Änderung in seiten/
sudo bash proxy.sh status
```

Jede Änderung wird vorher geprüft. Eine fehlerhafte Konfiguration wird nicht übernommen, die laufenden Webseiten bleiben unberührt.

Damit eine Webseite erreichbar ist, muss ihre Adresse beim Domain-Anbieter auf das Gerät zeigen (z. B. CNAME `www.beispiel.de` → DynDNS-Adresse), und der Router leitet Port 80 und 443 an das Gerät weiter.

Eine Anwendung in Docker (eigener Ordner, eigene `docker-compose.yml`) hängt sich so an:

```yaml
services:
  nextcloud:
    image: nextcloud
    restart: unless-stopped
    networks: [web]
networks:
  web:
    external: true
```

Danach: `sudo bash proxy.sh hinzufuegen cloud.beispiel.de --weiterleiten nextcloud:80`.

## Aktualisieren

```bash
sudo bash proxy.sh aktualisieren
```

Holt den neuen Stand aus GitHub, lädt das aktuelle Caddy-Image und übernimmt beides ohne Unterbrechung.

## Gut zu wissen

- `seiten/zeiterfassung.caddy` schreibt die Zeiterfassung selbst (bei jedem Update), nicht von Hand ändern.
- Beim Weiterleiten auf einen Port muss das Programm auf allen Netzwerkadressen lauschen (bei Docker: `ports: ["8080:80"]`, nicht `127.0.0.1:8080:80`). `proxy.sh` gibt den Port in der Firewall (ufw) nur für den Proxy frei; von außen ist er nicht erreichbar, weil der Router nur 80 und 443 weiterleitet.
- Backups: `daten/` enthält die Zertifikate, im Modus `lokal` auch die eigene Zertifizierungsstelle. Geht sie verloren, müssen alle Geräte ein neues Stammzertifikat installieren.
- Jede weitere Webseite ist eine zusätzliche Angriffsfläche und teilt sich die Leistung des Geräts. Programme aktuell halten.
