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

## Die vier Dashboards

Deckungsgleich mit dem Klickdummy, je mit erläuternden Textkacheln.

| Board | Kennzahlen | Inhalt |
|---|---|---|
| **1 — Überblick** | 11 | Umsatz, Verkäufe, Ø Bon, Käufer, Konten, Kaufquote, Tagesverlauf, Kaufzeitpunkt, Produktmix, Kanäle |
| **2 — Abo-Bestand** | 10 | Berechtigungen, Aktivierungsquote, offenes Potenzial, Trichter, Segmente, Altersprofil, PLZ-Tabelle |
| **3 — Einzeltickets über PayOne** | 11 | Leerzustand mit Feldbindung, Tarifkatalog, 93 Preisstufen, 712 Preispunkte, Gültigkeitsregeln, Preisspannen |
| **4 — Betrieb und Störungen** | 10 | Erfolgsquote, Durchlaufzeit, Bestellstrecke, Abbruchursachen, Plattform, Arbeitslisten, Tarifausnahmen |

Geprüft: 42 von 42 Kacheln liefern Daten.

## Abhängigkeiten zwischen den Views

`rpt.bestellung` → `rpt.bestellposition`, `rpt.tagesreihe`
`rpt.kunde_360` → `rpt.tagesreihe`, `rpt.trichter`, `rpt.arbeitsliste`
`rpt.produkt` → `rpt.bestellposition`
`rpt.abo_berechtigung` → `rpt.aktivierung_plz`, `rpt.aktivierung_segment`, `rpt.trichter`

Ein `DROP VIEW ... CASCADE` auf eine der linken Views reisst die rechten mit.
`08_korrekturen.sql` legt sie deshalb am Ende alle wieder an — die Datei ist
nach jeder Änderung an `kunde_360`, `bestellung` oder `produkt` erneut auszuführen.


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
