# LüMobil — Reporting, Ticket-API und Dashboards

Dieses Repository enthält alles, was der LüMobil-Reportingserver braucht: den nächtlichen
Import der Produktiv-Dumps, die Reporting-Sichten, die Ticket-API für das Hilfecenter und
die Metabase-Dashboards.

**Die Anleitung für den Server ist [`BETRIEBSHANDBUCH.md`](BETRIEBSHANDBUCH.md).**
Dort steht Schritt für Schritt, wie der Server aufgesetzt, betrieben und im Störungsfall
behandelt wird.

## Inhalt

| Ordner | Inhalt |
|---|---|
| [`import/`](import/) | Nächtlicher Import der Dumps (`import.sh`) und sein Abnahmetest |
| [`server/`](server/) | Alles für den Server: systemd-Dienste, nginx, SFTP-Zugang, Datenbankrollen |
| [`ticket-api/`](ticket-api/) | Ticketauskunft für das Hilfecenter: Datenbankteil, Tokens, Tests |
| [`metabase-setup/`](metabase-setup/) | Reporting-Sichten, Metabase-Demo, Einbettung der Dashboards |
| [`dashboard-screens/`](dashboard-screens/) | Bildschirmfotos der vier Dashboards |

## Für andere Teams

| Dokument | Für wen |
|---|---|
| [`ticket-api/ANBINDUNG_HILFECENTER.md`](ticket-api/ANBINDUNG_HILFECENTER.md) | Hilfecenter-Team: Tickets zu einer E-Mail-Adresse abfragen |
| [`metabase-setup/EINBINDUNG_DASHBOARDS_HILFECENTER.md`](metabase-setup/EINBINDUNG_DASHBOARDS_HILFECENTER.md) | Hilfecenter-Team: Dashboards einbetten |

## Auf den Produktivserver bringen

```bash
git clone <dieses-repository> /opt/luemobil
```

Danach das Betriebshandbuch ab Abschnitt 4 abarbeiten. Nicht im Repository enthalten und
deshalb auf dem Server zu besorgen:

| Fehlt | Woher |
|---|---|
| `metabase.jar`, PostgREST | werden im Handbuch heruntergeladen (4.1, 4.8.2) |
| Passwörter, Schlüssel, Zertifikate | werden auf dem Server erzeugt (4.7, 4.8) und gehören in den Tresor |
| Dumps `kk_*-PROD-*.sql` | liefert das Quellsystem per SFTP (4.4) |

**Nie einchecken:** Dumps, Schlüssel, Passwörter, die Metabase-Datei `metabase-app-db.mv.db`.
Die `.gitignore` hält das ab — bei neuen Dateien trotzdem selbst prüfen.

## Lokale Demo (Mac)

Anonymisierte Daten zum Vorführen und für die Entwicklung des Hilfecenters:

```bash
metabase-setup/start.sh     # PostgreSQL + Metabase auf http://localhost:3030
ticket-api/einrichten.sh && ticket-api/start.sh   # Ticket-API auf https://localhost:8443
```

Einzelheiten in [`metabase-setup/README.md`](metabase-setup/README.md) und
[`ticket-api/README.md`](ticket-api/README.md).

## Tests

```bash
import/test_import.sh <mpswl-dump> <swl-dump>   # 32 Prüfungen, eigene Testdatenbanken
ticket-api/test.sh                              # 28 Prüfungen gegen die laufende API
metabase-setup/einbettung_pruefen.py            # Einbettung der Dashboards
```
