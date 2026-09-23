# LüMobil Reporting-Server — Betriebshandbuch

| | |
|---|---|
| **System** | Virtueller Server für Reporting-Datenbank, nächtlichen Datenimport, Ticket-API und Metabase |
| **Zuständig** | _Name / Team eintragen_ |
| **Stand** | 22.09.2026 |
| **Quellen** | Dieses Repository: `import/`, `ticket-api/`, `server/`, `metabase-setup/` |

---

## 1. Überblick

Der Server bekommt jede Nacht zwei Datenbank-Dumps aus der Produktion, spielt sie ein und
stellt die Daten über zwei Wege bereit: die Reporting-Sichten (`rpt`, z. B. für Metabase)
und die Ticket-API für das Hilfecenter.

```
 Lieferant (Produktion)                Server (ein VPS, alles in Docker)
 ─────────────────────                 ────────────────────────────────────────────────────
                    SFTP, nur Schlüssel
 kk_mpswl-PROD-….sql ─────────────────▶ /srv/luemobil/dumps/eingang
 kk_swl-PROD-….sql                            │  luemobil-import.timer (alle 30 min)
                                              ▼
                                       import (Container) ── prüfen ── einspielen ── austauschen
                                              │
                                              ▼
                              ┌──────── postgres (Container des Hilfecenters) ────────┐
                              │  luemobil │ kk_mpswl │ kk_swl │ lue_reporting │       │
                              │                                 └─ rpt / api / protokoll
                              │                                 metabase_app          │
                              └───────▲──────────────────▲───────────────▲────────────┘
                                      │                  │               │
                                 app (Next.js)      postgrest        metabase
                                      │            127.0.0.1 nur      127.0.0.1:3001
                                      │            im Docker-Netz         │
                                      ▼                                   ▼
                                    caddy ── luemobil.…  (Hilfecenter)   reporting.…
                                                                        nur /embed, /api/embed, /app

 Admins ──SSH-Tunnel──▶ 127.0.0.1:3001 (Metabase-Oberfläche, nicht öffentlich)
```

**Wichtig zum Verständnis:**

- `kk_mpswl` und `kk_swl` sind **Wegwerf-Kopien**. Sie werden jede Nacht vollständig ersetzt.
  Hier nie etwas von Hand ändern, es ist am nächsten Morgen weg.
- `lue_reporting` und `metabase_app` sind die **einzigen Datenbanken mit eigenem Inhalt**:
  Sichten, API-Funktion, Token-Register und Abfrageprotokoll bzw. Dashboards, Fragen und
  Metabase-Konten. Nur diese beiden werden gesichert.
- **Metabase ist nicht öffentlich.** Nach außen geht nur die Einbettung einzelner Dashboards
  ins Hilfecenter. Anmeldeseite, Admin-Oberfläche und die übrige Metabase-API sind gesperrt;
  Administratoren arbeiten über einen SSH-Tunnel.
- **Die Ticket-API ist gar nicht öffentlich.** Die Hilfecenter-App ruft sie im Docker-Netz
  unter `http://postgrest:3000` auf.
- **Der PostgreSQL-Container gehört dem Hilfecenter-Stack.** Wird dieser gestoppt oder mit
  `docker compose down -v` entfernt, trifft das auch die Reporting-Daten.
- Auf diesem Server liegen **echte, nicht anonymisierte Personendaten**. Die Skripte
  `metabase-setup/01_anonymisieren.sql`, `02_anonymisieren_mpswl.sql` und
  `ticket-api/02_nur_demo.sql` sind nur für die Demo und werden hier **nie** ausgeführt.

---

## 2. Anforderungen an den Server

| | Empfehlung | Begründung |
|---|---|---|
| Betriebssystem | Debian 12 oder Ubuntu 24.04 LTS | systemd für die Timer, Docker aus den Paketquellen |
| Docker | Engine + Compose v2 | Der Hilfecenter-Stack läuft bereits so |
| PostgreSQL | **Version 17** — vorhandener Container `postgres:17-alpine` | Die Dumps stammen aus PG 17.11 und enthalten PG17-Objekte. Mit PG16 schlägt der Import fehl (getestet). |
| CPU / RAM | 2 vCPU / 8 GB | Import dauert ca. 6 Sekunden; Metabase belegt rund 2 GB |
| Java | nicht nötig | steckt im Metabase-Abbild |
| Festplatte | 40 GB | Während des Imports liegen die Daten 3-fach vor (aktuell, `_neu`, `_alt`), dazu 7 Tage Dump-Archiv und die Docker-Abbilder (rund 1,4 GB). Heute ca. 15 MB je Nacht |
| Eingehend | 22 (SFTP-Lieferant + Administration), 443 und 80 (Caddy) | Die Ticket-API braucht keinen offenen Port |
| Ausgehend | 25/587 (Mail für Fehlermeldungen), 443 (Updates, Let's Encrypt) | |
| Zeitzone | Europe/Berlin | Zeitpläne und Protokolle in Ortszeit |

---

## 3. Verzeichnisse, Benutzer, Rechte

| Pfad | Eigentümer | Rechte | Inhalt |
|---|---|---|---|
| `/opt/luemobil_reporting/` | root:root | 755 | Dieses Repository (Skripte, `compose.yml`) |
| `/opt/luemobil_reporting/.env` | root:root | 600 | **Alle Passwörter und Schlüssel** des Reporting-Stacks |
| `/etc/luemobil/import.conf` | root:root | 644 | Import-Konfiguration (in den Container gemountet) |
| `/srv/luemobil/dumps/` | root:root | 755 | SFTP-Chroot des Lieferanten (muss root gehören) |
| `/srv/luemobil/dumps/eingang/` | dumpupload:luemobil-dumps | 2770 | Hier kommen die Dumps an |
| `/srv/luemobil/archiv/` | postgres:postgres | 700 | Importierte Dumps, 7 Tage |
| `/srv/luemobil/fehler/` | postgres:postgres | 700 | Abgewiesene Dumps, 7 Tage |
| `/var/lib/luemobil-import/` | postgres:postgres | 700 | Sperre, Import-Register, `letzter_import.json` |
| `/var/backups/luemobil/` | postgres:postgres | 700 | Sicherungen von `lue_reporting`, 30 Tage |

| Systembenutzer | Zweck |
|---|---|
| `dumpupload` | Nur SFTP, nur Schlüssel, eingesperrt in `/srv/luemobil/dumps`. Keine Shell. |
| uid 70 (in den Containern `postgres`) | Import und Sicherung schreiben als diese Kennung — daher gehören ihr `archiv`, `fehler`, Status- und Sicherungsverzeichnis |

| Datenbankrolle | Zweck |
|---|---|
| `luemobil` | Superuser des vorhandenen Clusters: Eigentümer der Sichten, führt den Import aus |
| `postgres` | **Nur Eigentümername aus den Dumps**, ohne Anmelderecht (siehe 4.4) |
| `api_zugang` | Anmeldung des postgrest-Containers (Passwort), darf selbst nichts |
| `hilfecenter` | Rolle aus dem API-Token: darf nur `api.tickets_fuer_email` ausführen |
| `api_eigentuemer` | Besitzt die API-Funktion: liest 2 Sichten, schreibt nur ins Abfrageprotokoll |
| `metabase_app` | Besitzt die Metabase-Anwendungsdatenbank `metabase_app`, sonst nichts |
| `metabase_leser` | Metabase liest damit die Sichten: `SELECT` auf `rpt`, dauerhaft nur lesend |

---

## 4. Installation im Docker-Stack

Auf dem Server läuft bereits der Hilfecenter-Stack: Caddy davor, die Next.js-App und
**PostgreSQL 17 als Container** (`postgres:17-alpine`, Datenbank und Benutzer `luemobil`,
Volume `pgdata`). Der Reporting-Teil kommt als **eigener Compose-Stack** daneben und nutzt
diesen PostgreSQL mit. Kein zweiter Datenbankserver, keine doppelte Sicherung.

```
Hilfecenter-Stack (vorhanden)              Reporting-Stack (dieses Repository)
├─ caddy (Host)                            ├─ postgrest   Ticket-API, nur im Docker-Netz
├─ app (Next.js, 127.0.0.1:3000)           ├─ metabase    Dashboards, 127.0.0.1:3001
└─ postgres  ◀────── gemeinsames Netz ────▶├─ import      Einmal-Lauf, per systemd-Timer
   luemobil, kk_mpswl, kk_swl,             └─ sicherung   Einmal-Lauf, per systemd-Timer
   lue_reporting, metabase_app
```

Die App ruft die Ticketauskunft intern unter `http://postgrest:3000` auf — kein öffentlicher
Endpunkt, kein Zertifikat, keine IP-Freigabe. Öffentlich ist nur die Einbettung der
Dashboards über Caddy.

> Wer das ohne Docker betreiben will (eigener Server, PostgreSQL und Dienste direkt auf dem
> Host), findet die Schritte in **Anhang A**. Alles Übrige in diesem Handbuch gilt für beide.

### 4.1 Voraussetzungen prüfen

```bash
docker compose version
docker network ls | grep -i hilfecenter      # Name des gemeinsamen Netzes merken
docker exec -i $(docker ps --format '{{.Names}}' | grep -m1 postgres) \
  psql -U luemobil -Atc "select version()"   # muss PostgreSQL 17 sein
df -h /var/lib/docker                        # 10 GB frei reichen
```

### 4.2 Verzeichnisse, Lieferantenzugang, Repository

**Eingang:** Der Lieferant lädt in sein SFTP-Chroot hoch. Auf diesem Server ist das
`/srv/sftp/tafreporting/upload` (Benutzer `tafreporting`, Gruppe `sftponly`). Dieses
Verzeichnis wird **nicht verschoben** — der Import liest von dort und trägt die Dumps
anschließend nach `/srv/luemobil/archiv` aus dem Chroot heraus.

```bash
install -d -o root -g root -m 755 /srv/luemobil /etc/luemobil
# Die Container laufen als uid 70 (postgres im Alpine-Abbild):
install -d -o 70 -g 70 -m 750 /srv/luemobil/archiv /srv/luemobil/fehler \
                              /var/lib/luemobil-import /var/backups/luemobil

# Der Import muss im Eingang aufräumen dürfen — Schreibrecht auf das VERZEICHNIS.
# Eigentum und Rechte des Lieferanten bleiben unverändert.
# Reihenfolge beachten: chmod setzt die ACL-Maske zurück, also ZUERST chmod.
apt install -y acl
chmod 750 /srv/sftp/tafreporting/upload
setfacl -m u:70:rwx,m::rwx /srv/sftp/tafreporting/upload
getfacl -p /srv/sftp/tafreporting/upload | grep '^user:70'
#   richtig:  user:70:rwx
#   falsch:   user:70:rwx  #effective:r-x   -> Maske kappt das Schreibrecht

install -o root -g root -m 644 /opt/luemobil_reporting/server/import.conf.beispiel /etc/luemobil/import.conf
nano /etc/luemobil/import.conf                      # MELDUNG_AN und Mindestmengen prüfen
```

Der SFTP-Zugang selbst ist eingerichtet (Chroot `/srv/sftp/tafreporting`, root:root 755).
`server/sshd-dumps.conf` zeigt, wie der zugehörige `Match`-Block aussehen sollte:
`internal-sftp` mit `-u 0007`, kein Shell-Zugang, keine Weiterleitungen, Anmeldung per
Schlüssel. Die Vereinbarung über Dateinamen und Format steht in **Anhang A.4**.

### 4.3 Konfiguration des Stacks

```bash
cd /opt/luemobil_reporting
cp server/reporting.env.beispiel .env && chmod 600 .env

openssl rand -hex 24     # -> API_DB_PASSWORT   (Rolle api_zugang)
openssl rand -hex 24     # -> MB_DB_PASSWORT    (Rolle metabase_app)
openssl rand -base64 48  # -> JWT_SECRET        (Tokens der Ticket-API)
openssl rand -base64 32  # -> MB_ENCRYPTION_SECRET_KEY
openssl rand -hex 32     # -> MB_EMBEDDING_SECRET_KEY (geht ans Hilfecenter)
nano .env                # Werte eintragen, dazu POSTGRES_PASSWORD und HILFECENTER_NETZ
```

`POSTGRES_PASSWORD` ist dasselbe wie in der `.env` des Hilfecenters — der Import und Metabase
melden sich damit am vorhandenen PostgreSQL an.

### 4.4 Erstimport

```bash
# Dumps einmalig ablegen (oder den Lieferanten hochladen lassen)
cp kk_mpswl-PROD-*.sql kk_swl-PROD-*.sql /srv/luemobil/dumps/eingang/

cd /opt/luemobil_reporting && docker compose run --rm import
```

Erwartet: `Rolle postgres angelegt`, beide Datenbanken eingespielt, dann
`Rauchtest übersprungen: lue_reporting existiert noch nicht (Ersteinrichtung)`.

> **Warum die Rolle `postgres` angelegt wird:** Die Dumps enthalten rund 240-mal
> `ALTER ... OWNER TO postgres`. In eurem Cluster heißt der Superuser `luemobil`, eine Rolle
> `postgres` gibt es nicht. Der Import legt sie deshalb **ohne Anmelderecht** an (`NOLOGIN`)
> — ein reiner Eigentümername, kein zusätzlicher Zugang. Steuerbar über `DUMP_ROLLEN`
> in der `import.conf`.

### 4.5 Reporting-Sichten

```bash
cd /opt/luemobil_reporting
# Findet den PostgreSQL-Container des Hilfecenter-Stacks selbst:
PG="docker exec -i $(docker ps --format '{{.Names}}' | grep -m1 postgres) psql -U luemobil -v ON_ERROR_STOP=1"
echo "$PG"     # zur Kontrolle: der Containername muss darin stehen

$PG -d postgres -c "CREATE DATABASE lue_reporting"
sed "s/PGUSER_PLACEHOLDER/luemobil/" metabase-setup/03_reporting_views.sql | $PG -q -d lue_reporting
for f in 04_kennzahlen 06_payone_und_kennzahlen 08_korrekturen; do
  $PG -q -d lue_reporting < metabase-setup/$f.sql
done
$PG -At -d lue_reporting -c "SELECT count(*) FROM rpt.bestellposition"      # > 0
```

`postgres_fdw` verbindet sich innerhalb desselben Containers auf `localhost` — deshalb bleibt
in `03_reporting_views.sql` nur der Platzhalter für den Benutzer zu ersetzen.

> **Nicht ausführen:** `01_anonymisieren.sql`, `02_anonymisieren_mpswl.sql` (nur Demo).
> **Achtung:** Die Skripte 03–08 legen Sichten mit `DROP … CASCADE` neu an. Danach fehlen die
> Rechte der Ticket-API: 4.6 erneut ausführen. Für Metabase ist das nicht nötig,
> `metabase_leser` bekommt neue Sichten über Standardrechte automatisch.

### 4.6 Ticket-API und Metabase-Rollen in der Datenbank

```bash
cd /opt/luemobil_reporting
source .env
$PG -q -d lue_reporting -v db_passwort="$API_DB_PASSWORT" < ticket-api/01_datenbank.sql
$PG -q -d lue_reporting -v pw_app="$MB_DB_PASSWORT" -v pw_leser="<neu: openssl rand -hex 24>" \
        -v eigentuemer=luemobil < server/metabase_datenbank.sql
```

**Nicht** `ticket-api/02_nur_demo.sql` ausführen — das gilt nur für die anonymisierte Demo.
Das Passwort von `metabase_leser` wird in 4.8 gebraucht, also notieren.

### 4.7 Stack starten

```bash
cd /opt/luemobil_reporting && docker compose up -d
docker compose ps
docker compose logs -f metabase       # 1–2 Minuten bis "Metabase Initialization COMPLETE"
```

Die Ticket-API ist damit im Docker-Netz unter `http://postgrest:3000` erreichbar, Metabase
auf `127.0.0.1:3001`. Nach außen ist noch nichts offen.

### 4.8 Dashboards übernehmen

Die Dashboards liegen in der lokalen Metabase (H2-Datei). Metabase bringt dafür `load-from-h2`
mit. **Lokal geprobt:** 5 Dashboards und 80 Fragen übertragen, IDs 6–9 erhalten.

```bash
# 1. Auf dem Mac: Metabase stoppen, Datei kopieren, wieder starten
cd ~/Documents/luemobil_reporting/metabase-setup && ./stop.sh
scp metabase-app-db.mv.db admin@server:/tmp/ && ./start.sh

# 2. Auf dem Server: Metabase anhalten, Zieldatenbank leeren, Datei laden
cd /opt/luemobil_reporting && source .env
docker compose stop metabase

# load-from-h2 besteht auf einer LEEREN Zieldatenbank. Hat Metabase dort schon
# sein Schema angelegt (nach dem ersten Start), wird sie neu erstellt:
$PG -d postgres -c "DROP DATABASE IF EXISTS metabase_app WITH (FORCE)"
$PG -d postgres -c "CREATE DATABASE metabase_app OWNER metabase_app ENCODING 'UTF8' TEMPLATE template0"

# --user root ist nötig: Metabase lässt vor dem Kopieren Liquibase über die
# H2-Datei laufen und SCHREIBT dabei hinein ("The database is read only", sonst).
docker run --rm --user root --network "$HILFECENTER_NETZ" -v /tmp:/h \
  -e MB_DB_TYPE=postgres -e MB_DB_HOST="$PG_HOST" -e MB_DB_PORT=5432 \
  -e MB_DB_DBNAME=metabase_app -e MB_DB_USER=metabase_app -e MB_DB_PASS="$MB_DB_PASSWORT" \
  -e MB_ENCRYPTION_SECRET_KEY="$MB_ENCRYPTION_SECRET_KEY" \
  --entrypoint java metabase/metabase:v0.63.18 \
  --add-opens java.base/java.nio=ALL-UNNAMED -jar /app/metabase.jar load-from-h2 /h/metabase-app-db

# ERST prüfen, DANN aufräumen — bei einem Fehlschlag bleibt die Datei liegen
# und muss nicht erneut übertragen werden:
$PG -At -d metabase_app -c "SELECT count(*) FROM report_dashboard"     # 9 erwartet
docker compose up -d metabase
shred -u /tmp/metabase-app-db.mv.db /tmp/metabase-app-db.trace.db 2>/dev/null
```

Danach die Nacharbeiten. Sie laufen als eigener Dienst im Docker-Netz, ein SSH-Tunnel ist
dafür nicht nötig. Vorher in der `.env` ergänzen: `MB_LESER_PASSWORT` (aus 4.6) und die vier
`MB_ADMIN_*`-Zeilen für das persönliche Admin-Konto.

```bash
cd /opt/luemobil_reporting
docker compose run --rm nacharbeiten
```

Alternativ vom Arbeitsplatz aus über einen Tunnel, etwa um es zu beobachten:

```bash
ssh -L 3001:127.0.0.1:3001 root@<server>     # offen lassen
MB_URL=http://localhost:3001 LESER_PASSWORT=… ADMIN_EMAIL=… ADMIN_VORNAME=… \
ADMIN_NACHNAME=… ADMIN_PASSWORT=… DB_HOST=postgres \
  /opt/luemobil_reporting/server/metabase_nach_umzug.py
```

Das Skript stellt die Verbindung auf `metabase_leser` um, entfernt die Beispieldatenbank,
schaltet den Zwischenspeicher ab (sonst könnten nach dem Import alte Zahlen erscheinen),
legt das persönliche Admin-Konto an, deaktiviert das Demo-Konto und prüft die
Einbettungsfreigabe der Dashboards 6–9. Danach im Tunnel von Hand: die vier alten Dashboards
aus der Bauphase (IDs 2–5) archivieren und weitere Konten anlegen.

### 4.9 Caddy: Dashboards nach außen

**Vorher:** `reporting.swl-innovation.de` muss im DNS auf den Server zeigen, sonst bekommt
Caddy kein Zertifikat. Prüfen mit `dig +short reporting.swl-innovation.de`.

Die Zugriffe landen im Journal (`journalctl -u caddy`), nicht in einer eigenen Datei —
die systemd-Härtung des Caddy-Dienstes verbietet ihm das Schreiben außerhalb weniger
Verzeichnisse.

```bash
# Sauberer als Anhängen ans Caddyfile: eigene Datei, einmalig eingebunden mit
#   import /etc/caddy/conf.d/*.caddy     (ganz oben im Caddyfile)
mkdir -p /etc/caddy/conf.d
cp /opt/luemobil_reporting/server/Caddyfile-reporting.example /etc/caddy/conf.d/reporting.caddy
sed -i 's/REPORTING.EXAMPLE.DE/reporting.swl-innovation.de/g;
        s#HILFECENTER-ADRESSEN#https://luemobil.swl-innovation.de#' /etc/caddy/conf.d/reporting.caddy

caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

> „ambiguous site definition" heißt, dass derselbe Hostname zweimal im Caddyfile steht — etwa
> weil der Block versehentlich zweimal angehängt wurde. `grep -n "reporting" /etc/caddy/Caddyfile`
> zeigt die Stellen; einer der beiden Blöcke muss weg.

Durchgelassen werden nur `/embed/`, `/api/embed/` und `/app/`, alles andere gibt `404`.
Eine zusätzliche `Content-Security-Policy` lässt nur das Hilfecenter als einbettende Seite zu.
Im Zugriffslog wird das Token im Pfad durch `…` ersetzt. **Lokal geprüft**, einschließlich
Log-Kürzung und Sperre für Anmeldeseite, Admin-Oberfläche und übrige API.

### 4.10 Hilfecenter anschließen

In der `.env` des Hilfecenters:

```bash
LUEMOBIL_API_URL=http://postgrest:3000
METABASE_URL=https://reporting.swl-innovation.de
METABASE_DASHBOARDS=ueberblick:6,abo:7,payone:8,betrieb:9
```

Dazu die beiden Geheimnisse als Dateien in dessen `secrets/`:

```bash
cd /pfad/zum/hilfecenter
/opt/luemobil_reporting/ticket-api/token.sh neu hilfecenter-prod 365   # siehe 5.3 (Variante Docker)
printf '%s' '<token>'          > secrets/luemobil_api_token
printf '%s' '<MB_EMBEDDING_SECRET_KEY aus /opt/luemobil_reporting/.env>' > secrets/metabase_embed_secret
chmod 400 secrets/luemobil_api_token secrets/metabase_embed_secret
docker compose up -d app
```

Damit die App den Container `postgrest` erreicht, müssen beide Stacks dasselbe Netz nutzen —
das stellt `HILFECENTER_NETZ` in der `.env` des Reporting-Stacks sicher.

### 4.11 Zeitpläne aktivieren

```bash
cp /opt/luemobil_reporting/server/luemobil-*.service /opt/luemobil_reporting/server/luemobil-*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now luemobil-import.timer luemobil-import-waechter.timer luemobil-sicherung.timer
systemctl list-timers 'luemobil-*'
```

| Timer | Wann | Was |
|---|---|---|
| `luemobil-import.timer` | alle 30 Minuten | `docker compose run --rm import` — ist nichts da, endet der Lauf sofort |
| `luemobil-import-waechter.timer` | täglich 09:00 | meldet, wenn der letzte erfolgreiche Import älter als 30 Stunden ist |
| `luemobil-sicherung.timer` | täglich 04:15 | sichert `lue_reporting` und `metabase_app`, behält 30 Tage |

### 4.12 Abnahme

```bash
cd /opt/luemobil_reporting

# Import: 32 Prüfungen mit eigenen Testdatenbanken, fasst die echten nicht an
docker compose run --rm --entrypoint /opt/luemobil/test_import.sh import \
  /srv/luemobil/archiv/<mpswl-dump>.sql /srv/luemobil/archiv/<swl-dump>.sql

# Ticket-API aus dem Docker-Netz, wie die App sie ruft
docker run --rm --network "$HILFECENTER_NETZ" curlimages/curl -s -X POST \
  http://postgrest:3000/rpc/tickets_fuer_email \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"p_email":"<bekannte adresse>"}'

# Dashboards über den Tunnel
METABASE_URL=http://localhost:3001 METABASE_EMBED_SECRET=<schlüssel> \
  metabase-setup/einbettung_pruefen.py

# Von außen muss die Metabase-Oberfläche 404 liefern
curl -s -o /dev/null -w '%{http_code}\n' https://reporting.swl-innovation.de/
```

## 5. Täglicher Betrieb

### 5.1 So läuft ein Import

1. **Suchen:** neuestes `kk_mpswl-PROD-*` und `kk_swl-PROD-*` im Eingang. Ältere, liegen gebliebene Dumps werden übersprungen und archiviert.
2. **Warten, falls nötig:** Fehlt der Partner-Dump, wartet der Import bis zu 6 Stunden. Wird eine Datei noch geschrieben, wartet er auf den nächsten Lauf.
3. **Vollständigkeit:** Endzeile von `pg_dump` vorhanden, beide Dumps vom selben Tag, Paar noch nicht importiert (SHA-256-Register).
4. **Einspielen** in `kk_mpswl_neu` und `kk_swl_neu`, jeweils in einer einzigen Transaktion. Die laufenden Datenbanken bleiben dabei unberührt.
5. **Plausibilität:** Mindestmengen, und keine Tabelle ist um mehr als 5 % geschrumpft (Konten, Bestellungen, Abo-Berechtigungen, Positionen, Produkte).
6. **Austausch** per Umbenennen: aktuell → `_alt`, `_neu` → aktuell. Dauert unter einer Sekunde. Offene Verbindungen zu den Quelldatenbanken werden getrennt, `lue_reporting` verbindet sich beim nächsten Zugriff automatisch neu (getestet).
7. **Rauchtest:** `SELECT count(*) FROM rpt.bestellposition` muss > 0 liefern. Wenn nicht, wird sofort zurückgetauscht.
8. **Abschluss:** Dumps ins Archiv, Status nach `/var/lib/luemobil-import/letzter_import.json`, Dumps älter als 7 Tage löschen.

**Grundsatz:** Scheitert irgendein Schritt, bleiben die Daten von gestern aktiv. Die Dumps
wandern nach `fehler/`, und es kommt eine Mail.

**Während des Austauschs** kann eine einzelne API- oder Metabase-Anfrage, die genau in dieser
Sekunde läuft, mit Fehler enden. Die nächste Anfrage funktioniert wieder.

**Metabase braucht beim Import nichts zu tun.** Es liest `lue_reporting`, und die wird nicht
angefasst. Die Verbindungen in die ausgetauschten Quelldatenbanken baut PostgreSQL selbst neu
auf. Lokal geprüft: Nach dem Abbruch aller Verbindungen liefert dieselbe Frage sofort wieder
Zahlen. Ein Neustart von Metabase nach dem Import ist **nicht** nötig. Weil der Zwischenspeicher
abgeschaltet ist (4.8.4), zeigen die Dashboards sofort den neuen Stand.

### 5.2 Nachsehen

```bash
cd /opt/luemobil_reporting
docker compose run --rm import --status      # letzter erfolgreicher Import (JSON)
journalctl -u luemobil-import --since today  # Protokoll der Importläufe
systemctl list-timers 'luemobil-*'           # nächste Läufe
docker compose ps                            # laufen postgrest und metabase?
ls -l /srv/luemobil/dumps/eingang /srv/luemobil/fehler
```

Beispiel eines erfolgreichen Laufs:

```
Importiere Paar vom 20260912: kk_mpswl-PROD-20260912020000.sql, kk_swl-PROD-20260912020000.sql
  kk_mpswl_neu eingespielt (2 s)
  kk_swl_neu eingespielt (2 s)
  kk_mpswl.customers: 2132 -> 2132
  kk_mpswl.orders: 1551 -> 1551
  kk_mpswl.abo_berechtigungen_luebeck: 8267 -> 8267
  kk_swl.orders: 1551 -> 1551
  kk_swl.orders_products: 1551 -> 1551
  kk_swl.products: 34 -> 34
  Datenbanken ausgetauscht
  Rauchtest ok: 1551 Zeilen über lue_reporting
Import erfolgreich. Vorheriger Stand liegt als kk_mpswl_alt / kk_swl_alt bereit.
```

### 5.3 Ticket-API

Tokens werden mit `token.sh` verwaltet. Im Docker-Betrieb zeigt es über `DB`-Variablen auf
den Container, der JWT-Schlüssel kommt aus der `.env`:

```bash
cd /opt/luemobil_reporting && source .env
export PGHOST=127.0.0.1 PGPORT=5433 PGUSER=luemobil PGPASSWORD="$POSTGRES_PASSWORD"
# Zugang zum Container-PostgreSQL, solange kein Port veröffentlicht ist:
# oder direkt im Container arbeiten:
#   docker exec -i $(docker ps --format '{{.Names}}' | grep -m1 postgres) psql -U luemobil …

printf '%s' "$JWT_SECRET" > /tmp/jwt && JWT_SECRET_DATEI=/tmp/jwt DB=lue_reporting \
  ticket-api/token.sh liste                     # Tokens, Zustand, Anzahl Abfragen
JWT_SECRET_DATEI=/tmp/jwt DB=lue_reporting ticket-api/token.sh sperren <jti>
shred -u /tmp/jwt

# Abfrageprotokoll ansehen
docker exec -i $(docker ps --format '{{.Names}}' | grep -m1 postgres) \
  psql -U luemobil -d lue_reporting -c \
  "SELECT zeitpunkt, anwendung, bearbeiter, ip, treffer FROM protokoll.abfrage ORDER BY id DESC LIMIT 20"

docker compose logs -f postgrest                # Fehler der API (ohne Daten)
```

### 5.4 Metabase

```bash
ssh -L 3001:127.0.0.1:3001 admin@server      # Oberfläche: http://localhost:3001
cd /opt/luemobil_reporting && docker compose ps metabase
docker compose logs -f metabase
journalctl -u caddy -f | grep reporting       # eingebettete Zugriffe, Token gekürzt
```

Dashboards ändert man in der Oberfläche über den Tunnel. Neue Dashboards, die das Hilfecenter
zeigen soll, brauchen *Teilen → Einbetten → Statische Einbettung → Veröffentlichen*, und das
Hilfecenter braucht die neue Dashboard-ID.

---

## 6. Störungen

| Meldung / Symptom | Ursache | Vorgehen |
|---|---|---|
| `… ist unvollständig (Endmarke von pg_dump fehlt)` | Upload abgebrochen oder Dump-Export beim Lieferanten fehlgeschlagen | Lieferant informieren, neu hochladen lassen. Nichts weiter zu tun |
| `Seit … min nur kk_… vorhanden — zweiter Dump fehlt` | Lieferant hat nur einen Dump geschickt | Lieferant informieren. Wenn der zweite kommt: beide aus `fehler/` zurück nach `eingang/` (6.1) |
| `Einspielen von … fehlgeschlagen` + SQL-Fehler davor | Dump fehlerhaft, oder Quellsystem hat die PostgreSQL-Version gewechselt | Fehlerzeile im Journal lesen. Neue Hauptversion beim Lieferanten → Server-PostgreSQL angleichen |
| `…orders: Rückgang von X auf Y Zeilen` | Export unvollständig, oder beim Lieferanten wurde tatsächlich gelöscht | Beim Lieferanten nachfragen. Ist der Rückgang echt: Grenze in `import.conf` vorübergehend anheben, Dumps zurück nach `eingang/` |
| `Rauchtest fehlgeschlagen` + Rückbau | Schema im Quellsystem geändert (Spalte umbenannt/entfernt), Sichten passen nicht mehr | Sichten anpassen (`metabase-setup/`), dann 4.6 und 4.7.1 erneut, dann Dumps zurück nach `eingang/` |
| `PostgreSQL 17 oder neuer nötig` | Falsche Server-Version | Siehe 4.1 |
| `Austausch … nach 5 Versuchen nicht möglich` | Etwas hält Verbindungen zu `kk_*` offen und verbindet sich sofort neu | `SELECT datname, usename, application_name FROM pg_stat_activity WHERE datname LIKE 'kk_%'`, Verursacher abstellen |
| `Rückbau von … fehlgeschlagen — MANUELL PRÜFEN` | Sehr unwahrscheinlich, z. B. Datenbankserver während des Tauschs abgestürzt | 6.2 |
| Wächter-Mail `Letzter erfolgreicher Import vor … h` | Keine Dumps angekommen, oder alle Läufe gescheitert | `ls eingang/ fehler/`, `journalctl -u luemobil-import --since yesterday`. Kam nichts: Lieferant fragen |
| API liefert `502` | PostgREST läuft nicht | `systemctl status postgrest-tickets`, `journalctl -u postgrest-tickets` |
| API liefert `401` für gültiges Token | Token gesperrt/abgelaufen, oder JWT-Schlüssel geändert | `token.sh liste` |
| API liefert `500` nach Arbeiten an den Sichten | Rechte auf `rpt`-Sichten verloren (siehe Achtung in 4.6) | 4.7.1 erneut ausführen |
| `docker compose up` meldet „network … not found" | Netzname in der `.env` stimmt nicht, oder der Hilfecenter-Stack läuft nicht | `docker network ls`, `HILFECENTER_NETZ` anpassen |
| Import: `role "postgres" does not exist` | `DUMP_ROLLEN` in der `import.conf` leer | Eintrag `DUMP_ROLLEN="postgres"` ergänzen (siehe 4.4) |
| Import: „… ist nicht lesbar" | Dump wurde von Hand kopiert und hat `600`; der Lieferant lädt sonst mit `644` hoch | `chmod 644` auf die Datei — das Verzeichnis bleibt mit `750` geschlossen |
| Import: `permission denied` beim Verschieben der Dumps, `getfacl` zeigt `#effective:r-x` | Ein `chmod` nach dem `setfacl` hat die ACL-Maske zurückgesetzt | `setfacl -m u:70:rwx,m::rwx <eingang>` (4.2) |
| Import: `permission denied` beim Verschieben der Dumps | Verzeichnisse gehören nicht uid 70 | `chown -R 70:70 /srv/luemobil/archiv /srv/luemobil/fehler /var/lib/luemobil-import`, ACL für den Eingang (4.2) |
| App meldet, die Ticket-API sei nicht erreichbar | Beide Stacks nicht im selben Netz | `docker inspect <app-container> -f '{{json .NetworkSettings.Networks}}'` mit dem postgrest-Container vergleichen |
| `load-from-h2`: „The database is read only" | Der Container darf nicht in die H2-Datei schreiben, Liquibase braucht das aber | `docker run` mit `--user root` (4.8) |
| `load-from-h2`: Zieldatenbank ist nicht leer | Metabase lief zwischendurch und hat sein Schema angelegt | `metabase_app` löschen und neu anlegen (4.8) |
| Metabase startet nicht, Log: „Unable to connect to Metabase application database" | `metabase_app`-Zugang falsch | Werte in `/opt/luemobil_reporting/.env` prüfen, `docker compose up -d metabase` |
| Metabase-Dashboards leer, Kacheln melden Fehler | Verbindung zu `lue_reporting` gestört oder Rechte nach Sichten-Neuanlage verloren | Im Tunnel *Admin → Datenbanken → LüMobil Reporting → Verbindung testen*; 4.8.1 erneut ausführen |
| Dashboards zeigen alte Zahlen | Zwischenspeicher wieder eingeschaltet | Im Tunnel *Admin → Performance → Standardregel* auf „Kein Zwischenspeicher"; siehe 4.8 |
| Eingebettetes Dashboard im Hilfecenter leer | Token, Freigabe, IP oder CSP — siehe Fehlerbilder in `metabase-setup/EINBINDUNG_DASHBOARDS_HILFECENTER.md` | Dort Abschnitt 6 |
| Caddy startet nicht: `open /var/log/caddy/…: permission denied` | Der Dienst darf dort nicht schreiben (systemd-Härtung), auch wenn das Verzeichnis ihm gehört | Im Block `output stderr` statt `output file` — dann steht alles im Journal |
| `https://reporting…/` liefert die Metabase-Anmeldung statt `404` | Caddy-Block fehlt oder ist falsch eingehängt | 4.9 prüfen, `caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy` |
| Platte voll | Archiv oder `_alt` gewachsen | `du -sh /srv/luemobil/* /var/lib/postgresql`. `_alt`-Datenbanken dürfen gelöscht werden |

### 6.1 Dumps erneut importieren

```bash
mv /srv/luemobil/fehler/kk_*-PROD-JJJJMMTT*.sql /srv/luemobil/dumps/eingang/
cd /opt/luemobil_reporting && docker compose run --rm import      # oder: systemctl start luemobil-import
```

Ein schon erfolgreich importiertes Paar erkennt das Skript und überspringt es. Um es trotzdem neu
einzuspielen, die beiden Zeilen aus `/var/lib/luemobil-import/importiert.txt` löschen.

### 6.2 Von Hand auf den Stand von gestern zurück

Nur nötig, wenn ein Import „erfolgreich“ war, die Daten aber inhaltlich falsch sind.

```bash
systemctl stop luemobil-import.timer
docker exec -i $(docker ps --format '{{.Names}}' | grep -m1 postgres) psql -U luemobil <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('kk_mpswl','kk_swl','kk_mpswl_alt','kk_swl_alt');
ALTER DATABASE kk_mpswl RENAME TO kk_mpswl_defekt;  ALTER DATABASE kk_mpswl_alt RENAME TO kk_mpswl;
ALTER DATABASE kk_swl   RENAME TO kk_swl_defekt;    ALTER DATABASE kk_swl_alt   RENAME TO kk_swl;
SQL
docker exec -i $(docker ps --format '{{.Names}}' | grep -m1 postgres) \
  psql -U luemobil -d lue_reporting -Atc "SELECT count(*) FROM rpt.bestellposition"
# Ursache klären, dann: DROP DATABASE kk_mpswl_defekt; DROP DATABASE kk_swl_defekt;
systemctl start luemobil-import.timer
```

### 6.3 Token kompromittiert

Token sperren wie in 5.3. Ist der **JWT-Schlüssel** selbst betroffen (`/opt/luemobil_reporting/.env`
gelangte nach außen): neuen Schlüssel erzeugen, `JWT_SECRET` in der `.env` ersetzen,
`docker compose up -d postgrest`. Damit sind **alle** Tokens ungültig, neue ausstellen und
`secrets/luemobil_api_token` im Hilfecenter austauschen.

### 6.4 Metabase-Einbettung: Schlüssel wechseln

Neuen Schlüssel erzeugen (`openssl rand -hex 32`), in `/opt/luemobil_reporting/.env` unter
`MB_EMBEDDING_SECRET_KEY` eintragen, `docker compose up -d metabase`. Alle bisherigen Tokens
sind sofort ungültig; das Hilfecenter braucht den neuen Schlüssel in
`secrets/metabase_embed_secret`, sonst bleiben die Dashboards leer.

### 6.5 `lue_reporting` wiederherstellen

```bash
cd /opt/luemobil_reporting && docker compose stop postgrest
docker compose run --rm --entrypoint sh sicherung -c '
  dropdb lue_reporting && createdb lue_reporting &&
  pg_restore -d lue_reporting /sicherung/lue_reporting-JJJJMMTT.dump'
docker compose up -d postgrest
```

### 6.6 Metabase wiederherstellen

```bash
cd /opt/luemobil_reporting && docker compose stop metabase
docker compose run --rm --entrypoint sh sicherung -c '
  dropdb metabase_app && createdb -O metabase_app metabase_app &&
  pg_restore -d metabase_app /sicherung/metabase_app-JJJJMMTT.dump'
docker compose up -d metabase
```

Wichtig: Dieselbe Metabase-Version wie zum Zeitpunkt der Sicherung verwenden, und
`MB_ENCRYPTION_SECRET_KEY` muss unverändert sein, sonst bleiben die Datenbankzugänge unlesbar.

---

## 7. Datenschutz

| Wo | Personenbezug | Aufbewahrung | Zugriff |
|---|---|---|---|
| `kk_mpswl`, `kk_swl` | Kundendaten der Produktion | bis zum nächsten Import (+1 Tag als `_alt`) | nur `postgres`, über Sichten |
| `/srv/luemobil/archiv`, `fehler` | vollständige Dumps inkl. Passwort-Hashes | 7 Tage (`ARCHIV_TAGE`) | nur `postgres` (700) |
| `protokoll.abfrage` | gesuchte E-Mail-Adresse, Bearbeiter, IP | 12 Monate (Vorschlag) | nur Datenbank-Administratoren |
| `/var/backups/luemobil` | Abfrageprotokoll | 30 Tage | nur `postgres` (700) |
| `metabase_app` | Metabase-Konten (Name, E-Mail), keine Kundendaten | dauerhaft | nur `metabase_app` |
| Dashboard „4 — Betrieb und Störungen" | Tabelle mit einzelnen Bestellungen (Bestellnummer) | jeweils aktueller Stand | wer das Dashboard im Hilfecenter sieht |
| Caddy-Log `reporting` | IP-Adresse, Token gekürzt, keine E-Mail | Log-Rotation von Caddy | root |
| Container-Logs (`docker compose logs`) | IP-Adresse, keine E-Mail, keine Tokens | Docker-Log-Rotation | root |

Löschung des Abfrageprotokolls monatlich, z. B. per `/etc/cron.d/luemobil`:

```
0 5 1 * * postgres psql -d lue_reporting -qc "SELECT protokoll.aufraeumen(12)"
```

Offene Punkte mit dem Datenschutz: Aufbewahrungsfrist des Abfrageprotokolls,
Eintrag „Auskunft im Hilfecenter“ ins Verzeichnis der Verarbeitungstätigkeiten,
Auftragsverarbeitung mit dem Hoster des virtuellen Servers.

---

## 8. Wartung

| Aufgabe | Wie |
|---|---|
| Sicherheitsupdates | `apt update && apt upgrade` für den Host |
| Abbilder aktualisieren | Version in `compose.yml` hochsetzen, `docker compose pull && docker compose up -d`, danach Abnahme aus 4.12. Vorher Sicherung prüfen |
| PostgreSQL-Hauptversion | Gehört dem Hilfecenter-Stack. Erst wechseln, wenn der Lieferant wechselt — Dumps einer neueren Hauptversion lassen sich nicht einspielen |
| Token erneuern | Vor Ablauf neues ausstellen, übergeben, altes sperren (`token.sh liste` zeigt `gueltig_bis`) |
| Weitere einbettende Adresse | In `/etc/caddy/Caddyfile` bei `frame-ancestors` ergänzen, `systemctl reload caddy` |
| Metabase aktualisieren | Sicherung von `metabase_app` prüfen, neues Abbild in `compose.yml`, `docker compose up -d metabase` (die Datenbank wandelt sich selbst um), danach Abnahme aus 4.12 |
| Neues Dashboard fürs Hilfecenter | Im Tunnel veröffentlichen (5.4), ID ans Hilfecenter geben |
| Sichten geändert | 4.5, danach unbedingt 4.6 |

---

## 9. Dateien im Repository

| Datei | Zweck |
|---|---|
| `compose.yml` | Der Reporting-Stack: postgrest, metabase, import, sicherung |
| `import/Dockerfile`, `sichern.sh` | Werkzeug-Abbild (psql, pg_dump) und die Sicherung |
| `server/reporting.env.beispiel` | Vorlage für `/opt/luemobil_reporting/.env` |
| `server/Caddyfile-reporting.example` | Caddy: nur Einbettungspfade, CSP, Token im Log gekürzt |
| `server/ohne-docker/` | nginx- und systemd-Dateien für den Betrieb ohne Docker (Anhang A) |
| `import/import.sh` | Der Import (Abschnitt 5.1) |
| `import/test_import.sh` | Abnahmetest mit Testdatenbanken (4.9) |
| `server/import.conf.beispiel` | Vorlage für `/etc/luemobil/import.conf` |
| `server/luemobil-import.{service,timer}` | Import alle 30 Minuten |
| `server/luemobil-import-waechter.{service,timer}` | Tägliche Prüfung der Aktualität |
| `server/luemobil-sicherung.{service,timer}` | Tägliche Sicherung von `lue_reporting` |
| `server/luemobil-meldung@.service`, `meldung.sh` | Fehlermail |
| `server/postgrest-tickets.service` | PostgREST als Dienst |
| `server/nginx-tickets-api.conf` | nginx: TLS, Rate-Limit, ein Endpunkt |
| `server/sshd-dumps.conf` | SFTP-Chroot für den Lieferanten |
| `metabase-setup/03,04,06,08_*.sql` | Reporting-Sichten |
| `ticket-api/01_datenbank.sql` | API-Rollen, Funktion, Token-Register, Protokoll |
| `ticket-api/token.sh` | Tokens ausstellen, auflisten, sperren |
| `ticket-api/ANBINDUNG_HILFECENTER.md` | Schnittstellenbeschreibung Ticket-API für das Hilfecenter |
| `server/metabase_datenbank.sql` | Rollen `metabase_app`/`metabase_leser`, Anwendungsdatenbank |
| `server/metabase.{service,env.beispiel}` | Metabase als Dienst, nur auf 127.0.0.1 |
| `server/metabase_nach_umzug.py` | Anpassungen nach dem Umzug (Lesezugang, Zwischenspeicher, Konten) |
| `server/nginx-reporting.conf` | nginx: nur Einbettung, CSP auf das Hilfecenter beschränkt |
| `metabase-setup/EINBINDUNG_DASHBOARDS_HILFECENTER.md` | Anleitung fürs Hilfecenter zum Einbetten |
| `metabase-setup/einbettung_pruefen.py` | Prüft die Einbettung, erzeugt eine Testseite |

---

## Anhang A: Installation ohne Docker

Alle Befehle als root, in dieser Reihenfolge.

### A.1 Pakete

```bash
# PostgreSQL 17 aus dem offiziellen Repository
apt install -y postgresql-common
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
apt install -y postgresql-17 nginx certbot python3 bsd-mailx msmtp-mta curl jq xz-utils

# Java 25 für Metabase (Temurin)
apt install -y wget apt-transport-https gpg
wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/adoptium.gpg
echo "deb https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo $VERSION_CODENAME) main" \
  > /etc/apt/sources.list.d/adoptium.list
apt update && apt install -y temurin-25-jre
java -version

# PostgREST (fertiges Programm, keine Paketquelle)
curl -sSL https://github.com/PostgREST/postgrest/releases/download/v16.3/postgrest-v16.3-linux-static-x86-64.tar.xz \
  | tar xJ -C /usr/local/bin postgrest
postgrest --version        # PostgREST 16.3

timedatectl set-timezone Europe/Berlin
```

Mailversand (`msmtp`) auf das Mail-Relay der Firma einrichten und testen:
`echo test | mail -s test betrieb@luemobil.de`

### A.2 Benutzer und Verzeichnisse

```bash
groupadd --system luemobil-dumps
useradd --system --no-create-home --shell /usr/sbin/nologin postgrest
useradd --system --no-create-home --shell /usr/sbin/nologin metabase
useradd --create-home --shell /usr/sbin/nologin -G luemobil-dumps dumpupload
usermod -aG luemobil-dumps postgres

install -d -o root     -g root           -m 755  /srv/luemobil /srv/luemobil/dumps
install -d -o dumpupload -g luemobil-dumps -m 2770 /srv/luemobil/dumps/eingang
install -d -o postgres -g postgres       -m 700  /srv/luemobil/archiv /srv/luemobil/fehler \
                                                  /var/lib/luemobil-import /var/backups/luemobil
install -d -o root     -g root           -m 755  /etc/luemobil /opt/metabase
install -d -o metabase -g metabase       -m 750  /var/lib/metabase /var/lib/metabase/plugins
```

### A.3 Skripte installieren

```bash
git clone <repository> /opt/luemobil_reporting        # oder Ordner kopieren
chmod 755 /opt/luemobil_reporting/import/*.sh /opt/luemobil_reporting/ticket-api/*.sh /opt/luemobil_reporting/server/meldung.sh

install -o root -g postgres -m 640 /opt/luemobil_reporting/server/import.conf.beispiel /etc/luemobil/import.conf
nano /etc/luemobil/import.conf              # MELDUNG_AN, Mindestmengen prüfen

cp /opt/luemobil_reporting/server/*.service /opt/luemobil_reporting/server/*.timer /etc/systemd/system/
systemctl daemon-reload
```

### A.4 SFTP-Zugang für den Lieferanten

```bash
install -d -o dumpupload -g dumpupload -m 700 /home/dumpupload/.ssh
nano /home/dumpupload/.ssh/authorized_keys  # öffentlichen Schlüssel des Lieferanten eintragen
chmod 600 /home/dumpupload/.ssh/authorized_keys; chown dumpupload: /home/dumpupload/.ssh/authorized_keys

cp /opt/luemobil_reporting/server/sshd-dumps.conf /etc/ssh/sshd_config.d/luemobil-dumps.conf
sshd -t && systemctl reload ssh
```

**Vereinbarung mit dem Lieferanten:**

| | |
|---|---|
| Zugang | `sftp dumpupload@<server>`, landet direkt in `/eingang` |
| Dateinamen | `kk_mpswl-PROD-JJJJMMTThhmmss.sql` und `kk_swl-PROD-JJJJMMTThhmmss.sql`, wahlweise mit `.gz` |
| Format | `pg_dump` im Klartextformat aus PostgreSQL 17, vollständig, mit der Endzeile `-- PostgreSQL database dump complete` |
| Paar | Beide Dumps vom selben Kalendertag, im Abstand von höchstens 6 Stunden |
| Zeitpunkt | beliebig, der Server sieht alle 30 Minuten nach |
| Idealerweise | zuerst unter `.tmp`-Namen hochladen und danach umbenennen. Nötig ist das nicht: Der Import wartet, bis eine Datei 2 Minuten unverändert ist, und prüft die Endzeile |

### A.5 Erstimport

```bash
# Dumps einmalig von Hand ablegen (oder den Lieferanten hochladen lassen)
cp kk_mpswl-PROD-*.sql kk_swl-PROD-*.sql /srv/luemobil/dumps/eingang/
chown dumpupload:luemobil-dumps /srv/luemobil/dumps/eingang/*; chmod 660 /srv/luemobil/dumps/eingang/*

systemctl start luemobil-import
journalctl -u luemobil-import -n 30
```

Erwartet: `Rauchtest übersprungen: lue_reporting existiert noch nicht (Ersteinrichtung)` und
`Import erfolgreich (Erstimport).` Die Reporting-Datenbank entsteht erst im nächsten Schritt.

### A.6 Reporting-Datenbank

Die Skripte aus `metabase-setup/` legen die Sichten an. Auf dem Server verbindet sich
`postgres_fdw` über den Unix-Socket statt über TCP, deshalb werden Host, Port und Platzhalter angepasst:

```bash
sudo -u postgres createdb lue_reporting
cd /opt/luemobil_reporting/metabase-setup
sed -e "s/host 'localhost', port '5432', //" -e "s/PGUSER_PLACEHOLDER/postgres/" 03_reporting_views.sql \
  | sudo -u postgres psql -v ON_ERROR_STOP=1 -d lue_reporting
for f in 04_kennzahlen.sql 06_payone_und_kennzahlen.sql 08_korrekturen.sql; do
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d lue_reporting -f "$f"
done
sudo -u postgres psql -d lue_reporting -c "SELECT count(*) FROM rpt.bestellposition"   # > 0
```

> **Nicht ausführen:** `01_anonymisieren.sql`, `02_anonymisieren_mpswl.sql` (nur Demo).
> **Achtung:** Die Skripte 03–08 legen Sichten mit `DROP … CASCADE` neu an. Dabei gehen
> Rechte auf diese Sichten verloren. **Nach jedem erneuten Ausführen** deshalb Schritt 4.7.1
> (`01_datenbank.sql`) wiederholen. Für Metabase ist das nicht nötig: `metabase_leser`
> bekommt neue Sichten über Standardrechte automatisch (4.8.1, lokal geprüft).

Der Metabase-Zugang wird in 4.8.1 angelegt.

### A.7 Ticket-API

#### A.7.1 Datenbankteil

```bash
umask 077
openssl rand -base64 48 | tr -d '\n' > /etc/luemobil/jwt_secret
chown root:postgres /etc/luemobil/jwt_secret; chmod 640 /etc/luemobil/jwt_secret
DBPW=$(openssl rand -hex 24)

sudo -u postgres psql -d lue_reporting -v db_passwort="$DBPW" -f /opt/luemobil_reporting/ticket-api/01_datenbank.sql
```

**Nicht** `ticket-api/02_nur_demo.sql` ausführen.
`01_datenbank.sql` ist idempotent und darf jederzeit erneut laufen. Dabei wird allerdings jedes
Mal das Passwort von `api_zugang` neu gesetzt: `-v db_passwort=` muss dann das Passwort aus
`/etc/luemobil/postgrest.conf` sein.

#### A.7.2 PostgREST

```bash
cat > /etc/luemobil/postgrest.conf <<EOF
db-uri         = "postgres://api_zugang:${DBPW}@localhost:5432/lue_reporting"
db-schemas     = "api"
db-pre-request = "protokoll.token_pruefen"
db-max-rows    = 500
db-pool        = 5
db-channel-enabled = true
jwt-secret     = "$(cat /etc/luemobil/jwt_secret)"
jwt-aud        = "tickets-api"
server-host    = "127.0.0.1"
server-port    = 3100
openapi-mode   = "disabled"
log-level      = "warn"
EOF
chown root:postgrest /etc/luemobil/postgrest.conf; chmod 640 /etc/luemobil/postgrest.conf
unset DBPW

systemctl enable --now postgrest-tickets
journalctl -u postgrest-tickets -n 5          # "Schema cache loaded … 1 RPCs"
```

Kein `db-anon-role`, das ist Absicht: Ohne gültiges Token gibt es keine Antwort.

#### A.7.3 nginx und Zertifikat

```bash
cp /opt/luemobil_reporting/server/nginx-tickets-api.conf /etc/nginx/sites-available/tickets-api
sed -i 's/TICKETS-API.EXAMPLE.DE/tickets-api.luemobil.de/g' /etc/nginx/sites-available/tickets-api

cat > /etc/luemobil/erlaubte_ips.conf <<'EOF'
# IP-Adressen des Hilfecenters (Dev und Produktion)
allow 203.0.113.17;
deny  all;
EOF

# Zertifikat: zuerst nur den Port-80-Block aktiv, damit certbot prüfen kann
install -d /var/www/certbot
certbot certonly --webroot -w /var/www/certbot -d tickets-api.luemobil.de
ln -s /etc/nginx/sites-available/tickets-api /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

`certbot` erneuert das Zertifikat automatisch (eigener Timer). Nach der Erneuerung muss nginx
neu geladen werden: `echo 'deploy-hook = systemctl reload nginx' >> /etc/letsencrypt/cli.ini`.

#### A.7.4 Tokens ausstellen

```bash
cd /opt/luemobil_reporting/ticket-api
sudo -u postgres JWT_SECRET_DATEI=/etc/luemobil/jwt_secret ./token.sh neu hilfecenter-prod 365
```

Das Token wird **einmal** angezeigt und muss über den Passwort-Tresor an das Hilfecenter gehen.
Gespeichert wird nur seine Kennung (`jti`).
Beschreibung für das Hilfecenter-Team: `ticket-api/ANBINDUNG_HILFECENTER.md`.

### A.8 Metabase

Metabase liefert die Dashboards. Nach außen ist nur die Einbettung ins Hilfecenter
erreichbar; Dashboards bauen Administratoren über einen SSH-Tunnel.

#### A.8.1 Datenbanken und Rollen

```bash
PW_APP=$(openssl rand -hex 24); PW_LESER=$(openssl rand -hex 24)
sudo -u postgres psql -d lue_reporting \
  -v pw_app="$PW_APP" -v pw_leser="$PW_LESER" -v eigentuemer=postgres \
  -f /opt/luemobil_reporting/server/metabase_datenbank.sql
```

Das legt an: Datenbank `metabase_app` samt Besitzer und die Rolle `metabase_leser`
(nur lesend auf `rpt`, dauerhaft `read only`, 120 s Abfragegrenze). Beide Passwörter
notieren, `PW_APP` kommt gleich in die Konfiguration.

#### A.8.2 Programm und Konfiguration

Die Version muss **dieselbe** sein wie lokal, sonst schlägt der Umzug fehl (hier 0.63.18):

```bash
curl -sSL -o /opt/metabase/metabase.jar https://downloads.metabase.com/v0.63.18/metabase.jar

install -o root -g metabase -m 640 /opt/luemobil_reporting/server/metabase.env.beispiel /etc/luemobil/metabase.env
openssl rand -base64 32   # -> MB_ENCRYPTION_SECRET_KEY
openssl rand -hex 32      # -> MB_EMBEDDING_SECRET_KEY (geht an das Hilfecenter)
nano /etc/luemobil/metabase.env   # Schlüssel, MB_DB_PASS=$PW_APP, MB_SITE_URL eintragen
cp /opt/luemobil_reporting/server/metabase.service /etc/systemd/system/; systemctl daemon-reload
```

`MB_ENCRYPTION_SECRET_KEY` verschlüsselt die gespeicherten Datenbankzugänge. Geht er
verloren, kann Metabase die Verbindung zu `lue_reporting` nicht mehr lesen. In den Tresor damit.

#### A.8.3 Dashboards übernehmen

Die bestehenden Dashboards liegen in der lokalen Metabase (H2-Datei). Metabase bringt für den
Umzug den Befehl `load-from-h2` mit. **Lokal geprobt am 22.09.2026:** 5 Dashboards und 80 Fragen
wurden übertragen, die IDs 6–9 blieben erhalten.

```bash
# 1. Auf dem Mac: Metabase stoppen, Datei kopieren, wieder starten
cd ~/Documents/LüMobil_SQL/metabase-setup && ./stop.sh
scp metabase-app-db.mv.db admin@server:/tmp/ && ./start.sh

# 2. Auf dem Server: in die leere Anwendungsdatenbank laden
chown metabase: /tmp/metabase-app-db.mv.db
sudo -u metabase env $(grep -E '^MB_(DB|ENCRYPTION)' /etc/luemobil/metabase.env | xargs) \
  java --add-opens java.base/java.nio=ALL-UNNAMED \
  -jar /opt/metabase/metabase.jar load-from-h2 /tmp/metabase-app-db     # ohne .mv.db!
shred -u /tmp/metabase-app-db.mv.db

systemctl enable --now metabase
journalctl -u metabase -f      # 1–2 Minuten, bis "Metabase Initialization COMPLETE"
ss -ltnp | grep 3000           # muss 127.0.0.1:3000 zeigen, nicht *:3000
```

#### A.8.4 Nacharbeiten

Über einen SSH-Tunnel, weil Metabase nicht öffentlich erreichbar ist:

```bash
ssh -L 3030:127.0.0.1:3000 admin@server        # auf dem Arbeitsplatz, offen lassen

MB_URL=http://localhost:3030 LESER_PASSWORT=$PW_LESER \
ADMIN_EMAIL=vorname.nachname@luemobil.de ADMIN_VORNAME=Vorname ADMIN_NACHNAME=Nachname \
ADMIN_PASSWORT='<mind. 12 Zeichen>' \
  /opt/luemobil_reporting/server/metabase_nach_umzug.py
```

Das Skript stellt die Verbindung auf `metabase_leser` um, entfernt die Beispieldatenbank,
**schaltet den Zwischenspeicher ab** (sonst könnten nach dem nächtlichen Import alte Zahlen
erscheinen), legt das persönliche Admin-Konto an, deaktiviert das Demo-Konto und prüft die
Einbettungsfreigabe der Dashboards 6–9.

Danach von Hand im Tunnel (`http://localhost:3030`):

- Alte Dashboards aus der Bauphase aufräumen. In der Demo liegen noch die IDs 2–5
  („1 — Hochlauf-Cockpit“, „2 — Bestandsüberführung“, „3 — Betrieb und Störungen“,
  „4 — Produkt und Tarif“). Ins Archiv damit, damit niemand veraltete Zahlen sieht.
- Weitere Konten anlegen, wer Dashboards bauen soll.
- Stichprobe: Zeigen die Dashboards die Zahlen des letzten Imports?

#### A.8.5 nginx für die Einbettung

```bash
cp /opt/luemobil_reporting/server/nginx-reporting.conf /etc/nginx/sites-available/reporting
sed -i 's/REPORTING.EXAMPLE.DE/reporting.swl-innovation.de/g;
        s#HILFECENTER-ADRESSEN#https://luemobil.swl-innovation.de#' /etc/nginx/sites-available/reporting
certbot certonly --webroot -w /var/www/certbot -d reporting.swl-innovation.de
ln -s /etc/nginx/sites-available/reporting /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

Durchgelassen werden nur `/embed/`, `/api/embed/` und `/app/`; alles andere gibt `404`.
Zusätzlich beschränkt eine eigene `Content-Security-Policy` die einbettenden Seiten auf das
Hilfecenter — Metabase selbst erlaubt sonst jede Seite. **Lokal im Browser geprüft:**
Dashboards laden vollständig, Admin-Oberfläche und Anmeldung sind von außen gesperrt, eine
fremde Seite kann nichts einbetten.

Die Schnittstellenbeschreibung fürs Hilfecenter steht in
`metabase-setup/EINBINDUNG_DASHBOARDS_HILFECENTER.md`. Der Einbettungsschlüssel geht über den
Passwort-Tresor dorthin.

### A.9 Zeitpläne aktivieren

```bash
systemctl enable --now luemobil-import.timer luemobil-import-waechter.timer luemobil-sicherung.timer
systemctl list-timers 'luemobil-*'
```

| Timer | Wann | Was |
|---|---|---|
| `luemobil-import.timer` | alle 30 Minuten | Sieht nach neuen Dumps und importiert. Ist nichts da, endet er sofort |
| `luemobil-import-waechter.timer` | täglich 09:00 | Meldet, wenn der letzte erfolgreiche Import älter als 30 Stunden ist |
| `luemobil-sicherung.timer` | täglich 04:15 | Sichert `lue_reporting` und `metabase_app`, behält 30 Tage |

Jeder fehlgeschlagene Dienst verschickt eine Mail an `MELDUNG_AN` mit den letzten 40 Protokollzeilen.

### A.10 Abnahme

**Import** — Test mit Testdatenbanken, fasst die echten nicht an (ca. 1 Minute):

```bash
cd /opt/luemobil_reporting/import
sudo -u postgres ./test_import.sh \
  "$(ls -t /srv/luemobil/archiv/kk_mpswl-PROD-*.sql | head -1)" \
  "$(ls -t /srv/luemobil/archiv/kk_swl-PROD-*.sql | head -1)"
# Erwartet: 32 bestanden, 0 fehlgeschlagen   (Dumps unkomprimiert übergeben)
```

Er prüft: Erstimport, doppelte Lieferung, Austausch bei offener Sitzung, abgeschnittener Dump,
Dump mit SQL-Fehler, eingebrochene Datenmenge, Rückbau bei fehlgeschlagenem Rauchtest,
fehlender Partner-Dump, parallele Läufe, Wächter, leerer Eingang.

**API** — von einem freigegebenen Rechner:

```bash
curl -s -X POST https://tickets-api.luemobil.de/rpc/tickets_fuer_email \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"p_email":"katja.katze@swl-innovation.de"}' | jq length          # Anzahl Tickets
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://tickets-api.luemobil.de/rpc/tickets_fuer_email \
  -d '{"p_email":"x@y.de"}'                                             # 401
```

**Dashboards** — über den SSH-Tunnel, mit dem Einbettungsschlüssel aus `/etc/luemobil/metabase.env`:

```bash
METABASE_URL=http://localhost:3030 METABASE_EMBED_SECRET=<schlüssel> \
  /opt/luemobil_reporting/metabase-setup/einbettung_pruefen.py       # 4x "ok"
```

Danach dieselbe Prüfung von außen mit `METABASE_URL=https://reporting.swl-innovation.de`, und
stichprobenartig im Browser: `https://reporting.swl-innovation.de/` muss `404` liefern.

**Benachrichtigung** — einmal auslösen:
`systemctl start luemobil-meldung@test.service` → Mail muss ankommen.

---
