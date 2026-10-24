#!/usr/bin/env bash
# Burix Proxy: nimmt alle Anfragen auf Port 80/443 an und verteilt sie nach Adresse auf die Webseiten
# (Zeiterfassung und weitere). Läuft als eigenes Docker-Projekt, unabhängig von den Anwendungen.
# Im Proxy-Ordner ausführen (Raspberry Pi: /mnt/zeiterfassung/proxy, Server: /opt/proxy):
#
#   sudo bash proxy.sh einrichten --modus oeffentlich|lokal --email <e-mail> [--standard-adresse <adresse>]
#       → einmalig: Einstellungen in .env schreiben und Proxy starten (erneut aufrufen zum Ändern)
#   sudo bash proxy.sh aktualisieren   neuen Stand aus GitHub holen und übernehmen
#
#   sudo bash proxy.sh hinzufuegen www.beispiel.de
#       → HTML-Dateien aus dem Ordner dateien/www.beispiel.de/ ausliefern
#   sudo bash proxy.sh hinzufuegen app.beispiel.de --weiterleiten meine-app:8080
#       → an einen Docker-Container im Netz „web“ weiterleiten (Containername:Port)
#   sudo bash proxy.sh hinzufuegen app.beispiel.de --weiterleiten 8080
#       → an ein Programm weiterleiten, das direkt auf diesem Gerät auf Port 8080 läuft
#   sudo bash proxy.sh liste
#   sudo bash proxy.sh entfernen www.beispiel.de
#   sudo bash proxy.sh neu-laden      Konfiguration prüfen und übernehmen (z. B. nach Änderung in seiten/)
#   sudo bash proxy.sh pruefen        Konfiguration nur prüfen
#   sudo bash proxy.sh status
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen (z. B. mit: sudo bash proxy.sh …)." >&2
  exit 1
fi

HIER="$(cd "$(dirname "$0")" && pwd)"
# Docker-Netz, über das der Proxy die Anwendungen erreicht
NETZ=web
# Adressbereich der Docker-Netze – nur von dort dürfen weitergeleitete Ports auf dem Gerät erreicht werden
DOCKER_NETZ=172.16.0.0/12
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

hilfe() {
  sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p}' "$0"
  exit "${1:-0}"
}

netz_anlegen() {
  docker network inspect "$NETZ" >/dev/null 2>&1 || docker network create "$NETZ" >/dev/null
}

im_proxy_ordner() {
  [[ -f "$HIER/.env" && -d "$HIER/seiten" ]] || {
    echo "Proxy in $HIER ist noch nicht eingerichtet: sudo bash proxy.sh einrichten --modus … --email …" >&2
    exit 1
  }
  cd "$HIER"
}

laeuft() {
  docker compose ps --status running --services 2>/dev/null | grep -qx caddy
}

# Konfiguration prüfen, ohne den laufenden Proxy anzufassen
pruefen() {
  netz_anlegen
  if ! docker compose run --rm --no-deps -T caddy caddy validate --config /etc/caddy/Caddyfile >"$LOG" 2>&1; then
    echo "Die Konfiguration ist fehlerhaft:" >&2
    grep -v '"level":"info"' "$LOG" | tail -n 5 >&2
    return 1
  fi
}

# Proxy starten bzw. geänderte Konfiguration ohne Unterbrechung übernehmen
starten() {
  pruefen
  docker compose up -d --remove-orphans >"$LOG" 2>&1 || { cat "$LOG" >&2; return 1; }
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >"$LOG" 2>&1 || { cat "$LOG" >&2; return 1; }
}

# Nach einer Änderung: prüfen, bei Fehler rückgängig machen, sonst übernehmen
uebernehmen() {
  local rueckgaengig="$1"
  if ! pruefen; then
    echo "Änderung wird zurückgenommen." >&2
    eval "$rueckgaengig"
    exit 1
  fi
  if laeuft; then
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1
  else
    docker compose up -d >/dev/null 2>&1
  fi
  echo "Übernommen."
}

# Die Firewall sperrt eingehende Verbindungen – auch die vom Proxy zu Programmen auf diesem Gerät
firewall() {
  local aktion="$1" port="$2"
  command -v ufw >/dev/null && ufw status | grep -q "Status: active" || return 0
  if [[ "$aktion" == freigeben ]]; then
    ufw allow from "$DOCKER_NETZ" to any port "$port" proto tcp comment "Burix Proxy" >/dev/null
  else
    ufw delete allow from "$DOCKER_NETZ" to any port "$port" proto tcp >/dev/null 2>&1 || true
  fi
}

pruefe_adresse() {
  local adresse="$1" datei
  if ! [[ "$adresse" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "„$adresse“ ist keine gültige Adresse (z. B. www.beispiel.de, ohne https:// und ohne /)." >&2
    exit 1
  fi
  for datei in seiten/*.caddy; do
    [[ -e "$datei" && "$datei" != "seiten/$adresse.caddy" ]] || continue
    if [[ "$(seiten_adresse "$datei")" == "$adresse" ]]; then
      echo "$adresse wird bereits verwendet ($datei)." >&2
      exit 1
    fi
  done
}

# Adresse einer Seiten-Datei: erste Zeile, die einen Block öffnet
seiten_adresse() {
  sed -n '/^[^#[:space:]].*{$/{s/[[:space:]]*{$//;p;q}' "$1"
}

einrichten() {
  local modus="" email="" standard="" starten_danach=1
  while (( $# )); do
    case "$1" in
      --modus) modus="${2:-}"; shift 2 ;;
      --email) email="${2:-}"; shift 2 ;;
      --standard-adresse) standard="${2:-}"; shift 2 ;;
      --nicht-starten) starten_danach=0; shift ;;
      *) hilfe 1 ;;
    esac
  done
  cd "$HIER"

  # Bisherige Einstellungen übernehmen, angegebene Werte haben Vorrang
  alt() { [[ -f .env ]] && sed -n "s/^$1=//p" .env | tail -1 || true; }
  modus="${modus:-$(alt MODUS)}"
  email="${email:-$(alt ACME_EMAIL)}"
  standard="${standard:-$(alt STANDARD_ADRESSE)}"
  modus="${modus:-oeffentlich}"
  [[ "$modus" == oeffentlich || "$modus" == lokal ]] || { echo "--modus muss oeffentlich oder lokal sein." >&2; exit 1; }
  [[ -n "$email" ]] || { echo "--email fehlt (Kontakt für Let's Encrypt)." >&2; exit 1; }
  [[ "$modus" == oeffentlich || -n "$standard" ]] || { echo "Im Modus lokal ist --standard-adresse nötig (IP-Adresse des Geräts)." >&2; exit 1; }

  mkdir -p seiten dateien daten/caddy daten/caddy-config
  cat >.env <<ENV
# Burix Proxy – geschrieben von proxy.sh einrichten
# MODUS: oeffentlich (Let's Encrypt) oder lokal (eigene Zertifizierungsstelle, Firmennetz)
MODUS=${modus}
ACME_EMAIL=${email}
# Modus lokal: Adresse, deren Zertifikat Browser bei Aufruf per IP-Adresse bekommen
STANDARD_ADRESSE=${standard}
ENV
  netz_anlegen
  echo "Proxy eingerichtet in $HIER (Modus $modus)."
  if [[ $starten_danach == 1 ]]; then
    starten
    echo "Proxy läuft. Webseite hinzufügen: sudo bash proxy.sh hinzufuegen <adresse>"
  fi
}

aktualisieren() {
  echo "==> Neuen Stand holen ($(git rev-parse --abbrev-ref HEAD))"
  git pull --ff-only
  docker compose pull -q
  starten
  echo "Proxy aktualisiert."
}

hinzufuegen() {
  local adresse="${1:-}" ziel=""
  [[ -n "$adresse" ]] || hilfe 1
  adresse="${adresse,,}"
  shift
  if [[ "${1:-}" == "--weiterleiten" ]]; then
    ziel="${2:-}"
    if [[ "$ziel" =~ ^[0-9]+$ ]]; then
      ziel="host.docker.internal:$ziel"
    elif ! [[ "$ziel" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; then
      echo "Nach --weiterleiten fehlt das Ziel: eine Portnummer (z. B. 8080) oder Containername:Port (z. B. meine-app:80)." >&2
      exit 1
    fi
  elif [[ -n "${1:-}" ]]; then
    hilfe 1
  fi
  pruefe_adresse "$adresse"

  local datei="seiten/$adresse.caddy"
  [[ -e "$datei" ]] && echo "$adresse gibt es schon – wird überschrieben."
  if [[ -n "$ziel" ]]; then
    cat >"$datei" <<EOF
# Webseite $adresse – angelegt mit proxy.sh
$adresse {
	encode zstd gzip
	reverse_proxy $ziel
}
EOF
  else
    mkdir -p "dateien/$adresse"
    if [[ -z "$(ls -A "dateien/$adresse")" ]]; then
      cat >"dateien/$adresse/index.html" <<EOF
<!doctype html>
<html lang="de">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$adresse</title>
<p style="font-family: sans-serif; margin: 3rem auto; max-width: 30rem">Hier entsteht die Webseite <strong>$adresse</strong>.</p>
</html>
EOF
    fi
    chmod -R a+rX "dateien/$adresse"
    cat >"$datei" <<EOF
# Webseite $adresse – angelegt mit proxy.sh
# Dateien: dateien/$adresse/ (index.html ist die Startseite)
$adresse {
	encode zstd gzip
	root * /srv/$adresse
	file_server
}
EOF
  fi
  [[ "$ziel" =~ ^host\.docker\.internal:([0-9]+)$ ]] && firewall freigeben "${BASH_REMATCH[1]}"

  uebernehmen "rm -f '$datei'"
  echo
  echo "Webseite: https://$adresse"
  if [[ -n "$ziel" ]]; then
    echo "Leitet weiter an: $ziel"
  else
    echo "Dateien hierhin kopieren: $HIER/dateien/$adresse/"
  fi
  echo "Damit sie erreichbar ist, muss $adresse auf dieses Gerät zeigen (DNS-Eintrag beim Domain-Anbieter)."
}

entfernen() {
  local adresse="${1:-}"
  [[ -n "$adresse" ]] || hilfe 1
  adresse="${adresse,,}"
  local datei="seiten/$adresse.caddy"
  [[ -e "$datei" ]] || { echo "Keine Webseite $adresse vorhanden (siehe: proxy.sh liste)." >&2; exit 1; }
  local port
  port="$(sed -n 's/^\s*reverse_proxy host\.docker\.internal:\([0-9]*\)$/\1/p' "$datei")"
  mv "$datei" "$datei.entfernt"
  uebernehmen "mv '$datei.entfernt' '$datei'"
  rm -f "$datei.entfernt"
  # Port nur schließen, wenn ihn keine andere Webseite mehr braucht
  if [[ -n "$port" ]] && ! grep -qs "reverse_proxy host\.docker\.internal:$port$" seiten/*.caddy; then
    firewall schliessen "$port"
  fi
  [[ -d "dateien/$adresse" ]] && echo "Die Dateien in dateien/$adresse/ wurden nicht gelöscht."
  return 0
}

liste() {
  local gefunden=0 datei adresse ziel
  for datei in seiten/*.caddy; do
    [[ -e "$datei" ]] || continue
    gefunden=1
    adresse="$(seiten_adresse "$datei")"
    ziel="$(sed -n 's/^\s*reverse_proxy \([^ {]*\).*/\1/p' "$datei" | head -1)"
    if [[ -z "$ziel" ]]; then
      ziel="Dateien in $(sed -n 's#^\s*root \* /srv/\(.*\)#dateien/\1/#p' "$datei" | head -1)"
    fi
    printf 'https://%s  →  %s  (%s)\n' "$adresse" "$ziel" "$datei"
  done
  [[ $gefunden == 1 ]] || echo "Noch keine Webseiten eingerichtet."
}

case "${1:-}" in
  einrichten) shift; einrichten "$@" ;;
  aktualisieren) im_proxy_ordner; aktualisieren ;;
  hinzufuegen) im_proxy_ordner; shift; hinzufuegen "$@" ;;
  entfernen) im_proxy_ordner; shift; entfernen "$@" ;;
  liste) im_proxy_ordner; liste ;;
  neu-laden | starten) im_proxy_ordner; starten && echo "Proxy läuft, Konfiguration übernommen." ;;
  pruefen) im_proxy_ordner; pruefen && echo "Konfiguration in Ordnung." ;;
  status) im_proxy_ordner; docker compose ps; echo; liste ;;
  -h | --hilfe | hilfe) hilfe 0 ;;
  *) hilfe 1 ;;
esac
