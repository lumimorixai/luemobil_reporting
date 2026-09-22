#!/usr/bin/env python3
"""
LüMobil — Metabase einrichten
=============================
Legt Admin-Konto, Datenbankverbindung, Metadaten, Fragen und Dashboards an.
Idempotent: bereits vorhandene Objekte werden übersprungen.

Aufruf:  python3 05_metabase_einrichten.py
"""
import json, time, urllib.request, urllib.error, getpass, sys

BASE  = "http://localhost:3030"
ADMIN = {"first_name": "LüMobil", "last_name": "Demo",
         "email": "demo@luemobil.local", "password": "LueMobilDemo2026"}
DB    = {"name": "LüMobil Reporting", "dbname": "lue_reporting",
         "host": "localhost", "port": 5432, "user": getpass.getuser()}

session_token = None

def call(path, data=None, method=None):
    url = BASE + path
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body,
        method=method or ("POST" if data is not None else "GET"))
    req.add_header("Content-Type", "application/json")
    if session_token:
        req.add_header("X-Metabase-Session", session_token)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:400]
        raise RuntimeError(f"{method or 'GET'} {path} -> {e.code}: {detail}")

# ---------------------------------------------------------------- Setup
props = call("/api/session/properties")
if props.get("setup-token"):
    print("Admin-Konto anlegen ...")
    session_token = call("/api/setup", {
        "token": props["setup-token"],
        "user": ADMIN,
        "prefs": {"site_name": "LüMobil", "site_locale": "de",
                  "allow_tracking": False},
    })["id"]
else:
    print("Setup bereits erfolgt, anmelden ...")
    session_token = call("/api/session",
        {"username": ADMIN["email"], "password": ADMIN["password"]})["id"]
print("  angemeldet")

# ------------------------------------------------------------ Datenbank
dbs = call("/api/database")
dbs = dbs["data"] if isinstance(dbs, dict) else dbs
db = next((d for d in dbs if d["name"] == DB["name"]), None)
if not db:
    print("Datenbankverbindung anlegen ...")
    db = call("/api/database", {
        "name": DB["name"], "engine": "postgres",
        "details": {"host": DB["host"], "port": DB["port"], "dbname": DB["dbname"],
                    "user": DB["user"], "password": "", "ssl": False,
                    "schema-filters-type": "inclusion", "schema-filters-patterns": "rpt"},
        "is_full_sync": True,
    })
db_id = db["id"]
print(f"  Datenbank-ID {db_id}")

print("Warte auf Schema-Abgleich ...")
for _ in range(60):
    tables = call(f"/api/database/{db_id}/metadata").get("tables", [])
    if len([t for t in tables if t["schema"] == "rpt"]) >= 9:
        break
    time.sleep(5)
tables = {t["name"]: t for t in call(f"/api/database/{db_id}/metadata").get("tables", [])
          if t["schema"] == "rpt"}
print(f"  {len(tables)} Views erkannt: {', '.join(sorted(tables))}")

# ------------------------------------------------------- Metadatenpflege
ANZEIGENAMEN = {
    "bestellung": "Bestellungen", "bestellposition": "Bestellpositionen",
    "kunde_360": "Kunden (360°)", "abo_berechtigung": "Abo-Berechtigungen",
    "abo": "Abonnements", "produkt": "Produkte", "statuslauf": "Statusverlauf",
    "tagesreihe": "Tagesreihe", "aktivierung_plz": "Aktivierung je PLZ",
    "aktivierung_segment": "Aktivierung je Segment", "trichter": "Überführungstrichter",
    "arbeitsliste": "Arbeitslisten",
}
BESCHREIBUNG = {
    "bestellung": "Eine Zeile je Bestellung. Umsatz brutto und netto sind bereits "
                  "korrekt getrennt (ot_total ist brutto). Die Verknüpfung in die "
                  "Shop-Datenbank läuft über shop_bestellung_id, nicht über die Kundennummer.",
    "kunde_360": "App-Konto, Abo-Bestand und Kaufverhalten je Person. Das Geburtsdatum "
                 "stammt aus der Berechtigung, nicht aus dem Konto (dort Platzhalter).",
    "abo_berechtigung": "Abo-Bestand, eine Zeile je Berechtigung. Für Personenzählungen "
                        "auf 'ist_hauptzeile = wahr' filtern (8.267 Zeilen, 8.215 Personen).",
    "arbeitsliste": "Die gespeicherten Suchen als Übersicht: was der Service abarbeiten muss.",
    "trichter": "Der Überführungstrichter vom Bestand zum laufenden Abo, Personenebene.",
}
GELDFELDER = {"umsatz_brutto", "umsatz_netto", "steuer", "preis",
              "einzelpreis_netto", "einzelpreis_brutto", "positionswert_netto"}

print("Metadaten pflegen ...")
for name, t in tables.items():
    payload = {"display_name": ANZEIGENAMEN.get(name, name)}
    if name in BESCHREIBUNG:
        payload["description"] = BESCHREIBUNG[name]
    call(f"/api/table/{t['id']}", payload, method="PUT")
    for f in t.get("fields", []):
        upd = {"display_name": f["name"].replace("_", " ").capitalize()}
        if f["name"] in GELDFELDER:
            upd["semantic_type"] = "type/Currency"
            upd["settings"] = {"currency": "EUR", "currency_style": "symbol",
                               "number_style": "decimal"}
        elif f["name"] == "plz":
            upd["semantic_type"] = "type/ZipCode"
        elif f["name"].endswith("_email"):
            upd["semantic_type"] = "type/Email"
        elif f["name"] == "quote_prozent":
            upd["semantic_type"] = "type/Percentage"
        try:
            call(f"/api/field/{f['id']}", upd, method="PUT")
        except RuntimeError:
            pass
print("  fertig")

# ------------------------------------------------------------- Sammlung
colls = call("/api/collection")
coll = next((c for c in colls if c.get("name") == "LüMobil Vertrieb"), None)
if not coll:
    coll = call("/api/collection", {"name": "LüMobil Vertrieb",
        "description": "Boards und Fragen für Vertrieb, Service und Controlling.",
        "color": "#0F6F7E", "parent_id": None})
coll_id = coll["id"]
print(f"Sammlung 'LüMobil Vertrieb' (ID {coll_id})")

# --------------------------------------------------------------- Fragen
def frage(name, sql, anzeige="table", beschreibung=None, viz=None):
    """Legt eine SQL-Frage an (oder gibt die vorhandene zurück)."""
    vorhandene = call(f"/api/collection/{coll_id}/items?models=card").get("data", [])
    treffer = next((c for c in vorhandene if c["name"] == name), None)
    if treffer:
        return treffer["id"]
    card = call("/api/card", {
        "name": name, "description": beschreibung,
        "collection_id": coll_id, "display": anzeige,
        "dataset_query": {"type": "native", "database": db_id,
                          "native": {"query": sql}},
        "visualization_settings": viz or {},
    })
    return card["id"]

print("Fragen anlegen ...")
K = {}

K["umsatz"] = frage("Umsatz brutto (erfolgreich)",
    "SELECT sum(umsatz_brutto) AS \"Umsatz brutto\" FROM rpt.bestellung WHERE erfolgreich",
    "scalar", "Summe über alle erfolgreich abgeschlossenen Bestellungen.")

K["verkaeufe"] = frage("Verkäufe",
    "SELECT count(*) AS \"Verkäufe\" FROM rpt.bestellung WHERE erfolgreich", "scalar")

K["quote"] = frage("Aktivierungsquote Bestand",
    """SELECT round(100.0 * count(*) FILTER (WHERE aktiviert) / count(*), 1) AS "Quote %"
       FROM rpt.abo_berechtigung WHERE ist_hauptzeile""", "scalar",
    "Anteil der Abo-Berechtigten mit App-Konto. Die zentrale Hochlaufkennzahl.")

K["offen"] = frage("Berechtigte ohne App-Konto",
    """SELECT count(*) AS "Offen" FROM rpt.abo_berechtigung
       WHERE NOT aktiviert AND ist_hauptzeile""", "scalar",
    "Adressierbares Potenzial für Kampagnen.")

K["stoerung"] = frage("Abos mit Störung",
    "SELECT count(*) AS \"Störungen\" FROM rpt.abo WHERE stoerung", "scalar")

K["verlauf"] = frage("Bestellungen und Konten je Tag",
    """SELECT tag AS "Tag", bestellungen AS "Bestellungen", neue_konten AS "Neue Konten"
       FROM rpt.tagesreihe ORDER BY tag""", "line",
    "Der Hochlauf seit Marktstart am 10.09.",
    {"graph.dimensions": ["Tag"], "graph.metrics": ["Bestellungen", "Neue Konten"]})

K["umsatztag"] = frage("Umsatz je Tag",
    """SELECT tag AS "Tag", umsatz_brutto AS "Umsatz brutto"
       FROM rpt.tagesreihe ORDER BY tag""", "bar", None,
    {"graph.dimensions": ["Tag"], "graph.metrics": ["Umsatz brutto"]})

K["trichter"] = frage("Überführungstrichter",
    "SELECT schritt AS \"Schritt\", anzahl AS \"Personen\" FROM rpt.trichter ORDER BY stufe",
    "funnel", "Vom Abo-Bestand zum laufenden Abo.",
    {"funnel.dimension": "Schritt", "funnel.metric": "Personen"})

K["plz"] = frage("Aktivierung nach Postleitzahl",
    """SELECT plz AS "PLZ", ort AS "Ort", berechtigte AS "Berechtigte",
              aktivierte AS "Aktivierte", offen AS "Offen", quote_prozent AS "Quote %"
       FROM rpt.aktivierung_plz WHERE berechtigte >= 20
       ORDER BY berechtigte DESC""", "table",
    "Gebiete ab 20 Berechtigten. Grundlage für Gebietskampagnen, Spalten sortierbar.")

K["segment"] = frage("Aktivierung je Bestandssegment",
    """SELECT bestandssegment AS "Segment", berechtigte AS "Berechtigte",
              quote_prozent AS "Quote %"
       FROM rpt.aktivierung_segment ORDER BY quote_prozent DESC""", "bar",
    "9995 gegen 9999 — gleiches Produkt, gleicher Preis, sehr verschiedene Quote.",
    {"graph.dimensions": ["Segment"], "graph.metrics": ["Quote %"]})

K["produktmix"] = frage("Produktmix",
    """SELECT produkt AS "Produkt", count(*) AS "Stück",
              sum(einzelpreis_brutto) AS "Umsatz brutto"
       FROM rpt.bestellposition WHERE erfolgreich GROUP BY produkt ORDER BY 2 DESC""",
    "bar", None, {"graph.dimensions": ["Produkt"], "graph.metrics": ["Stück"]})

K["kanal"] = frage("Umsatz je Vertriebskanal",
    """SELECT coalesce(vertriebskanal,'unbekannt') AS "Kanal",
              count(*) AS "Verkäufe", sum(einzelpreis_brutto) AS "Umsatz brutto"
       FROM rpt.bestellposition WHERE erfolgreich GROUP BY 1 ORDER BY 3 DESC""",
    "row", "Einzelticket und Fähre bleiben leer, bis PayOne live ist.",
    {"graph.dimensions": ["Kanal"], "graph.metrics": ["Umsatz brutto"]})

K["stunde"] = frage("Kaufzeitpunkt im Tagesverlauf",
    """SELECT kaufstunde AS "Stunde", count(*) AS "Käufe"
       FROM rpt.bestellung GROUP BY 1 ORDER BY 1""", "bar", None,
    {"graph.dimensions": ["Stunde"], "graph.metrics": ["Käufe"]})

K["plattform"] = frage("Geräteplattform",
    """SELECT plattform AS "Plattform", count(DISTINCT geraet_id) AS "Geräte"
       FROM rpt.bestellung WHERE geraet_id IS NOT NULL GROUP BY 1""", "pie", None,
    {"pie.dimension": "Plattform", "pie.metric": "Geräte"})

K["abbruch"] = frage("Abbrüche nach Ursache",
    """SELECT abbruchursache AS "Ursache", count(*) AS "Fälle"
       FROM rpt.statuslauf WHERE abbruchursache IS NOT NULL
       GROUP BY 1 ORDER BY 2 DESC""", "row", None,
    {"graph.dimensions": ["Ursache"], "graph.metrics": ["Fälle"]})

K["laufzeit"] = frage("Durchlaufzeit bis zum Ticket",
    """SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sekunden_bis_ticket)::numeric,2) AS "Median s",
              round(percentile_cont(0.95) WITHIN GROUP (ORDER BY sekunden_bis_ticket)::numeric,2) AS "p95 s",
              round(max(sekunden_bis_ticket)::numeric,2) AS "Maximum s"
       FROM rpt.bestellung WHERE sekunden_bis_ticket IS NOT NULL""", "table")

K["arbeit"] = frage("Arbeitslisten",
    """SELECT liste AS "Liste", zweck AS "Zweck", faelle AS "Fälle"
       FROM rpt.arbeitsliste ORDER BY faelle DESC""", "table",
    "Was heute abzuarbeiten ist.")

K["vollpreis"] = frage("Schultickets zum Erwachsenenpreis",
    """SELECT bestellung_id AS "Bestellung", kauftag AS "Kauftag", produkt AS "Produkt",
              einzelpreis_brutto AS "Preis brutto", status AS "Status"
       FROM rpt.bestellposition
       WHERE produkt LIKE '%Schule%' AND einzelpreis_netto > 50
       ORDER BY kauftag""", "table",
    "194 Fälle mit 63 € statt 43 €. Tarifprüfung.")

K["katalog"] = frage("Tarifkatalog nach Kanal",
    """SELECT vertriebskanal AS "Kanal", count(*) AS "Produkte",
              sum(anzahl_preisstufen) AS "Preispunkte"
       FROM rpt.produkt GROUP BY 1 ORDER BY 2 DESC""", "table",
    "31 der 34 Produkte sind für PayOne freigeschaltet.")

print(f"  {len(K)} Fragen angelegt")

# ------------------------------------------------------------ Dashboards
def dashboard(name, beschreibung, kacheln):
    vorhandene = call(f"/api/collection/{coll_id}/items?models=dashboard").get("data", [])
    if any(d["name"] == name for d in vorhandene):
        print(f"  '{name}' besteht bereits")
        return
    d = call("/api/dashboard", {"name": name, "description": beschreibung,
                                "collection_id": coll_id})
    cards = []
    for i, (key, col, row, w, h) in enumerate(kacheln):
        cards.append({"id": -(i + 1), "card_id": K[key], "row": row, "col": col,
                      "size_x": w, "size_y": h,
                      "visualization_settings": {}, "parameter_mappings": []})
    call(f"/api/dashboard/{d['id']}", {"dashcards": cards}, method="PUT")
    print(f"  '{name}' mit {len(cards)} Kacheln")

print("Dashboards bauen ...")
dashboard("1 — Hochlauf-Cockpit",
    "Tagesgeschäft für die Geschäftsführung. Stand der Dumps vom 15.09.2026.",
    [("umsatz", 0, 0, 6, 3), ("verkaeufe", 6, 0, 6, 3),
     ("quote", 12, 0, 6, 3), ("offen", 18, 0, 6, 3),
     ("verlauf", 0, 3, 12, 6), ("umsatztag", 12, 3, 12, 6),
     ("stunde", 0, 9, 12, 5), ("produktmix", 12, 9, 12, 5),
     ("kanal", 0, 14, 24, 4)])

dashboard("2 — Bestandsüberführung",
    "Für Vertrieb und Marketing: wo der Abo-Bestand aktiviert und wo nicht.",
    [("quote", 0, 0, 8, 3), ("offen", 8, 0, 8, 3), ("stoerung", 16, 0, 8, 3),
     ("trichter", 0, 3, 12, 7), ("segment", 12, 3, 12, 7),
     ("plz", 0, 10, 24, 8)])

dashboard("3 — Betrieb und Störungen",
    "Für Service und Betrieb. Harter Termin: Verlängerungslauf am 27.09.2026.",
    [("stoerung", 0, 0, 8, 3), ("laufzeit", 8, 0, 16, 3),
     ("abbruch", 0, 3, 12, 6), ("plattform", 12, 3, 12, 6),
     ("arbeit", 0, 9, 12, 6), ("vollpreis", 12, 9, 12, 6)])

dashboard("4 — Produkt und Tarif",
    "Für Controlling: Produktmix, Preisstufen-Ausnahmen, PayOne-Bereitschaft.",
    [("produktmix", 0, 0, 12, 6), ("kanal", 12, 0, 12, 6),
     ("katalog", 0, 6, 12, 5), ("vollpreis", 12, 6, 12, 5)])

print("\nFertig.")
print(f"  {BASE}")
print(f"  Anmeldung: {ADMIN['email']} / {ADMIN['password']}")
