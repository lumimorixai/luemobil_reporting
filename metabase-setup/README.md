# LüMobil — Metabase-Demo, lokal

Eine vollständige, lauffähige Metabase-Instanz mit den Daten aus beiden Dumps —
**anonymisiert**. Gedacht zum Vorführen im Vertrieb: „So sieht das aus, so klickt
ihr euch das selbst zusammen."

## Starten und stoppen

```bash
./start.sh          # PostgreSQL + Metabase hochfahren
./stop.sh           # Metabase beenden (PostgreSQL läuft weiter)
./stop.sh --alles   # beides beenden
./entfernen.sh      # Demo restlos vom Rechner entfernen
```

Metabase läuft auf **http://localhost:3030**
Anmeldung: `demo@luemobil.local` / `LueMobilDemo2026`

Port 3030 statt des üblichen 3000, weil dort bereits ein anderer Dienst lief.

## Was installiert wurde

| Komponente | Version | Woher |
|---|---|---|
| PostgreSQL | 16.15 | Homebrew, läuft als Dienst |
| OpenJDK | 21 | Homebrew |
| Metabase | aktuell | JAR in diesem Ordner, interne H2-Datenbank daneben |

## Datenbanken

| Name | Inhalt |
|---|---|
| `kk_mpswl` | Mobilitätsplattform, anonymisiert |
| `kk_swl` | Ticketshop, anonymisiert |
| `lue_reporting` | Reporting-Datenbank: bindet beide per `postgres_fdw` ein, enthält das Schema `rpt` |

Metabase sieht **ausschließlich `rpt`** — nicht die Rohtabellen. Genau das ist der Punkt:
Der Vertrieb kann sich frei bedienen, ohne die Fallen im Quellschema kennen zu müssen.

## Die Skripte, in dieser Reihenfolge

| Datei | Zweck |
|---|---|
| `01_anonymisieren.sql` | Ersetzt Namen, E-Mails, Telefon, Straße in beiden Datenbanken |
| `02_anonymisieren_mpswl.sql` | Zusätzlich Abo-Bestand, Abo-Codes, Geräte-IDs; prüft die Kennzahlen |
| `03_reporting_views.sql` | FDW-Einrichtung und die neun Auswertungssichten |
| `04_kennzahlen.sql` | Eindeutige Zählebenen, Trichter, Arbeitslisten |
| `05_metabase_einrichten.py` | Admin-Konto, Datenbankverbindung, Metadaten, 19 Fragen, 4 Dashboards |
| `06`–`11` | Nachträge, Korrekturen und Gestaltung (Stand September 2026) |
| `12_kundenliste.py` | Kundenliste der Abo-Berechtigten, siehe unten |
| `13_app_reports.sql` | **Livebetrieb ab Oktober 2026:** korrigierte und neue Sichten, siehe unten |
| `14_dashboards.py` | **Livebetrieb:** alle sieben Boards, korrigierte und neue Fragen |
| `reports_einspielen.sh` | 13, 12 und 14 in dieser Reihenfolge — auf dem Server `docker compose run --rm reports` |

Alle Skripte sind **idempotent** und laufen gegen die echte Produktivdatenbank genauso —
mit zwei Ausnahmen: 01 und 02 dürfen dort **niemals** ausgeführt werden, die sind nur
für die Demo.

## Anonymisierung

Deterministisch über `md5()`: Dieselbe Original-E-Mail ergibt in allen Tabellen und beiden
Datenbanken denselben Ersatzwert. Nur deshalb bleiben die Joins intakt.

**Erhalten:** PLZ, Ort, Geburtsjahr, alle Beträge, Zeitstempel, Status, Produktbezüge, Plattform
**Ersetzt:** Name, E-Mail, Telefon, Straße, Hausnummer, Tag/Monat der Geburt, Abo-Kundennummer
**Gelöscht:** Passwörter, Sitzungsschlüssel, Lichtbild, Barcode, Ticketgeheimnis

Nachweis, dass die Auswertung unberührt bleibt:

| Kennzahl | Vor Anonymisierung | Danach |
|---|---|---|
| App-Konten | 2.132 | 2.132 |
| Berechtigungen | 8.267 | 8.267 |
| **Aktiviert (E-Mail-Join!)** | **1.698** | **1.698** |
| Bestellungen | 1.551 | 1.551 |
| Aktive Abos | 1.459 | 1.459 |
| Verschiedene Geräte | 1.443 | 1.443 |

## Die sechs gekapselten Fallen

Das ist der eigentliche Wert der Views. Ohne sie käme Selbstbedienung zu falschen Zahlen:

1. **`customers_id` bedeutet in beiden Datenbanken nicht dasselbe.** Von 2.124 gemeinsamen
   E-Mails haben 27 dieselbe ID. Verknüpft wird über `custom1 ->> 'externalOrderReference'`.
2. **`ot_total` ist brutto, `final_price` netto.** 87.433 € gegen 81.713 € für dieselben Verkäufe.
3. **Status 3 heißt erfolgreich** — aber 1.459 Bestellungen erreichten ihn, Endstand 1.442.
4. **Bestandsabgleich nur über `lower(btrim(email))`.**
5. **Geburtsdatum aus der Berechtigung**, nicht aus dem Konto (dort 82 % Platzhalter `1800-01-01`).
6. **Kundentags überleben gelöschte Kunden** — 2.996 Warenkorb-Tags bei 2.132 Konten.

Dazu zwei weitere, die erst beim Bauen auffielen:

**Siebte Falle:** **Zeilen sind nicht Personen.** 8.267
Berechtigungen gehören 8.215 Personen. Deshalb trägt `rpt.abo_berechtigung` die Spalte
`ist_hauptzeile` — Personenzählungen filtern darauf. Ohne diese Festlegung liefert dieselbe
Frage je nach Klickpfad 6.517 oder 6.559.

**Achte Falle — Bestellungen ohne Konto.** In `orders` stehen 1.453 Kundennummern,
aber nur 1.445 davon haben ein Konto in `customers`. Zehn Bestellungen von acht
Kundennummern hängen in der Luft, sieben davon erfolgreich ausgeliefert. Die
Kennzahl „Käufer" zählt deshalb kontoseitig (1.445); die Differenz steht als
eigener Eintrag in den Arbeitslisten statt sie stillschweigend zu verrechnen.

**Neunte Falle — der Produktbezug liegt nur im Shop.** In `kk_mpswl` steht als
SKU pauschal `OEPNV`; die echte Tarif-SKU (541, 548) gibt es nur in `kk_swl`.
Wer den Produktmix aus der Plattform-Datenbank zieht, bekommt eine einzige
Sammelposition. `rpt.bestellposition` holt die Positionen deshalb über
`externalOrderReference` aus dem Shop.

## Die sieben Dashboards

Seit Oktober 2026 (`14_dashboards.py`). Jedes Board zeigt oben rechts den **Datenstand**
(letzte Bestellung im Dump). Die Texte enthalten keine festen Zahlen mehr. Alle Boards sind
für die Einbettung freigegeben, keines zeigt E-Mail-Adressen oder Namen.

| Board | Inhalt |
|---|---|
| **1 — Überblick** | Umsatz, Verkäufe, Ø Bon, Käufer, Konten, Bestellungen und Umsatz je Tag, **Tickets je Tag nach Kanal**, Kaufzeitpunkt, Produktmix, Kanäle |
| **2 — Abo-Bestand** | Berechtigungen, Aktivierungsquote, offenes Potenzial, aktive Abos, Trichter, Segmente, Altersprofil, Arbeitslisten, PLZ-Tabelle |
| **3 — Einzeltickets und PayOne** | PayOne-Bestellungen, Erfolgsquote (gesamt und 7 Tage), Umsatz ÖPNV und Fähre, Verlauf je Tag, Ausgang (abgelehnt, abgebrochen, Aufräumjob, erstattet), Produkte, **Relationen**, Tageszeit, Plattform, Erstattungen; darunter der Tarifkatalog |
| **4 — Betrieb und Störungen** | Erfolgsquote, Abbrüche, Durchlaufzeit, Bestellstrecke, Abbrüche nach Ausgang, Plattform, Arbeitslisten (jetzt 12 Listen), Tarifausnahmen |
| **5 — Monatsbilanz Abo** (neu) | Berechtigte → App-Konto → aktives Abo → **gültiges Ticket im Monat**, je Segment, verlängert/neu je Monat, Kundenbindung, nach Alter und PLZ, täglicher Verlauf |
| **6 — Abo-Verlängerung** (neu) | Nächster Abrechnungstag, fällige Abos, Folgemonat schon ausgestellt, Lauf je Ausstellungstag, Kundenbindung, gestörte Abos |
| **7 — App-Nutzung** (neu) | Konten, neue Konten (7/30 Tage), Käufer in 30 Tagen, Einwilligungen je Kontaktweg, Bestellungen je Konto, Wochentag, Plattform, Registrierungsmonat |

Geprüft mit den Daten vom 21.10.2026: alle Kacheln liefern Daten, keine braucht mehr als
2,2 Sekunden (alle zusammen 35 Sekunden).

**Logins** wertet kein Board aus: `customers_info_date_last_logon` ist in der Quelle bei
7.506 von 7.529 Konten leer.

## Livebetrieb ab Oktober 2026: `13_app_reports.sql`

Ändert vorhandene Sichten nur mit `CREATE OR REPLACE` und hängt neue Spalten hinten an.
Die Rechte der Ticket-API und von Metabase bleiben erhalten, 4.6 im Betriebshandbuch muss
**nicht** erneut laufen.

**Korrigiert:**

| Sicht | Fehler | Folge vorher |
|---|---|---|
| `rpt.bestellposition` | Verknüpfung über die SKU; seit 7.10. gibt es jede Einzel- und Fähr-SKU zwei- bis dreimal | 8.785 statt 8.629 Positionen; Einzeltickets doppelt gezählt, auch in der **Ticket-API** des Hilfecenters |
| `rpt.produkt` | kannte nur die Kategorien 1–3, nicht die neuen Unterkategorien | Fähre als Einzelticket, 54 Tickets „unbekannt“ |
| `rpt.bestellung`, `rpt.kunde_360`, `rpt.produkt` | Unterabfragen je Zeile über `postgres_fdw` | 6 s je Spalte, einzelne Kacheln brachen ab |
| Kundenliste (`12_kundenliste.py`) | „versendet im Monat“ nach Kaufdatum | Oktober: rund 1.959 statt 4.914 Personen mit Ticket |

**Neu:** `rpt.abo_ticket` (wer hat für welchen Monat ein Abo-Ticket), `rpt.berechtigte_person`,
`rpt.monatsbilanz`, `rpt.monatsstand` (Tabelle, tägliche Momentaufnahme),
`rpt.abo_verlauf`, `rpt.abo_verlaengerung`, `rpt.bestellergebnis`, `rpt.erstattung`,
`rpt.app_nutzung`, `rpt.datenstand`; `rpt.bestellposition` mit Gültigkeit, Gültigkeitsmonat,
Start- und Zielzone; `rpt.tagesreihe` mit Tickets je Kanal, PayOne und Erstattungen.

**Zehnte Falle — eine SKU ist kein Produkt.** Verknüpft wird über `products_id`.

**Elfte Falle — gekauft ist nicht gültig.** Das Abo-Ticket für Oktober wird am 27. September
ausgestellt. Wer wissen will, wer im Oktober ein Ticket hat, fragt die Gültigkeit
(`orders_products.custom1 → timeValidity`), nicht das Kaufdatum.

**Zwölfte Falle — Fremdtabellen ohne Statistik.** Ohne `ANALYZE` kennt der Planer die
Zeilenzahlen der Quelltabellen nicht und plant je nach Abfrage Schleifen über
`postgres_fdw`: Dieselbe Sicht brauchte Minuten statt einer halben Sekunde. Das Skript und
der nächtliche Import frischen die Statistik deshalb jedes Mal auf.

**Monatsverlauf:** Der Abo-Bestand wird jeden Monat vollständig ersetzt. Damit der Verlauf
erhalten bleibt, schreibt der Import nach jedem Lauf eine Zeile je Segment nach
`rpt.monatsstand` (nur Zahlen). Der Verlauf beginnt mit der Einrichtung.

## Abhängigkeiten zwischen den Views

`rpt.bestellung` → `rpt.bestellposition`, `rpt.tagesreihe`, `rpt.bestellergebnis`
`rpt.bestellposition` → `rpt.abo_ticket` → `rpt.berechtigte_person` → `rpt.monatsbilanz` → `rpt.monatsstand`
`rpt.kunde_360` → `rpt.tagesreihe`, `rpt.trichter`, `rpt.arbeitsliste`
`rpt.produkt` → `rpt.bestellposition`
`rpt.abo_berechtigung` → `rpt.aktivierung_plz`, `rpt.aktivierung_segment`, `rpt.trichter`

Ein `DROP VIEW ... CASCADE` auf eine der linken Views reisst die rechten mit.
Seit `13_app_reports.sql` gilt deshalb: Sichten nur noch mit `CREATE OR REPLACE` ändern.
Wer doch einmal 03–08 erneut einspielt, muss danach `13_app_reports.sql` und 4.6 im
Betriebshandbuch wiederholen.


## Kundenliste nach Ticket

`12_kundenliste.py` legt die Frage „Kundenliste nach Ticket (9995 / 9999)“ an: alle
Abo-Berechtigten mit Ticket 9995 und/oder 9999, eine Zeile je Person (E-Mail, Name,
Kundennummer, Ticket, PLZ, Ort, Gültigkeit, App-Konto). Dazu je Person, ob im gewählten
Monat ein Ticket versendet wurde, wie viele und wann zuletzt.

| Filter | Vorbelegung |
|---|---|
| Ticket | 9995 und 9999 |
| Ticket gültig im Monat | aktueller Monat |
| Ticket versendet | leer = alle; `ja` oder `nein` |

**Versendet** heißt: ein ausgestelltes Abo-Ticket (Status 3 „Versendet“), das **im
gewählten Monat gilt**. Das Kaufdatum zählt nicht: Das Ticket für Oktober wird am
27. September ausgestellt (bis Oktober 2026 zählte die Liste nach Kaufdatum und zeigte
deshalb für Oktober nur etwa 1.959 statt 4.914 Personen mit Ticket). Dazu die Spalten
„Aktives Abo“ und „Abo gestört“. Berechtigung und Bestellung werden über die
normalisierte E-Mail verbunden, denn `order_number` ist im Bestand leer. Wer in der App
mit einer anderen Adresse bestellt, erscheint deshalb als „nicht versendet“.

Die Tabelle zeigt höchstens 2.000 Zeilen. Der CSV-Download unten rechts enthält alle.

**Auf dem Server** läuft das Skript als Dienst im Docker-Netz, ganz ohne Tunnel. Die
Zugangsdaten kommen aus der `.env` (`MB_ADMIN_EMAIL`, `MB_ADMIN_PASSWORT`):

```bash
cd /opt/luemobil_reporting && git pull
docker compose run --rm kundenliste                  # Frage anlegen, Zahlen prüfen
```

**Liste als CSV ohne Browser:** `--csv` schreibt sie auf die Standardausgabe.

```bash
docker compose run --rm -T kundenliste --csv --versendet ja > /root/kundenliste.csv
scp <benutzer>@reporting.swl-innovation.de:/root/kundenliste.csv ~/Downloads/   # auf dem Mac
rm /root/kundenliste.csv                                                         # auf dem Server
```

`-T` ist Pflicht. Ohne diese Option vermischt Docker die Meldungen mit der Liste.

| Option | Bedeutung |
|---|---|
| `--versendet ja` / `nein` | nur mit oder ohne versendetes Ticket (weggelassen: alle) |
| `--monat 2026-10` | Monat, in dem das Ticket gilt (weggelassen: aktueller Monat) |
| `--ticket 9995` | nur dieses Ticket, mehrfach möglich (weggelassen: beide) |

Die Optionen gelten auch für den Probelauf ohne `--csv`. In der Demo liegen die Daten
im September: `python3 metabase-setup/12_kundenliste.py --monat 2026-09`.

**Ansehen in der Oberfläche** geht weiterhin nur über den Tunnel
(`ssh -N -L 3001:127.0.0.1:3001 <benutzer>@reporting.swl-innovation.de`, dann
`http://localhost:3001`). Das Skript lässt sich auch von dort aus starten:
`MB_URL=http://localhost:3001 MB_EMAIL=… MB_PASSWORT=… python3 metabase-setup/12_kundenliste.py`.

Die Liste enthält Personendaten. Sie gehört auf kein Dashboard, das ins Hilfecenter
eingebettet wird.

## Gestaltung

`09_gestaltung.py`, `10_feinschliff.py` und `11_layout.py` setzen Zahlenformate,
Diagrammfarben und das Raster. Die Palette entspricht dem Prototyp:
Teal `#0F6F7E` (Abo), Blau `#2E5F92` (Einzelticket), Grün `#4A7A63` (Fähre),
Amber `#8A5C0D` (Konten), Rot `#A63A33` (Störungen).

**Was gesetzt ist:** Euro- und Prozentformate mit deutschen Trennzeichen,
Datum als `3.9.2026`, Serienfarben je Diagramm, zweite Achse für die
Kontenlinie, Mini-Balken in den Tabellen, bedingte Einfärbung der
Aktivierungsquote, Boards auf volle Breite, 24-Spalten-Raster.

**Was nicht geht:** Diese Metabase ist die Open-Source-Ausgabe
(`whitelabel: false`). Markenfarbe, Logo und Schriftart der Oberfläche
selbst lassen sich nicht ändern — das ist der kostenpflichtigen Ausgabe
vorbehalten. Die Seitenleiste, die Kopfzeile und die Grundtypografie
bleiben im Metabase-Look.

**Zwei Fallstricke beim Gestalten:**

1. Metabase rechnet mit einem **24-Spalten-Raster**. Eine Zeile mit
   Kachelbreiten, die zusammen mehr als 24 ergeben, bricht um und
   verschiebt alles darunter. `11_layout.py` prüft das beim Setzen.
2. Die Einstellung „Zahlen abkürzen" (`scalar.compact_primary_number`)
   wird bei schmalen Kacheln **ignoriert** — Metabase kürzt dann trotzdem
   (`€82k` statt `€81.926`). Abhilfe ist allein mehr Breite.

## Für den Produktivbetrieb

Es ändert sich wenig:

- `01` und `02` entfallen — dort wird nicht anonymisiert.
- In `03` die Verbindungsdaten der beiden echten Datenbanken eintragen.
- Metabase nicht als JAR mit H2, sondern als Dienst mit PostgreSQL als Anwendungsdatenbank.
- Einen eigenen Datenbankbenutzer `metabase` mit `SELECT` nur auf `rpt` anlegen
  (die Befehle stehen am Ende von `03_reporting_views.sql`).
- Personenbezogene Spalten in Metabase je nach Rolle ausblenden.

`04` und `05` laufen unverändert.
