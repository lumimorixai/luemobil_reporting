# LüMobil Ticket-API für das Hilfecenter

Gibt zu einer E-Mail-Adresse alle bestellten Tickets zurück. Abgesichert über HTTPS
und ein Token je Anwendung. Die Anwendung kann nur lesen.

```
Hilfecenter ──HTTPS + Bearer-Token──▶ nginx :8443 ──▶ PostgREST 127.0.0.1:3100 ──▶ lue_reporting
                                      TLS, IP-Filter,   prüft Token-Signatur,        Rolle hilfecenter:
                                      Rate-Limit,       Ablauf, Zielgruppe           darf genau eine
                                      nur 1 Endpunkt                                 Funktion ausführen
```

## Aufruf

```bash
curl -X POST https://tickets-api.local:8443/rpc/tickets_fuer_email \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -H "X-Bearbeiter: m.mustermann" \
  -d '{"p_email": "katja.katze@swl-innovation.de"}'
```

```json
[{"gekauft_am":"2026-09-03T13:50:04.59","bestellnummer":"1788436204117",
  "produkt":"Deutschlandticket 2.Kl","sku":"541","menge":1,
  "preis_brutto":63.00,"status":"Versendet","erfolgreich":true}, …]
```

| Antwort | Bedeutung |
|---|---|
| `200` + Liste | Treffer, neueste zuerst. Leere Liste `[]` = keine Bestellungen |
| `400` | Keine gültige E-Mail-Adresse |
| `401` | Token fehlt, ist falsch, abgelaufen oder gesperrt |
| `403` | Andere Methode als POST, oder IP-Adresse nicht freigegeben |
| `404` | Anderer Pfad als `/rpc/tickets_fuer_email` |
| `429` | Zu viele Anfragen (30/min je Token, 60/min je IP) |

`X-Bearbeiter` ist freiwillig. Wenn die Anwendung den Namen der Person im Hilfecenter
mitschickt, steht er im Protokoll. Das ist sinnvoll, weil das Token sonst nur die Anwendung benennt.

Warum POST und nicht GET: Bei GET stünde die E-Mail in der URL und damit in jedem
Zugriffsprotokoll auf dem Weg. Der Proxy weist GET deshalb ab.

## Bedienung

```bash
./einrichten.sh                      # einmalig; idempotent
psql -d lue_reporting -f 02_nur_demo.sql   # NUR DEMO, siehe unten
./start.sh / ./stop.sh
./token.sh neu <anwendung> [tage]    # Token ausstellen, wird nur einmal angezeigt
./token.sh liste                     # alle Tokens mit Zustand und Anzahl Abfragen
./token.sh sperren <jti>             # wirkt sofort
./test.sh                            # 28 Prüfungen, dauert ca. 1 Minute
```

Das Protokoll auswerten:

```sql
SELECT zeitpunkt, anwendung, bearbeiter, ip, email_gesucht, treffer
FROM protokoll.abfrage ORDER BY zeitpunkt DESC;
```

## Was abgesichert ist und wie

| Anforderung | Umsetzung | Geprüft in test.sh |
|---|---|---|
| Verschlüsselt | nginx, nur TLS 1.2/1.3; Port 8080 weist ab; PostgREST lauscht nur auf 127.0.0.1 | Transport |
| Token | JWT (HS256) mit `role`, `aud`, `jti`, `exp`; PostgREST prüft Signatur, Ablauf, Zielgruppe | Authentifizierung |
| Token sperrbar | Register `protokoll.token`; Prüfung vor jeder Anfrage (`db-pre-request`) | Sperren |
| Nur lesen | Rolle `hilfecenter` hat **keine** Tabellenrechte, nur `EXECUTE` auf eine Funktion. Die Funktion gehört `api_eigentuemer`, der nur zwei Sichten lesen darf | Nur lesen |
| Nur ein Endpunkt | PostgREST veröffentlicht nur Schema `api`, nginx lässt nur einen Pfad und nur POST durch | Nur lesen |
| Kein Durchprobieren | Rate-Limit je Token und je IP, Body max. 1 KB, Abfragezeit max. 5 s, max. 500 Zeilen | Rate-Limit |
| Nachvollziehbar | Jede Abfrage landet in `protokoll.abfrage` (wer, wann, welche Adresse, Trefferzahl) | Protokoll |
| Keine Daten in Logs | nginx protokolliert weder Body noch Query-String noch Token | Protokoll |

Die einzige Schreibstelle ist das Abfrageprotokoll. Die Funktion schreibt es selbst,
der Aufrufer hat darauf keinen Einfluss und kann es auch nicht lesen.

## Nur in der Demo

Die Demo-Datenbank ist anonymisiert. `02_nur_demo.sql` sorgt dafür, dass die API
trotzdem mit echten Adressen sucht: Sie rechnet die Eingabe mit derselben md5-Formel in den
Ersatzwert um. **In Produktion nicht ausführen**, dort wird direkt gesucht.

Außerdem demo-spezifisch: selbst ausgestellte Zertifikate (`geheim/ca.crt`), das
Demo-Token in `geheim/demo_token` für `test.sh` und der Zugriff nur von localhost.

## Für die Produktion

Die vollständige Serveranleitung mit Import, systemd-Diensten und Störungsbehebung steht in
[`BETRIEBSHANDBUCH.md`](../BETRIEBSHANDBUCH.md). Kurzfassung:

1. **Datenbank:** `01_datenbank.sql` in der produktiven `lue_reporting` ausführen, `02` nicht.
2. **Server:** PostgREST und nginx auf einen Server im selben Netz wie die Datenbank.
   PostgREST als systemd-Dienst, Konfiguration wie `geheim/postgrest.conf`.
3. **Zertifikat:** echtes Zertifikat für den echten Hostnamen (Let's Encrypt/certbot),
   in `nginx.conf.vorlage` die beiden `ssl_certificate`-Zeilen anpassen.
4. **IP-Filter:** in `erlaubte_ips.conf` die Adresse(n) des Hilfecenters eintragen,
   localhost entfernen.
5. **Geheimnisse:** `jwt_secret` und `db_passwort` neu erzeugen (nie die aus der Demo),
   in einen Tresor legen. Wer den JWT-Schlüssel hat, kann Tokens ausstellen.
   Wird der Schlüssel ausgetauscht, werden alle Tokens sofort ungültig.
6. **Datenbankverbindung:** in `db-uri` `sslmode=require` anhängen, wenn die Datenbank
   auf einem anderen Rechner liegt.
7. **Token ausstellen:** `./token.sh neu zendesk 365`. Das Token über den Passwort-Tresor
   übergeben, nicht per E-Mail. Vor Ablauf ein neues ausstellen und das alte sperren.
8. **Aufbewahrung:** `SELECT protokoll.aufraeumen(12);` monatlich per Cron (12 Monate
   ist ein Vorschlag, mit dem Datenschutz abstimmen). Das Verzeichnis von
   Verarbeitungstätigkeiten um „Auskunft im Hilfecenter“ ergänzen.

## Dateien

| Datei | Zweck |
|---|---|
| `01_datenbank.sql` | Rollen, Schemata `api`/`api_intern`/`protokoll`, Funktion, Token-Register, Protokoll |
| `02_nur_demo.sql` | Suche über anonymisierte Adressen, nur Demo |
| `einrichten.sh` | Geheimnisse, Zertifikate, DB, Konfiguration |
| `nginx.conf.vorlage` | Proxy: TLS, Rate-Limit, ein Endpunkt, Logformat |
| `erlaubte_ips.conf` | IP-Freigabe |
| `token.sh` | Tokens ausstellen, auflisten, sperren |
| `start.sh`, `stop.sh` | Dienste starten und beenden |
| `test.sh` | Prüft alles oben Genannte von außen |
| `bin/postgrest` | PostgREST 16.3 (macOS x86-64, von GitHub-Releases) |
| `geheim/` | Schlüssel, Passwort, Zertifikate, PostgREST-Konfiguration (chmod 700) |
| `laufzeit/` | PIDs, Logs, erzeugte nginx.conf |
