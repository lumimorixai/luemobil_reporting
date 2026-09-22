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
 Lieferant (Produktion)                          Virtueller Server
 ─────────────────────                           ───────────────────────────────────────────────────────
                         SFTP, nur Schlüssel     /srv/luemobil/dumps/eingang
 kk_mpswl-PROD-….sql  ─────────────────────────▶      │
 kk_swl-PROD-….sql                                    │  luemobil-import.timer (alle 30 min)
                                                      ▼
                                                 import.sh ── prüfen ── einspielen ── austauschen
                                                      │
                                    ┌─────────────────┼──────────────────┐
                                    ▼                 ▼                  ▼
                                kk_mpswl           kk_swl          lue_reporting
                                (Plattform)        (Shop)          ├─ rpt.*        Sichten über postgres_fdw
                                    ▲                 ▲            ├─ api.*        Ticket-API-Funktion
                                    └──── postgres_fdw┘            └─ protokoll.*  Tokens, Abfrageprotokoll
                                                                          │
                                            ┌─────────────────────────────┴───────────┐
                                            ▼                                         ▼
 Hilfecenter ──Bearer-Token──▶ nginx :443 ──▶ PostgREST 127.0.0.1:3100   Metabase 127.0.0.1:3000
   (Ticketauskunft)            tickets-api                                 metabase_app (eigene DB)
                                                                                      ▲
 Hilfecenter ──signiertes Token im iframe──▶ nginx :443 ─────────────────────────────┘
   (Dashboards)                              reporting: nur /embed, /api/embed, /app

 Admins ──SSH-Tunnel──▶ 127.0.0.1:3000 (Metabase-Oberfläche, nicht öffentlich)
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
- Auf diesem Server liegen **echte, nicht anonymisierte Personendaten**. Die Skripte
  `metabase-setup/01_anonymisieren.sql`, `02_anonymisieren_mpswl.sql` und
  `ticket-api/02_nur_demo.sql` sind nur für die Demo und werden hier **nie** ausgeführt.

---

## 2. Anforderungen an den Server

| | Empfehlung | Begründung |
|---|---|---|
| Betriebssystem | Debian 12 oder Ubuntu 24.04 LTS | systemd, aktuelle OpenSSL |
| PostgreSQL | **Version 17** (aus apt.postgresql.org) | Die Dumps stammen aus PG 17.11 und enthalten PG17-Objekte. Mit PG16 schlägt der Import fehl (getestet). |
| CPU / RAM | 2 vCPU / 8 GB | Import dauert ca. 6 Sekunden; Metabase belegt 2 GB Heap |
| Java | **Temurin 25 (JRE)** | Von Metabase 0.63 verlangt |
| Festplatte | 40 GB | Während des Imports liegen die Daten 3-fach vor (aktuell, `_neu`, `_alt`), dazu 7 Tage Dump-Archiv. Heute ca. 15 MB je Nacht |
| Eingehend | 22 (nur SFTP-Lieferant + Administration), 443 (nur Hilfecenter), 80 (nur Zertifikatserneuerung) | Firewall auf Absender beschränken |
| Ausgehend | 25/587 (Mail für Fehlermeldungen), 443 (Updates, Let's Encrypt) | |
| Zeitzone | Europe/Berlin | Zeitpläne und Protokolle in Ortszeit |

---

## 3. Verzeichnisse, Benutzer, Rechte

| Pfad | Eigentümer | Rechte | Inhalt |
|---|---|---|---|
| `/opt/luemobil/` | root:root | 755 | Kopie dieses Repositorys (Skripte) |
| `/etc/luemobil/import.conf` | root:postgres | 640 | Import-Konfiguration |
| `/etc/luemobil/postgrest.conf` | root:postgrest | 640 | PostgREST-Konfiguration **mit DB-Passwort und JWT-Schlüssel** |
| `/etc/luemobil/jwt_secret` | root:postgres | 640 | JWT-Schlüssel, zum Ausstellen von Tokens |
| `/etc/luemobil/erlaubte_ips.conf` | root:root | 644 | IP-Freigaben für die API |
| `/etc/luemobil/metabase.env` | root:metabase | 640 | Metabase-Konfiguration **mit DB-Passwort, Verschlüsselungs- und Einbettungsschlüssel** |
| `/opt/metabase/metabase.jar` | root:root | 644 | Metabase-Programm |
| `/var/lib/metabase/` | metabase:metabase | 750 | Arbeitsverzeichnis, Plugins |
| `/srv/luemobil/dumps/` | root:root | 755 | SFTP-Chroot des Lieferanten (muss root gehören) |
| `/srv/luemobil/dumps/eingang/` | dumpupload:luemobil-dumps | 2770 | Hier kommen die Dumps an |
| `/srv/luemobil/archiv/` | postgres:postgres | 700 | Importierte Dumps, 7 Tage |
| `/srv/luemobil/fehler/` | postgres:postgres | 700 | Abgewiesene Dumps, 7 Tage |
| `/var/lib/luemobil-import/` | postgres:postgres | 700 | Sperre, Import-Register, `letzter_import.json` |
| `/var/backups/luemobil/` | postgres:postgres | 700 | Sicherungen von `lue_reporting`, 30 Tage |

| Systembenutzer | Zweck |
|---|---|
| `dumpupload` | Nur SFTP, nur Schlüssel, eingesperrt in `/srv/luemobil/dumps`. Keine Shell. |
| `postgres` | Führt Import und Sicherung aus (Datenbank-Superuser über Unix-Socket) |
| `postgrest` | Führt PostgREST aus, kein Login |
| `metabase` | Führt Metabase aus, kein Login |

| Datenbankrolle | Zweck |
|---|---|
| `postgres` | Eigentümer aller Datenbanken und Sichten, Import |
| `api_zugang` | Anmeldung von PostgREST (Passwort), darf selbst nichts |
| `hilfecenter` | Rolle aus dem API-Token: darf nur `api.tickets_fuer_email` ausführen |
| `api_eigentuemer` | Besitzt die API-Funktion: liest 2 Sichten, schreibt nur ins Abfrageprotokoll |
| `metabase_app` | Besitzt die Metabase-Anwendungsdatenbank `metabase_app`, sonst nichts |
| `metabase_leser` | Metabase liest damit die Sichten: `SELECT` auf `rpt`, dauerhaft nur lesend |

---

## 4. Installation

Alle Befehle als root, in dieser Reihenfolge.

### 4.1 Pakete

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

### 4.2 Benutzer und Verzeichnisse

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

### 4.3 Skripte installieren

```bash
git clone <repository> /opt/luemobil        # oder Ordner kopieren
chmod 755 /opt/luemobil/import/*.sh /opt/luemobil/ticket-api/*.sh /opt/luemobil/server/meldung.sh

install -o root -g postgres -m 640 /opt/luemobil/server/import.conf.beispiel /etc/luemobil/import.conf
nano /etc/luemobil/import.conf              # MELDUNG_AN, Mindestmengen prüfen

cp /opt/luemobil/server/*.service /opt/luemobil/server/*.timer /etc/systemd/system/
systemctl daemon-reload
```

### 4.4 SFTP-Zugang für den Lieferanten

```bash
install -d -o dumpupload -g dumpupload -m 700 /home/dumpupload/.ssh
nano /home/dumpupload/.ssh/authorized_keys  # öffentlichen Schlüssel des Lieferanten eintragen
chmod 600 /home/dumpupload/.ssh/authorized_keys; chown dumpupload: /home/dumpupload/.ssh/authorized_keys

cp /opt/luemobil/server/sshd-dumps.conf /etc/ssh/sshd_config.d/luemobil-dumps.conf
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

### 4.5 Erstimport

```bash
# Dumps einmalig von Hand ablegen (oder den Lieferanten hochladen lassen)
cp kk_mpswl-PROD-*.sql kk_swl-PROD-*.sql /srv/luemobil/dumps/eingang/
chown dumpupload:luemobil-dumps /srv/luemobil/dumps/eingang/*; chmod 660 /srv/luemobil/dumps/eingang/*

systemctl start luemobil-import
journalctl -u luemobil-import -n 30
```

Erwartet: `Rauchtest übersprungen: lue_reporting existiert noch nicht (Ersteinrichtung)` und
`Import erfolgreich (Erstimport).` Die Reporting-Datenbank entsteht erst im nächsten Schritt.

### 4.6 Reporting-Datenbank

Die Skripte aus `metabase-setup/` legen die Sichten an. Auf dem Server verbindet sich
`postgres_fdw` über den Unix-Socket statt über TCP, deshalb werden Host, Port und Platzhalter angepasst:

```bash
sudo -u postgres createdb lue_reporting
cd /opt/luemobil/metabase-setup
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

### 4.7 Ticket-API

#### 4.7.1 Datenbankteil

```bash
umask 077
openssl rand -base64 48 | tr -d '\n' > /etc/luemobil/jwt_secret
chown root:postgres /etc/luemobil/jwt_secret; chmod 640 /etc/luemobil/jwt_secret
DBPW=$(openssl rand -hex 24)

sudo -u postgres psql -d lue_reporting -v db_passwort="$DBPW" -f /opt/luemobil/ticket-api/01_datenbank.sql
```

**Nicht** `ticket-api/02_nur_demo.sql` ausführen.
`01_datenbank.sql` ist idempotent und darf jederzeit erneut laufen. Dabei wird allerdings jedes
Mal das Passwort von `api_zugang` neu gesetzt: `-v db_passwort=` muss dann das Passwort aus
`/etc/luemobil/postgrest.conf` sein.

#### 4.7.2 PostgREST

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

#### 4.7.3 nginx und Zertifikat

```bash
cp /opt/luemobil/server/nginx-tickets-api.conf /etc/nginx/sites-available/tickets-api
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

#### 4.7.4 Tokens ausstellen

```bash
cd /opt/luemobil/ticket-api
sudo -u postgres JWT_SECRET_DATEI=/etc/luemobil/jwt_secret ./token.sh neu hilfecenter-prod 365
```

Das Token wird **einmal** angezeigt und muss über den Passwort-Tresor an das Hilfecenter gehen.
Gespeichert wird nur seine Kennung (`jti`).
Beschreibung für das Hilfecenter-Team: `ticket-api/ANBINDUNG_HILFECENTER.md`.

### 4.8 Metabase

Metabase liefert die Dashboards. Nach außen ist nur die Einbettung ins Hilfecenter
erreichbar; Dashboards bauen Administratoren über einen SSH-Tunnel.

#### 4.8.1 Datenbanken und Rollen

```bash
PW_APP=$(openssl rand -hex 24); PW_LESER=$(openssl rand -hex 24)
sudo -u postgres psql -d lue_reporting \
  -v pw_app="$PW_APP" -v pw_leser="$PW_LESER" -v eigentuemer=postgres \
  -f /opt/luemobil/server/metabase_datenbank.sql
```

Das legt an: Datenbank `metabase_app` samt Besitzer und die Rolle `metabase_leser`
(nur lesend auf `rpt`, dauerhaft `read only`, 120 s Abfragegrenze). Beide Passwörter
notieren, `PW_APP` kommt gleich in die Konfiguration.

#### 4.8.2 Programm und Konfiguration

Die Version muss **dieselbe** sein wie lokal, sonst schlägt der Umzug fehl (hier 0.63.18):

```bash
curl -sSL -o /opt/metabase/metabase.jar https://downloads.metabase.com/v0.63.18/metabase.jar

install -o root -g metabase -m 640 /opt/luemobil/server/metabase.env.beispiel /etc/luemobil/metabase.env
openssl rand -base64 32   # -> MB_ENCRYPTION_SECRET_KEY
openssl rand -hex 32      # -> MB_EMBEDDING_SECRET_KEY (geht an das Hilfecenter)
nano /etc/luemobil/metabase.env   # Schlüssel, MB_DB_PASS=$PW_APP, MB_SITE_URL eintragen
cp /opt/luemobil/server/metabase.service /etc/systemd/system/; systemctl daemon-reload
```

`MB_ENCRYPTION_SECRET_KEY` verschlüsselt die gespeicherten Datenbankzugänge. Geht er
verloren, kann Metabase die Verbindung zu `lue_reporting` nicht mehr lesen. In den Tresor damit.

#### 4.8.3 Dashboards übernehmen

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

#### 4.8.4 Nacharbeiten

Über einen SSH-Tunnel, weil Metabase nicht öffentlich erreichbar ist:

```bash
ssh -L 3030:127.0.0.1:3000 admin@server        # auf dem Arbeitsplatz, offen lassen

MB_URL=http://localhost:3030 LESER_PASSWORT=$PW_LESER \
ADMIN_EMAIL=vorname.nachname@luemobil.de ADMIN_VORNAME=Vorname ADMIN_NACHNAME=Nachname \
ADMIN_PASSWORT='<mind. 12 Zeichen>' \
  /opt/luemobil/server/metabase_nach_umzug.py
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

#### 4.8.5 nginx für die Einbettung

```bash
cp /opt/luemobil/server/nginx-reporting.conf /etc/nginx/sites-available/reporting
sed -i 's/REPORTING.EXAMPLE.DE/reporting.luemobil.de/g;
        s#HILFECENTER-ADRESSEN#https://hilfe.luemobil.de#' /etc/nginx/sites-available/reporting
certbot certonly --webroot -w /var/www/certbot -d reporting.luemobil.de
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

### 4.9 Zeitpläne aktivieren

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

### 4.10 Abnahme

**Import** — Test mit Testdatenbanken, fasst die echten nicht an (ca. 1 Minute):

```bash
cd /opt/luemobil/import
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
  /opt/luemobil/metabase-setup/einbettung_pruefen.py       # 4x "ok"
```

Danach dieselbe Prüfung von außen mit `METABASE_URL=https://reporting.luemobil.de`, und
stichprobenartig im Browser: `https://reporting.luemobil.de/` muss `404` liefern.

**Benachrichtigung** — einmal auslösen:
`systemctl start luemobil-meldung@test.service` → Mail muss ankommen.

---

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
/opt/luemobil/import/import.sh --status                # letzter erfolgreicher Import (JSON)
journalctl -u luemobil-import --since today            # Protokoll des Imports
systemctl list-timers 'luemobil-*'                      # nächste Läufe
ls -l /srv/luemobil/dumps/eingang /srv/luemobil/fehler  # liegt etwas herum?
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

```bash
cd /opt/luemobil/ticket-api
sudo -u postgres ./token.sh liste                       # Tokens, Zustand, Anzahl Abfragen
sudo -u postgres ./token.sh sperren <jti>               # wirkt sofort
sudo -u postgres psql -d lue_reporting -c \
  "SELECT zeitpunkt, anwendung, bearbeiter, ip, treffer FROM protokoll.abfrage ORDER BY id DESC LIMIT 20"
tail -f /var/log/nginx/tickets-api.log                  # Zugriffe (ohne E-Mail-Adressen)
```

### 5.4 Metabase

```bash
ssh -L 3030:127.0.0.1:3000 admin@server     # Oberfläche: http://localhost:3030
systemctl status metabase
journalctl -u metabase --since today
tail -f /var/log/nginx/reporting.log         # eingebettete Zugriffe, ohne Token
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
| Metabase startet nicht, Log: „Unable to connect to Metabase application database" | `metabase_app`-Zugang falsch | `/etc/luemobil/metabase.env` prüfen, `systemctl restart metabase` |
| Metabase-Dashboards leer, Kacheln melden Fehler | Verbindung zu `lue_reporting` gestört oder Rechte nach Sichten-Neuanlage verloren | Im Tunnel *Admin → Datenbanken → LüMobil Reporting → Verbindung testen*; 4.8.1 erneut ausführen |
| Dashboards zeigen alte Zahlen | Zwischenspeicher wieder eingeschaltet | Im Tunnel *Admin → Performance → Standardregel* auf „Kein Zwischenspeicher"; siehe 4.8.4 |
| Eingebettetes Dashboard im Hilfecenter leer | Token, Freigabe, IP oder CSP — siehe Fehlerbilder in `metabase-setup/EINBINDUNG_DASHBOARDS_HILFECENTER.md` | Dort Abschnitt 6 |
| `https://reporting…/` liefert die Metabase-Anmeldung statt `404` | nginx-Konfiguration nicht aktiv | 4.8.5 prüfen, `nginx -t && systemctl reload nginx` |
| Platte voll | Archiv oder `_alt` gewachsen | `du -sh /srv/luemobil/* /var/lib/postgresql`. `_alt`-Datenbanken dürfen gelöscht werden |

### 6.1 Dumps erneut importieren

```bash
mv /srv/luemobil/fehler/kk_*-PROD-JJJJMMTT*.sql /srv/luemobil/dumps/eingang/
systemctl start luemobil-import && journalctl -u luemobil-import -n 30 -f
```

Ein schon erfolgreich importiertes Paar erkennt das Skript und überspringt es. Um es trotzdem neu
einzuspielen, die beiden Zeilen aus `/var/lib/luemobil-import/importiert.txt` löschen.

### 6.2 Von Hand auf den Stand von gestern zurück

Nur nötig, wenn ein Import „erfolgreich“ war, die Daten aber inhaltlich falsch sind.

```bash
systemctl stop luemobil-import.timer
sudo -u postgres psql -d postgres <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('kk_mpswl','kk_swl','kk_mpswl_alt','kk_swl_alt');
ALTER DATABASE kk_mpswl RENAME TO kk_mpswl_defekt;  ALTER DATABASE kk_mpswl_alt RENAME TO kk_mpswl;
ALTER DATABASE kk_swl   RENAME TO kk_swl_defekt;    ALTER DATABASE kk_swl_alt   RENAME TO kk_swl;
SQL
sudo -u postgres psql -d lue_reporting -c "SELECT count(*) FROM rpt.bestellposition"
# Ursache klären, dann: DROP DATABASE kk_mpswl_defekt; DROP DATABASE kk_swl_defekt;
systemctl start luemobil-import.timer
```

### 6.3 Token kompromittiert

```bash
sudo -u postgres /opt/luemobil/ticket-api/token.sh sperren <jti>     # sofort wirksam
```

Ist der **JWT-Schlüssel** selbst betroffen (`/etc/luemobil/jwt_secret` oder `postgrest.conf`
gelangte nach außen): neuen Schlüssel erzeugen, in beide Dateien eintragen,
`systemctl restart postgrest-tickets`. Damit sind **alle** Tokens ungültig. Neue ausstellen.

### 6.4 Metabase-Einbettung: Schlüssel wechseln

Neuen Schlüssel erzeugen (`openssl rand -hex 32`), in `/etc/luemobil/metabase.env` unter
`MB_EMBEDDING_SECRET_KEY` eintragen, `systemctl restart metabase`. Alle bisherigen Tokens sind
sofort ungültig; das Hilfecenter braucht den neuen Schlüssel, sonst bleiben die Dashboards leer.

### 6.5 `lue_reporting` wiederherstellen

```bash
sudo -u postgres dropdb lue_reporting
sudo -u postgres createdb lue_reporting
sudo -u postgres pg_restore -d lue_reporting /var/backups/luemobil/lue_reporting-JJJJMMTT.dump
systemctl restart postgrest-tickets
```

### 6.6 Metabase wiederherstellen

```bash
systemctl stop metabase
sudo -u postgres dropdb metabase_app && sudo -u postgres createdb -O metabase_app metabase_app
sudo -u postgres pg_restore -d metabase_app /var/backups/luemobil/metabase_app-JJJJMMTT.dump
systemctl start metabase
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
| nginx-Log `reporting` | IP-Adresse, kein Token, keine E-Mail | Log-Rotation (14 Tage) | root |
| nginx-Log | IP-Adresse, keine E-Mail | Log-Rotation der Distribution (14 Tage) | root |

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
| Sicherheitsupdates | `apt update && apt upgrade`, PostgreSQL-Nebenversionen kommen darüber mit |
| PostgREST aktualisieren | Neue Version wie in 4.1 nach `/usr/local/bin`, `systemctl restart postgrest-tickets`, API-Test aus 4.9 |
| PostgreSQL-Hauptversion | Erst wechseln, wenn der Lieferant wechselt. Dumps einer neueren Hauptversion lassen sich nicht einspielen |
| Token erneuern | Vor Ablauf neues ausstellen, übergeben, altes sperren (`token.sh liste` zeigt `gueltig_bis`) |
| Neue IP fürs Hilfecenter | `/etc/luemobil/erlaubte_ips.conf`, `nginx -t && systemctl reload nginx` |
| Metabase aktualisieren | Sicherung von `metabase_app` prüfen, `systemctl stop metabase`, neue `metabase.jar` nach `/opt/metabase`, `systemctl start metabase` (die Datenbank wandelt sich selbst um), danach Abnahme aus 4.10 |
| Neues Dashboard fürs Hilfecenter | Im Tunnel veröffentlichen (5.4), ID ans Hilfecenter geben |
| Sichten geändert | 4.6, danach unbedingt 4.7.1 |

---

## 9. Dateien im Repository

| Datei | Zweck |
|---|---|
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
