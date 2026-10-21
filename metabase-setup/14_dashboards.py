#!/usr/bin/env python3
"""Dashboards für den Livebetrieb (ab Oktober 2026).

Setzt alle sieben Boards vollständig neu zusammen, korrigiert die Fragen,
die noch auf dem Stand vor PayOne waren, und legt die neuen Fragen an:

  1 — Überblick                 bestehend, Texte ohne feste Zahlen, Tickets je Kanal
  2 — Abo-Bestand               bestehend, "Aktive Abos" zählt nur aktive
  3 — Einzeltickets und PayOne  bisher "… über PayOne": jetzt mit Livedaten
  4 — Betrieb und Störungen     bestehend, Abbruchgründe aus rpt.bestellergebnis
  5 — Monatsbilanz Abo          neu: wer hat im Monat ein gültiges Ticket
  6 — Abo-Verlängerung          neu: der Lauf am 27., Kundenbindung
  7 — App-Nutzung               neu: Konten, Einwilligungen, Kaufverhalten

Setzt 13_app_reports.sql voraus. Wiederholbar: vorhandene Fragen und Boards
werden über den Namen gefunden und auf diesen Stand gebracht, die IDs der
Boards bleiben gleich (wichtig für die Einbettung im Hilfecenter).
Keine Frage auf diesen Boards zeigt E-Mail-Adressen oder Namen.

  Demo:    python3 metabase-setup/14_dashboards.py
  Server:  docker compose run --rm reports       (siehe compose.yml)
"""
import json, os, sys, urllib.error, urllib.request

BASE = os.environ.get("MB_URL", "http://localhost:3030").rstrip("/")
ANMELDUNG = {"username": os.environ.get("MB_EMAIL", "demo@luemobil.local"),
             "password": os.environ.get("MB_PASSWORT", "LueMobilDemo2026")}
tok = None

def call(p, d=None, m=None):
    r = urllib.request.Request(BASE + p, data=json.dumps(d).encode() if d is not None else None,
                               method=m or ("POST" if d is not None else "GET"))
    r.add_header("Content-Type", "application/json")
    if tok: r.add_header("X-Metabase-Session", tok)
    try:
        with urllib.request.urlopen(r, timeout=300) as x:
            raw = x.read().decode(); return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{p} -> {e.code}: {e.read().decode()[:300]}")

tok = call("/api/session", ANMELDUNG)["id"]
dbs = call("/api/database"); dbs = dbs["data"] if isinstance(dbs, dict) else dbs
db_id = next(d["id"] for d in dbs if d["name"] == "LüMobil Reporting")
COLL = next(c["id"] for c in call("/api/collection") if c.get("name") == "LüMobil Vertrieb")
vorhanden = {c["name"]: c["id"] for c in call(f"/api/collection/{COLL}/items?models=card")["data"]}

# --- Gestaltung (Palette wie 09_gestaltung.py) ---------------------------
TEAL, BLAU, GRUEN, AMBER, ROT, GRAU = "#0F6F7E", "#2E5F92", "#4A7A63", "#8A5C0D", "#A63A33", "#8C8C8C"
schl = lambda n: json.dumps(["name", n], separators=(",", ":"))
EUR = {"number_style": "currency", "currency": "EUR", "currency_style": "symbol",
       "decimals": 2, "number_separators": ",."}
EUR0 = {**EUR, "decimals": 0}
PROZ = {"suffix": " %", "decimals": 1, "number_separators": ",."}
ZAHL = {"number_separators": ",."}
DAT = {"date_style": "D/M/YYYY", "date_separator": ".", "date_abbreviate": False}

def spalten(**fmt):  # spalten(Umsatz=EUR, Tag=DAT) -> column_settings
    return {"column_settings": {schl(k.replace("_", " ")): v for k, v in fmt.items()}}

def zahl(spalte, fmt=ZAHL):  # Kennzahl-Kachel: nicht abkürzen, deutsches Format
    return {"scalar.compact_primary_number": False, "column_settings": {schl(spalte): fmt}}

def balken(x, reihen, farben, gestapelt=False, **mehr):
    v = {"graph.dimensions": [x], "graph.metrics": reihen,
         "series_settings": {r: {"color": f} for r, f in zip(reihen, farben)},
         "graph.x_axis.title_text": "", "graph.y_axis.title_text": ""}
    if gestapelt: v["stackable.stack_type"] = "stacked"
    v.update(mehr); return v

# --- Fragen ---------------------------------------------------------------
K = {}
def frage(name, sql, anzeige="table", beschreibung=None, viz=None):
    """Legt eine SQL-Frage an oder bringt die vorhandene auf diesen Stand.
    viz=None lässt die Gestaltung einer vorhandenen Frage unverändert."""
    abfrage = {"type": "native", "database": db_id, "native": {"query": sql}}
    if name in vorhanden:
        body = {"dataset_query": abfrage, "display": anzeige, "description": beschreibung}
        if viz is not None: body["visualization_settings"] = viz
        call(f"/api/card/{vorhanden[name]}", body, m="PUT")
    else:
        vorhanden[name] = call("/api/card", {"name": name, "description": beschreibung,
            "collection_id": COLL, "display": anzeige, "dataset_query": abfrage,
            "visualization_settings": viz or {}})["id"]
    K[name] = vorhanden[name]

print("Fragen anlegen und korrigieren ...")

frage("Datenstand",
    """SELECT to_char(letzte_bestellung, 'DD.MM.YYYY, HH24:MI') || ' Uhr' AS "Daten bis"
       FROM rpt.datenstand""", "scalar",
    "Zeitpunkt der letzten Bestellung im eingespielten Dump. Der Import läuft jede Nacht.")

# ---- Korrekturen an bestehenden Fragen (SQL oder Beschreibung) ----------
frage("Aktive Abos", """SELECT count(*) AS "Abos" FROM rpt.abo WHERE aktiv""", "scalar",
    "Laufende Abonnements. Verlängert wird gesammelt am Abrechnungstag, siehe Board 6.")
frage("Käufer", """SELECT count(*) AS "Käufer" FROM rpt.kunde_360 WHERE hat_gekauft""", "scalar",
    "Konten mit mindestens einer Bestellung. Bestellungen ohne Konto stehen in den Arbeitslisten.")
frage("Berechtigungen gesamt", """SELECT count(*) AS "Berechtigungen" FROM rpt.abo_berechtigung""",
    "scalar", "Zeilen im Bestand des laufenden Monats. Eine Person kann mehrere haben.")
frage("Umsatz je Vertriebskanal",
    """SELECT coalesce(vertriebskanal,'unbekannt') AS "Kanal", count(*) AS "Verkäufe",
              sum(einzelpreis_brutto) AS "Umsatz brutto"
       FROM rpt.bestellposition WHERE erfolgreich GROUP BY 1 ORDER BY 3 DESC""", "row",
    "Abo, Einzelticket (ÖPNV) und Fähre. Einzelticket und Fähre laufen seit 7.10.2026 über PayOne.")
frage("Bestellstrecke",
    """SELECT status AS "Status", bestellungen AS "Bestellungen" FROM rpt.bestellstrecke ORDER BY stufe""",
    "bar", "Wie viele Bestellungen jeden Schritt erreicht haben. Zurückgenommene zählen beim Schritt mit.")
frage("Schultickets zum Erwachsenenpreis",
    """SELECT bestellung_id AS "Bestellung", kauftag AS "Kauftag", produkt AS "Produkt",
              einzelpreis_brutto AS "Preis brutto", status AS "Status"
       FROM rpt.bestellposition WHERE produkt LIKE '%Schule%' AND einzelpreis_netto > 50
       ORDER BY kauftag""", "table",
    "Schulticket, aber zum Erwachsenenpreis abgerechnet. Tarifprüfung.")
frage("Abbrüche nach Ursache",
    """SELECT ergebnis AS "Ausgang", count(*) AS "Fälle" FROM rpt.bestellergebnis
       WHERE ergebnis <> 'erfolgreich' GROUP BY 1 ORDER BY 2 DESC""", "row",
    "Alle Bestellungen, die kein Ticket ergeben haben, nach Grund.",
    {"graph.dimensions": ["Ausgang"], "graph.metrics": ["Fälle"],
     "series_settings": {"Fälle": {"color": ROT}}})
frage("Umsatz Einzeltickets",
    """SELECT coalesce(sum(einzelpreis_brutto), 0) AS "Umsatz" FROM rpt.bestellposition
       WHERE erfolgreich AND vertriebskanal = 'Einzelticket'""", "scalar",
    "Einzel- und Zeitkarten ÖPNV über PayOne, brutto. Ohne Fähre.", zahl("Umsatz", EUR))
frage("Transaktionen PayOne",
    """SELECT count(*) AS "Bestellungen" FROM rpt.bestellung WHERE zahlungsmodul = 'payone'""",
    "scalar", "Alle Bestellungen über PayOne, gleich wie sie ausgingen.", zahl("Bestellungen"))
frage("Zahlungsabbrüche",
    """SELECT count(*) AS "Abgelehnt" FROM rpt.bestellergebnis WHERE ergebnis = 'Zahlung abgelehnt'""",
    "scalar", "Bestellungen, bei denen PayOne die Zahlung abgelehnt hat. Kein Ticket ausgestellt.",
    zahl("Abgelehnt"))
frage("Erstattungen", """SELECT count(*) AS "Erstattungen" FROM rpt.erstattung""", "scalar",
    "Erstattungen über PayOne, auch offene und fehlgeschlagene.", zahl("Erstattungen"))
frage("PayOne-Bereitschaft",
    """SELECT gegenstand AS "Gegenstand", quellfeld AS "Quellfeld", datensaetze AS "Datensätze",
              stand AS "Stand" FROM rpt.payone_bereitschaft ORDER BY reihenfolge""", "table",
    "Welche Felder PayOne befüllt. Grundlage der Auswertungen auf Board 3.")
frage("Tarifkatalog nach Kanal",
    """SELECT vertriebskanal AS "Kanal", count(*) AS "Produkte", sum(anzahl_preisstufen) AS "Preispunkte"
       FROM rpt.produkt GROUP BY 1 ORDER BY 2 DESC""", "table",
    "Produkte im Katalog je Kanal, alter und neuer Katalog zusammen.")
frage("Tarifkatalog je Kanal",
    """SELECT vertriebskanal AS "Kanal", coalesce(unterkategorie, '–') AS "Bereich",
              count(*) AS "Produkte", count(*) FILTER (WHERE payone_faehig) AS "für PayOne frei",
              count(*) FILTER (WHERE aktiv) AS "aktiv", sum(anzahl_preisstufen) AS "Preispunkte"
       FROM rpt.produkt GROUP BY 1, 2 ORDER BY 1, 2""", "table",
    "Seit 7.10.2026 mit Unterkategorien. Produkte ohne Bereich gehören zum alten Katalog.")
frage("Preisstufen", """SELECT count(*) AS "Preisstufen" FROM rpt.tarifstruktur""", "scalar",
    "Im Katalog gepflegte Preisstufen.")
frage("Preisspannen je Produkt",
    """SELECT produkt AS "Produkt", vertriebskanal AS "Kanal", anzahl_preisstufen AS "Preisstufen",
              preis_ab_brutto AS "ab", preis_bis_brutto AS "bis"
       FROM rpt.produkt WHERE payone_faehig AND aktiv AND anzahl_preisstufen > 1
       ORDER BY anzahl_preisstufen DESC""", "table",
    "Aktive, für PayOne freigegebene Produkte mit mehreren Preisstufen.")
frage("Bestellungen und Konten je Tag",
    """SELECT tag AS "Tag", bestellungen AS "Bestellungen", neue_konten AS "Neue Konten"
       FROM rpt.tagesreihe ORDER BY tag""", "combo",
    "Bestellungen aller Kanäle und neu angelegte App-Konten. Die Spitzen am 27. sind der Abo-Lauf.")

# ---- Board 1 -----------------------------------------------------------
frage("Tickets je Tag nach Kanal",
    """SELECT tag AS "Tag", abo_tickets AS "Abo", einzeltickets_oepnv AS "Einzelticket",
              faehrtickets AS "Fähre" FROM rpt.tagesreihe ORDER BY tag""", "bar",
    "Ausgestellte Tickets je Kauftag. Abo-Tickets kommen gesammelt am 27. für den Folgemonat.",
    {**balken("Tag", ["Abo", "Einzelticket", "Fähre"], [TEAL, BLAU, GRUEN], True), **spalten(Tag=DAT)})

# ---- Board 3: Einzeltickets und PayOne ---------------------------------
frage("PayOne erfolgreich",
    """SELECT count(*) AS "Erfolgreich" FROM rpt.bestellergebnis
       WHERE zahlungsmodul = 'payone' AND ergebnis = 'erfolgreich'""", "scalar",
    "PayOne-Bestellungen mit ausgestelltem Ticket.", zahl("Erfolgreich"))
frage("Erfolgsquote PayOne",
    """SELECT round(100.0 * count(*) FILTER (WHERE ergebnis = 'erfolgreich') / nullif(count(*), 0), 1)
              AS "Quote" FROM rpt.bestellergebnis WHERE zahlungsmodul = 'payone'""", "scalar",
    "Anteil der PayOne-Bestellungen mit ausgestelltem Ticket, seit Start.", zahl("Quote", PROZ))
frage("Erfolgsquote PayOne, 7 Tage",
    """SELECT round(100.0 * count(*) FILTER (WHERE ergebnis = 'erfolgreich') / nullif(count(*), 0), 1)
              AS "Quote" FROM rpt.bestellergebnis
       WHERE zahlungsmodul = 'payone'
         AND kauftag > (SELECT max(kauftag) FROM rpt.bestellung) - 7""", "scalar",
    "Wie Erfolgsquote PayOne, aber nur die letzten sieben Tage im Datenstand.", zahl("Quote", PROZ))
frage("Umsatz Fähre",
    """SELECT coalesce(sum(einzelpreis_brutto), 0) AS "Umsatz" FROM rpt.bestellposition
       WHERE erfolgreich AND vertriebskanal = 'Fähre'""", "scalar",
    "Fährtickets (Personen, Fahrrad, Fahrzeuge) über PayOne, brutto.", zahl("Umsatz", EUR))
frage("Erstattet",
    """SELECT coalesce(sum(betrag) FILTER (WHERE ergebnis = 'erfolgreich'), 0) AS "Erstattet"
       FROM rpt.erstattung""", "scalar", "Erfolgreich erstatteter Betrag.", zahl("Erstattet", EUR))
frage("PayOne je Tag",
    """SELECT tag AS "Tag", payone_versuche AS "Bestellungen", payone_erfolgreich AS "Erfolgreich"
       FROM rpt.tagesreihe
       WHERE tag >= (SELECT min(kauftag) FROM rpt.bestellung WHERE zahlungsmodul = 'payone')
       ORDER BY tag""", "combo",
    "Alle PayOne-Bestellungen je Tag und wie viele davon ein Ticket ergaben.",
    {"graph.dimensions": ["Tag"], "graph.metrics": ["Bestellungen", "Erfolgreich"],
     "series_settings": {"Bestellungen": {"color": GRAU, "display": "bar"},
                         "Erfolgreich": {"color": BLAU, "display": "line", "line.marker_enabled": True}},
     "graph.x_axis.title_text": "", "graph.y_axis.title_text": "", **spalten(Tag=DAT)})
frage("Ausgang der PayOne-Bestellungen",
    """SELECT ergebnis AS "Ausgang", count(*) AS "Bestellungen" FROM rpt.bestellergebnis
       WHERE zahlungsmodul = 'payone' GROUP BY 1 ORDER BY 2 DESC""", "row",
    "„Aufräumjob“: Bestellung blieb offen und wurde automatisch geschlossen, meist Abbruch im Zahlungsschritt.",
    {"graph.dimensions": ["Ausgang"], "graph.metrics": ["Bestellungen"],
     "series_settings": {"Bestellungen": {"color": BLAU}}})
frage("Einzeltickets nach Produkt",
    """SELECT vertriebskanal AS "Kanal", coalesce(unterkategorie, '–') AS "Bereich", produkt AS "Produkt",
              count(*) AS "Stück", sum(einzelpreis_brutto) AS "Umsatz brutto"
       FROM rpt.bestellposition WHERE erfolgreich AND vertriebskanal <> 'Abo'
       GROUP BY 1, 2, 3 ORDER BY 4 DESC""", "table",
    "Verkaufte Einzel-, Zeit- und Fährtickets.", spalten(Umsatz_brutto=EUR))
frage("Häufigste Relationen",
    """SELECT von_zone AS "Von", nach_zone AS "Nach", count(*) AS "Tickets"
       FROM rpt.bestellposition WHERE erfolgreich AND vertriebskanal <> 'Abo' AND von_zone IS NOT NULL
       GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20""", "table",
    "Start- und Zielzone der Einzeltickets. Tickets ohne Zone (z. B. Fähre) fehlen hier.")
frage("PayOne nach Tageszeit",
    """SELECT kaufstunde AS "Stunde", count(*) FILTER (WHERE ergebnis = 'erfolgreich') AS "Erfolgreich",
              count(*) FILTER (WHERE ergebnis <> 'erfolgreich') AS "Ohne Ticket"
       FROM rpt.bestellergebnis WHERE zahlungsmodul = 'payone' GROUP BY 1 ORDER BY 1""", "bar",
    "Wann Einzeltickets gekauft werden, und wann es scheitert.",
    balken("Stunde", ["Erfolgreich", "Ohne Ticket"], [BLAU, ROT], True))
frage("PayOne nach Plattform",
    """SELECT plattform AS "Plattform", count(*) AS "Bestellungen",
              count(*) FILTER (WHERE ergebnis = 'erfolgreich') AS "Erfolgreich",
              round(100.0 * count(*) FILTER (WHERE ergebnis = 'erfolgreich') / count(*), 1) AS "Quote"
       FROM rpt.bestellergebnis WHERE zahlungsmodul = 'payone' GROUP BY 1 ORDER BY 2 DESC""", "table",
    "Erfolgsquote je App-Plattform.", spalten(Quote=PROZ))
frage("Erstattungen im Einzelnen",
    """SELECT tag AS "Tag", bestellnummer AS "Bestellung", betrag AS "Betrag", ergebnis AS "Ergebnis",
              anlass AS "Anlass", bestellstatus AS "Bestellstatus"
       FROM rpt.erstattung ORDER BY angelegt_am DESC""", "table",
    "Jede Erstattung. „TAF Aufräumjob“: automatisch erstattet, weil die Bestellung nicht abgeschlossen wurde.",
    spalten(Betrag=EUR, Tag=DAT))

# ---- Board 5: Monatsbilanz Abo -----------------------------------------
GESAMT = "FROM rpt.monatsbilanz WHERE segment = 'Gesamt'"
frage("Berechtigte im Monat", f"""SELECT berechtigte AS "Personen" {GESAMT}""", "scalar",
    "Personen im Abo-Bestand des laufenden Monats.", zahl("Personen"))
frage("Berechtigte mit App-Konto", f"""SELECT mit_app_konto AS "Personen" {GESAMT}""", "scalar",
    "Berechtigte, zu deren E-Mail es ein App-Konto gibt.", zahl("Personen"))
frage("Berechtigte mit aktivem Abo", f"""SELECT mit_aktivem_abo AS "Personen" {GESAMT}""", "scalar",
    "Berechtigte mit laufendem Abo in der App.", zahl("Personen"))
frage("Ticket im Monat", f"""SELECT mit_ticket_im_monat AS "Personen" {GESAMT}""", "scalar",
    "Berechtigte mit ausgestelltem Abo-Ticket, das im laufenden Monat gilt.", zahl("Personen"))
frage("Ticketquote im Monat", f"""SELECT ticketquote_prozent AS "Quote" {GESAMT}""", "scalar",
    "Anteil der Berechtigten mit gültigem Ticket im laufenden Monat.", zahl("Quote", PROZ))
frage("Konto, aber kein Ticket", f"""SELECT konto_ohne_ticket AS "Personen" {GESAMT}""", "scalar",
    "App-Konto vorhanden, aber kein gültiges Ticket im Monat. Wer das ist: Kundenliste.",
    zahl("Personen"))
frage("Hochlaufkette im Monat",
    """SELECT v.schritt AS "Schritt", v.n AS "Personen"
       FROM rpt.monatsbilanz b,
            LATERAL (VALUES (1, 'Berechtigt', b.berechtigte), (2, 'App-Konto', b.mit_app_konto),
                            (3, 'Aktives Abo', b.mit_aktivem_abo), (4, 'Ticket im Monat', b.mit_ticket_im_monat))
                    AS v(i, schritt, n)
       WHERE b.segment = 'Gesamt' ORDER BY v.i""", "funnel",
    "Vom Bestand zum gültigen Ticket, Personen im laufenden Monat.")
frage("Monatsbilanz je Segment",
    """SELECT segment AS "Segment", berechtigte AS "Berechtigte", mit_app_konto AS "App-Konto",
              mit_aktivem_abo AS "Aktives Abo", mit_ticket_im_monat AS "Ticket im Monat",
              konto_ohne_ticket AS "Konto ohne Ticket", ohne_app_konto AS "Ohne App-Konto",
              ticketquote_prozent AS "Quote"
       FROM rpt.monatsbilanz ORDER BY segment = 'Gesamt', segment""", "table",
    "Segmente 9995 und 9999. „9995, 9999“: Personen mit Berechtigungen in beiden.",
    spalten(Quote=PROZ))
frage("Abo-Tickets je Monat",
    """SELECT rpt.monatsname(monat) AS "Monat", verlaengert AS "Verlängert", neu AS "Neu"
       FROM rpt.abo_verlauf ORDER BY monat""", "bar",
    "Personen mit gültigem Abo-Ticket je Monat: aus dem Vormonat verlängert oder neu dazugekommen.",
    balken("Monat", ["Verlängert", "Neu"], [TEAL, AMBER], True))
frage("Kundenbindung je Monat",
    """SELECT rpt.monatsname(monat) AS "Monat", personen_mit_ticket AS "Mit Ticket",
              verlaengert AS "Verlängert", neu AS "Neu", nicht_verlaengert AS "Nicht verlängert",
              round(100.0 * verlaengert / nullif(verlaengert + nicht_verlaengert, 0), 1) AS "Bindung"
       FROM rpt.abo_verlauf ORDER BY monat""", "table",
    "Bindung: Anteil der Vormonatskunden, die auch in diesem Monat ein Ticket haben.",
    spalten(Bindung=PROZ))
frage("Ticketquote nach Altersgruppe",
    """SELECT altersgruppe AS "Altersgruppe", count(*) FILTER (WHERE ticket_im_monat) AS "Mit Ticket",
              count(*) FILTER (WHERE NOT ticket_im_monat) AS "Ohne Ticket"
       FROM rpt.berechtigte_person WHERE altersgruppe IS NOT NULL GROUP BY 1 ORDER BY 1""", "bar",
    "Berechtigte im laufenden Monat nach Alter, mit und ohne gültiges Ticket.",
    balken("Altersgruppe", ["Mit Ticket", "Ohne Ticket"], [TEAL, GRAU], True))
frage("Ticketquote nach Postleitzahl",
    """SELECT plz AS "PLZ", min(ort) AS "Ort", count(*) AS "Berechtigte",
              count(*) FILTER (WHERE ticket_im_monat) AS "Mit Ticket",
              round(100.0 * count(*) FILTER (WHERE ticket_im_monat) / count(*), 1) AS "Quote"
       FROM rpt.berechtigte_person WHERE plz IS NOT NULL
       GROUP BY plz HAVING count(*) >= 20 ORDER BY 3 DESC""", "table",
    "Gebiete ab 20 Berechtigten. Grundlage für Gebietskampagnen.", spalten(Quote=PROZ))
frage("Verlauf der Monatsbilanz",
    """SELECT stichtag AS "Stichtag", berechtigte AS "Berechtigte", mit_app_konto AS "App-Konto",
              mit_ticket_im_monat AS "Ticket im Monat"
       FROM rpt.monatsstand WHERE segment = 'Gesamt' ORDER BY stichtag""", "line",
    "Eine Momentaufnahme je Import. Der Verlauf beginnt mit der Einrichtung dieses Boards.",
    {**balken("Stichtag", ["Berechtigte", "App-Konto", "Ticket im Monat"], [GRAU, AMBER, TEAL]),
     **spalten(Stichtag=DAT)})

# ---- Board 6: Abo-Verlängerung -----------------------------------------
NAECHSTER = """(SELECT min(naechste_abrechnung) FROM rpt.abo
                WHERE aktiv AND naechste_abrechnung >= (SELECT max(kauftag) FROM rpt.bestellung))"""
frage("Nächster Abrechnungstag",
    f"""SELECT to_char({NAECHSTER}, 'DD.MM.YYYY') AS "Nächste Verlängerung" """, "scalar",
    "An diesem Tag stellt das System für alle fälligen Abos das Ticket des Folgemonats aus.")
frage("Abos zur Verlängerung",
    f"""SELECT count(*) AS "Abos" FROM rpt.abo WHERE aktiv AND naechste_abrechnung = {NAECHSTER}""",
    "scalar", "Aktive Abos, die am nächsten Abrechnungstag fällig sind.", zahl("Abos"))
frage("Folgemonat schon ausgestellt",
    """SELECT count(*) AS "Personen" FROM rpt.abo_ticket
       WHERE gueltigkeitsmonat = (date_trunc('month', (SELECT max(kauftag) FROM rpt.bestellung))
                                  + interval '1 month')::date""", "scalar",
    "Personen mit Abo-Ticket für den kommenden Monat. Steigt am Abrechnungstag sprunghaft.",
    zahl("Personen"))
frage("Verlängerung nach Abrechnungstag",
    """SELECT naechste_abrechnung AS "Abrechnungstag", produkt AS "Produkt", aktive_abos AS "Aktiv",
              gestoert AS "Gestört", ticket_schon_da AS "Folgemonat ausgestellt"
       FROM rpt.abo_verlaengerung ORDER BY 1 DESC, 2""", "table",
    "Abos nach nächstem Abrechnungstag. Gestörte Abos werden nicht verlängert.",
    spalten(Abrechnungstag=DAT))
frage("Abo-Tickets je Ausstellungstag",
    """SELECT tag AS "Tag", abo_tickets AS "Abo-Tickets" FROM rpt.tagesreihe ORDER BY tag""", "bar",
    "Wann Abo-Tickets ausgestellt werden: der große Lauf am 27., danach Nachzügler und Neukunden.",
    {**balken("Tag", ["Abo-Tickets"], [TEAL]), **spalten(Tag=DAT)})
frage("Gestörte Abos nach Produkt",
    """SELECT produkt AS "Produkt", count(*) FILTER (WHERE aktiv) AS "Aktiv",
              count(*) FILTER (WHERE stoerung) AS "Gestört",
              count(*) FILTER (WHERE stoerung AND coalesce(btrim(stoerungstext), '') = '') AS "ohne Störungstext"
       FROM rpt.abo GROUP BY 1 ORDER BY 1""", "table",
    "Gestörte Abos sind inaktiv. Die Quelle liefert meist keinen Störungstext.")

# ---- Board 7: App-Nutzung ----------------------------------------------
NUTZ = "FROM rpt.app_nutzung"
frage("Konten gesamt", f"""SELECT konten AS "Konten" {NUTZ}""", "scalar",
    "Alle App-Konten.", zahl("Konten"))
frage("Neue Konten, 7 Tage", f"""SELECT neu_7_tage AS "Konten" {NUTZ}""", "scalar",
    "In den letzten sieben Tagen angelegt.", zahl("Konten"))
frage("Neue Konten, 30 Tage", f"""SELECT neu_30_tage AS "Konten" {NUTZ}""", "scalar",
    "In den letzten 30 Tagen angelegt.", zahl("Konten"))
frage("Gekauft in 30 Tagen", f"""SELECT kauf_30_tage AS "Konten" {NUTZ}""", "scalar",
    "Konten mit mindestens einer Bestellung in den letzten 30 Tagen.", zahl("Konten"))
frage("Kontakt erlaubt",
    f"""SELECT round(100.0 * marketing_einwilligung / nullif(konten, 0), 1) AS "Quote" {NUTZ}""",
    "scalar", "Anteil der Konten, die mindestens einem Kontaktweg zugestimmt haben.",
    zahl("Quote", PROZ))
frage("Kontolöschung beantragt", f"""SELECT loeschung_beantragt AS "Konten" {NUTZ}""", "scalar",
    "Konten mit Löschantrag. Datenschutz: nachhalten.", zahl("Konten"))
frage("Neue Konten je Tag",
    """SELECT tag AS "Tag", neue_konten AS "Neue Konten" FROM rpt.tagesreihe ORDER BY tag""", "bar",
    "Angelegte App-Konten je Tag.", {**balken("Tag", ["Neue Konten"], [AMBER]), **spalten(Tag=DAT)})
frage("Einwilligungen je Kontaktweg",
    """SELECT CASE w WHEN 'JOURNEY_BOOKING_COMMUNICATIONS' THEN 'Fahrt- und Buchungsinfos'
                     WHEN 'TEXT_SMS_MESSAGES' THEN 'SMS'
                     WHEN 'PUSH_NOTIFICATIONS' THEN 'Push-Nachrichten'
                     WHEN 'POSTAL_MAIL' THEN 'Post'
                     WHEN 'EMAIL' THEN 'E-Mail'
                     ELSE w END AS "Kontaktweg", count(*) AS "Konten"
       FROM rpt.kunde_360, unnest(string_to_array(marketing_einwilligung, ',')) AS w
       WHERE coalesce(marketing_einwilligung, '') <> '' GROUP BY 1 ORDER BY 2 DESC""", "row",
    "Wofür Kunden in der App Nachrichten erlauben. Mehrfachnennung möglich.",
    {"graph.dimensions": ["Kontaktweg"], "graph.metrics": ["Konten"],
     "series_settings": {"Konten": {"color": AMBER}}})
frage("Bestellungen je Konto",
    """SELECT CASE WHEN bestellungen_erfolgreich >= 4 THEN '4 und mehr'
                   ELSE bestellungen_erfolgreich::text END AS "Erfolgreiche Bestellungen",
              count(*) AS "Konten"
       FROM rpt.kunde_360 GROUP BY 1 ORDER BY 1""", "bar",
    "Wie oft ein Konto schon erfolgreich bestellt hat. 0 = Konto ohne Kauf.",
    balken("Erfolgreiche Bestellungen", ["Konten"], [AMBER]))
frage("Käufe nach Wochentag",
    """SELECT (ARRAY['Mo','Di','Mi','Do','Fr','Sa','So'])[wochentag_nr] AS "Wochentag", count(*) AS "Käufe"
       FROM rpt.bestellung WHERE erfolgreich GROUP BY wochentag_nr ORDER BY wochentag_nr""", "bar",
    "Erfolgreiche Bestellungen nach Wochentag. Der Abo-Lauf am 27. fällt auf den jeweiligen Wochentag.",
    balken("Wochentag", ["Käufe"], [TEAL]))
frage("Konten nach Registrierungsmonat",
    """SELECT rpt.monatsname(date_trunc('month', registriert_am)::date) AS "Monat", count(*) AS "Konten"
       FROM rpt.kunde_360 WHERE registriert_am >= '2026-01-01'
       GROUP BY date_trunc('month', registriert_am) ORDER BY date_trunc('month', registriert_am)""", "bar",
    "Angelegte Konten je Monat seit Jahresbeginn 2026 (ältere sind Testkonten).",
    balken("Monat", ["Konten"], [AMBER]))
print(f"  {len(K)} Fragen")

# --- Boards -------------------------------------------------------------
def text(inhalt, col, row, w, h, i):
    return {"id": -i, "card_id": None, "row": row, "col": col, "size_x": w, "size_y": h,
            "visualization_settings": {"virtual_card": {"name": None, "display": "text",
                "visualization_settings": {}, "dataset_query": {}, "archived": False},
                "text": inhalt, "dashcard.background": False},
            "parameter_mappings": []}

def kopf(titel, inhalt):  # Kopfzeile: Text links, Datenstand rechts
    return [("TEXT", f"## {titel}\n{inhalt}", 0, 0, 18, 2), ("Datenstand", 18, 0, 6, 2)]

fehler_raster = []
def board(name, beschreibung, elemente, frueher=()):
    alle = call(f"/api/collection/{COLL}/items?models=dashboard")["data"]
    d = next((x for x in alle if x["name"] in (name, *frueher)), None)
    if d:
        did = d["id"]
    else:
        did = call("/api/dashboard", {"name": name, "description": beschreibung,
                                      "collection_id": COLL})["id"]
    # Einbettung: für neue Boards freigeben, keine Filter, keine Personendaten
    call(f"/api/dashboard/{did}", {"name": name, "description": beschreibung,
                                   "enable_embedding": True, "embedding_params": {},
                                   "width": "full"}, m="PUT")
    karten, belegt = [], {}
    for i, el in enumerate(elemente, 1):
        if el[0] == "TEXT":
            karten.append(text(*el[1:], i)); col, row, w, h = el[2:6]
        else:
            k, col, row, w, h = el
            karten.append({"id": -i, "card_id": K.get(k) or vorhanden[k], "row": row, "col": col,
                           "size_x": w, "size_y": h, "visualization_settings": {},
                           "parameter_mappings": []})
        if col + w > 24: fehler_raster.append(f"{name}: {el[0]} ragt über Spalte 24")
        for r in range(row, row + h):
            for c in range(col, col + w):
                if (r, c) in belegt:
                    fehler_raster.append(f"{name}: {el[0]} überlappt {belegt[(r, c)]}")
                    break
                belegt[(r, c)] = el[0]
    call(f"/api/dashboard/{did}", {"dashcards": karten}, m="PUT")
    print(f"  {did:>3}  {name}: {len(karten)} Kacheln")
    return did

print("Boards zusammenstellen ...")
B = {}
B[1] = board("1 — Überblick", "Absatz, Umsatz und Konten über alle Kanäle seit Marktstart.", [
  *kopf("Überblick", "Absatz und Umsatz über alle Kanäle seit Marktstart am 10. September 2026. "
        "Abo, Einzelticket (ÖPNV) und Fähre: siehe Kanäle unten und Board 3."),
  ("Umsatz brutto", 0, 2, 4, 3), ("Verkäufe", 4, 2, 4, 3), ("Ø Bon", 8, 2, 4, 3),
  ("Käufer", 12, 2, 4, 3), ("Neue Konten", 16, 2, 4, 3), ("Konto zu Kauf", 20, 2, 4, 3),
  ("Bestellungen und Konten je Tag", 0, 5, 12, 7), ("Umsatz je Tag", 12, 5, 12, 7),
  ("Tickets je Tag nach Kanal", 0, 12, 24, 6),
  ("Kaufzeitpunkt im Tagesverlauf", 0, 18, 12, 6), ("Produktmix", 12, 18, 12, 6),
  ("Umsatz je Vertriebskanal", 0, 24, 24, 4)])

B[2] = board("2 — Abo-Bestand", "Überführung des Abo-Bestands in die App.", [
  *kopf("Abo-Bestand und Überführung", "Der Bestand wird jeden Monat vollständig ersetzt. Alle Quoten "
        "zählen Personen, nicht Zeilen. Wer im Monat ein gültiges Ticket hat: Board 5."),
  ("Berechtigungen gesamt", 0, 2, 5, 3), ("Aktivierungsquote Bestand", 5, 2, 5, 3),
  ("Berechtigte ohne App-Konto", 10, 2, 5, 3), ("Aktive Abos", 15, 2, 5, 3), ("Abos mit Störung", 20, 2, 4, 3),
  ("Überführungstrichter", 0, 5, 12, 7), ("Aktivierung je Bestandssegment", 12, 5, 12, 7),
  ("Altersprofil der Berechtigten", 0, 12, 12, 7), ("Arbeitslisten", 12, 12, 12, 7),
  ("Aktivierung nach Postleitzahl", 0, 19, 24, 9),
  ("TEXT", "Die Segmente 9995 und 9999 sind dasselbe Produkt zum selben Preis, ihre Quoten unterscheiden "
           "sich aber deutlich. Wofür die Unterscheidung fachlich steht, ist offen.", 0, 28, 24, 2)])

B[3] = board("3 — Einzeltickets und PayOne", "Einzel- und Fährtickets über PayOne, live seit 7.10.2026.", [
  *kopf("Einzeltickets und PayOne", "Einzel- und Zeitkarten (ÖPNV) und Fährtickets, bezahlt über PayOne, "
        "live seit 7. Oktober 2026: Erfolgsquote, Gründe für Abbrüche, Erstattungen, Relationen."),
  ("Transaktionen PayOne", 0, 2, 4, 3), ("PayOne erfolgreich", 4, 2, 4, 3),
  ("Erfolgsquote PayOne", 8, 2, 4, 3), ("Erfolgsquote PayOne, 7 Tage", 12, 2, 4, 3),
  ("Umsatz Einzeltickets", 16, 2, 4, 3), ("Umsatz Fähre", 20, 2, 4, 3),
  ("PayOne je Tag", 0, 5, 16, 7), ("Ausgang der PayOne-Bestellungen", 16, 5, 8, 7),
  ("Einzeltickets nach Produkt", 0, 12, 12, 8), ("Häufigste Relationen", 12, 12, 12, 8),
  ("PayOne nach Tageszeit", 0, 20, 12, 6), ("PayOne nach Plattform", 12, 20, 6, 6),
  ("Zahlungsabbrüche", 18, 20, 6, 3), ("Erstattet", 18, 23, 6, 3),
  ("Erstattungen im Einzelnen", 0, 26, 24, 6),
  ("TEXT", "### Tarifkatalog\nSeit 7.10.2026 gibt es einen neuen Katalog mit Unterkategorien. Die Produkte "
           "des alten Katalogs bestehen daneben weiter, verkauft wird über die neuen.", 0, 32, 24, 2),
  ("Preisstufen", 0, 34, 4, 3), ("Preispunkte", 4, 34, 4, 3), ("Produkte für PayOne", 8, 34, 4, 3),
  ("Tarifkatalog je Kanal", 12, 34, 12, 7), ("Gültigkeitsregeln", 0, 37, 12, 4),
  ("Preisspannen je Produkt", 0, 41, 24, 8)],
  frueher=("3 — Einzeltickets über PayOne",))

B[4] = board("4 — Betrieb und Störungen", "Für Service und Betrieb.", [
  *kopf("Betrieb und Störungen", "Wie Bestellungen ausgehen, wie schnell Tickets kommen und was "
        "abzuarbeiten ist. Die Abo-Verlängerung am 27. des Monats: Board 6."),
  ("Erfolgsquote", 0, 2, 5, 3), ("Abbrüche", 5, 2, 5, 3), ("Abos mit Störung", 10, 2, 5, 3),
  ("Geräte", 15, 2, 4, 3), ("Durchlaufzeit bis zum Ticket", 19, 2, 5, 3),
  ("Bestellstrecke", 0, 5, 12, 6), ("Abbrüche nach Ursache", 12, 5, 12, 6),
  ("Geräteplattform", 0, 11, 8, 8), ("Arbeitslisten", 8, 11, 16, 8),
  ("Schultickets zum Erwachsenenpreis", 0, 19, 24, 8),
  ("TEXT", "Schultickets zum Erwachsenenpreis: entweder fehlen Nachweise, oder es ist ein Tariffehler. "
           "Die Tabelle zeigt einzelne Bestellungen.", 0, 27, 24, 2)])

B[5] = board("5 — Monatsbilanz Abo", "Wer im laufenden Monat ein gültiges Abo-Ticket hat.", [
  *kopf("Monatsbilanz Abo", "Wer im laufenden Monat berechtigt ist, ein App-Konto hat und ein gültiges "
        "Abo-Ticket bekommen hat. Gezählt wird die Gültigkeit, nicht das Kaufdatum: Das Ticket für einen "
        "Monat wird am 27. des Vormonats ausgestellt."),
  ("Berechtigte im Monat", 0, 2, 4, 3), ("Berechtigte mit App-Konto", 4, 2, 4, 3),
  ("Berechtigte mit aktivem Abo", 8, 2, 4, 3), ("Ticket im Monat", 12, 2, 4, 3),
  ("Ticketquote im Monat", 16, 2, 4, 3), ("Konto, aber kein Ticket", 20, 2, 4, 3),
  ("Hochlaufkette im Monat", 0, 5, 12, 7), ("Monatsbilanz je Segment", 12, 5, 12, 7),
  ("Abo-Tickets je Monat", 0, 12, 12, 7), ("Kundenbindung je Monat", 12, 12, 12, 7),
  ("Ticketquote nach Altersgruppe", 0, 19, 12, 8), ("Ticketquote nach Postleitzahl", 12, 19, 12, 8),
  ("Verlauf der Monatsbilanz", 0, 27, 24, 6)])

B[6] = board("6 — Abo-Verlängerung", "Der Verlängerungslauf am 27. und die Kundenbindung.", [
  *kopf("Abo-Verlängerung", "Am Abrechnungstag (27.) stellt das System für alle aktiven Abos das Ticket "
        "des Folgemonats aus. Hier: was ansteht, was durchgelaufen ist und wo es hakt."),
  ("Nächster Abrechnungstag", 0, 2, 6, 3), ("Abos zur Verlängerung", 6, 2, 6, 3),
  ("Folgemonat schon ausgestellt", 12, 2, 6, 3), ("Abos mit Störung", 18, 2, 6, 3),
  ("Verlängerung nach Abrechnungstag", 0, 5, 12, 7), ("Abo-Tickets je Ausstellungstag", 12, 5, 12, 7),
  ("Abo-Tickets je Monat", 0, 12, 12, 7), ("Kundenbindung je Monat", 12, 12, 12, 7),
  ("Gestörte Abos nach Produkt", 0, 19, 12, 4),
  ("TEXT", "Gestörte Abos sind inaktiv und werden nicht verlängert. Wer betroffen ist, steht in der "
           "Kundenliste (Abo gestört) — nur in Metabase selbst, nicht eingebettet.", 12, 19, 12, 4)])

B[7] = board("7 — App-Nutzung", "Konten, Einwilligungen und Kaufverhalten in der App.", [
  *kopf("App-Nutzung", "Konten, Neuanmeldungen, Einwilligungen und Kaufverhalten. Logins wertet das "
        "Board nicht aus: Die Quelle pflegt den letzten Login nicht."),
  ("Konten gesamt", 0, 2, 4, 3), ("Neue Konten, 7 Tage", 4, 2, 4, 3), ("Neue Konten, 30 Tage", 8, 2, 4, 3),
  ("Gekauft in 30 Tagen", 12, 2, 4, 3), ("Kontakt erlaubt", 16, 2, 4, 3),
  ("Kontolöschung beantragt", 20, 2, 4, 3),
  ("Neue Konten je Tag", 0, 5, 24, 6),
  ("Bestellungen je Konto", 0, 11, 8, 6), ("Käufe nach Wochentag", 8, 11, 8, 6),
  ("Geräteplattform", 16, 11, 8, 6),
  ("Kaufzeitpunkt im Tagesverlauf", 0, 17, 12, 6), ("Einwilligungen je Kontaktweg", 12, 17, 12, 6),
  ("Konten nach Registrierungsmonat", 0, 23, 24, 5)])

if fehler_raster:
    print("RASTER:", *fehler_raster, sep="\n  "); sys.exit(1)

# --- Probelauf: jede Kachel muss ohne Fehler antworten -------------------
print("Kacheln prüfen ...")
leer, kaputt = [], []
for nr, did in B.items():
    for dc in call(f"/api/dashboard/{did}")["dashcards"]:
        if not dc.get("card_id"): continue
        name = dc["card"]["name"]
        erg = call(f"/api/card/{dc['card_id']}/query", {})
        if erg.get("error"): kaputt.append(f"Board {nr}, {name}: {str(erg['error'])[:150]}")
        elif not erg.get("data", {}).get("rows"): leer.append(f"Board {nr}, {name}")
for z in kaputt: print("  FEHLER", z)
for z in leer: print("  leer  ", z)
ids = ", ".join(f"{nr}={did}" for nr, did in B.items())
print(f"Fertig. Board-IDs: {ids}" + (" — mit Fehlern" if kaputt else ""))
sys.exit(1 if kaputt else 0)
