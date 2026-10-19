#!/usr/bin/env python3
"""Kundenliste der Abo-Berechtigten nach Ticket (Bestandssegment 9995 / 9999).

Legt in der Sammlung "LüMobil Vertrieb" eine Frage an, die je Person eine
Zeile liefert: E-Mail, Name, Kundennummer, Ticket, PLZ, Gültigkeit, App-Konto
und ob im gewählten Monat ein Ticket versendet wurde.
Filter oben: Ticket (vorbelegt: beide), Monat (vorbelegt: aktueller),
Ticket versendet ja/nein (leer: alle). Unten lädt man die Liste als CSV.

Enthält Personendaten. Die Frage gehört NICHT auf ein Dashboard fürs
Hilfecenter, sondern ist nur in der Metabase-Oberfläche erreichbar.

  Demo:    python3 metabase-setup/12_kundenliste.py
  Server:  ssh -L 3001:127.0.0.1:3001 admin@server   # offen lassen, dann
           MB_URL=http://localhost:3001 MB_EMAIL=… MB_PASSWORT=… \\
             python3 metabase-setup/12_kundenliste.py

Idempotent: Gibt es die Frage schon, wird sie auf diesen Stand gebracht.
"""
import csv, io, json, os, urllib.error, urllib.parse, urllib.request, uuid

BASE = os.environ.get("MB_URL", "http://localhost:3030").rstrip("/")
ANMELDUNG = {"username": os.environ.get("MB_EMAIL", "demo@luemobil.local"),
             "password": os.environ.get("MB_PASSWORT", "LueMobilDemo2026")}
NAME = "Kundenliste nach Ticket (9995 / 9999)"
TICKETS = ["9995", "9999"]
tok = None

def call(p, d=None, m=None):
    r = urllib.request.Request(BASE + p, data=json.dumps(d).encode() if d is not None else None,
                               method=m or ("POST" if d is not None else "GET"))
    r.add_header("Content-Type", "application/json")
    if tok: r.add_header("X-Metabase-Session", tok)
    try:
        with urllib.request.urlopen(r, timeout=180) as x:
            raw = x.read().decode(); return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{p} -> {e.code}: {e.read().decode()[:250]}")

tok = call("/api/session", ANMELDUNG)["id"]
dbs = call("/api/database"); dbs = dbs["data"] if isinstance(dbs, dict) else dbs
db_id = next(d["id"] for d in dbs if d["name"] == "LüMobil Reporting")
COLL = next(c["id"] for c in call("/api/collection") if c.get("name") == "LüMobil Vertrieb")

# Feldfilter: Metabase setzt die Bedingung selbst ein und bietet beim Ticket
# die vorhandenen Werte, beim Monat die Datumsauswahl an.
def feld(tabelle, spalte):
    t = next(t for t in call("/api/table") if t["schema"] == "rpt" and t["name"] == tabelle)
    return next(f["id"] for f in call(f"/api/table/{t['id']}/query_metadata")["fields"]
                if f["name"] == spalte)
FELD_TICKET = feld("abo_berechtigung", "bestandssegment")
FELD_KAUFTAG = feld("bestellung", "kauftag")
call(f"/api/field/{FELD_TICKET}", {"display_name": "Ticket", "has_field_values": "list"}, m="PUT")

# Je Person eine Zeile (Personenebene wie überall: normalisierte E-Mail).
# Wer beide Tickets hat, erscheint einmal mit "9995, 9999".
# Versendet = Bestellung im Status 3 "Versendet" oder 47 "Versendet und
# ausgecheckt" im gewählten Monat. Die Berechtigung kennt keine Bestellnummer
# (order_number ist leer), die Zuordnung läuft daher über die E-Mail.
# Feldfilter brauchen den vollen Tabellennamen — kein Alias im FROM.
SQL = """WITH liste AS (
  SELECT kunde_email,
         min(name)                                                    AS name,
         string_agg(DISTINCT abo_kundennummer, ', ')                  AS kundennummer,
         string_agg(DISTINCT bestandssegment, ', ' ORDER BY bestandssegment) AS ticket,
         min(produkt) AS produkt, min(plz) AS plz, min(ort) AS ort,
         min(gueltig_ab) AS gueltig_ab, max(gueltig_bis) AS gueltig_bis,
         bool_or(aktiviert)                                           AS app_konto
  FROM rpt.abo_berechtigung
  WHERE {{ticket}}
  GROUP BY kunde_email
), versand AS (
  SELECT kunde_email, count(*) AS anzahl, max(gekauft_am) AS zuletzt
  FROM rpt.bestellung
  WHERE status_id IN (3, 47) AND {{monat}}
  GROUP BY kunde_email
)
SELECT
  l.kunde_email              AS "E-Mail",
  l.name                     AS "Name",
  l.kundennummer             AS "Abo-Kundennummer",
  l.ticket                   AS "Ticket",
  l.produkt                  AS "Produkt",
  l.plz                      AS "PLZ",
  l.ort                      AS "Ort",
  l.gueltig_ab               AS "Gültig ab",
  l.gueltig_bis              AS "Gültig bis",
  l.app_konto                AS "App-Konto",
  v.kunde_email IS NOT NULL  AS "Ticket versendet",
  coalesce(v.anzahl, 0)      AS "Versendete Tickets",
  v.zuletzt                  AS "Zuletzt versendet"
FROM liste l
LEFT JOIN versand v ON v.kunde_email = l.kunde_email
WHERE true
[[AND (v.kunde_email IS NOT NULL) = ({{versendet}} = 'ja')]]
ORDER BY "Name", "E-Mail\""""

# Filter: Kennung bei einer vorhandenen Frage behalten, sonst verlieren
# gespeicherte Links ihre Auswahl.
vorhanden = next((c for c in call(f"/api/collection/{COLL}/items?models=card")["data"]
                  if c["name"] == NAME), None)
alte_tags = {}
if vorhanden:
    alte_tags = call(f"/api/card/{vorhanden['id']}")["dataset_query"] \
                .get("native", {}).get("template-tags", {})
tid = lambda n: alte_tags.get(n, {}).get("id") or str(uuid.uuid4())

FILTER = [  # Name, Anzeige, Art, Feld, Vorbelegung
    ("ticket", "Ticket", "string/=", FELD_TICKET, TICKETS),
    ("monat", "Versendet im Monat", "date/all-options", FELD_KAUFTAG, "thismonth"),
    ("versendet", "Ticket versendet", "string/=", None, None),
]
tags, parameter = {}, []
for name, anzeige, art, feld_id, vorbelegung in FILTER:
    tag = {"id": tid(name), "name": name, "display-name": anzeige}
    par = {"id": tag["id"], "name": anzeige, "slug": name, "type": art}
    if feld_id:
        tag.update({"type": "dimension", "dimension": ["field", feld_id, None],
                    "widget-type": art, "default": vorbelegung})
        par["target"] = ["dimension", ["template-tag", name]]
        par["default"] = vorbelegung
    else:  # ja / nein, leer = alle
        tag.update({"type": "text"})
        par.update({"target": ["variable", ["template-tag", name]],
                    "values_query_type": "list", "values_source_type": "static-list",
                    "values_source_config": {"values": ["ja", "nein"]}})
    tags[name] = tag; parameter.append(par)

DAT = {"date_style": "D.M.YYYY"}
karte = {
    "name": NAME,
    "description": "Alle Abo-Berechtigten mit Ticket 9995 und/oder 9999, eine Zeile je Person, "
                   "dazu ob im gewählten Monat (vorbelegt: aktueller) ein Ticket versendet wurde. "
                   "Oben filtern, unten rechts als CSV herunterladen. "
                   "Enthält Personendaten — nicht weitergeben, nicht einbetten.",
    "collection_id": COLL, "display": "table",
    "dataset_query": {"type": "native", "database": db_id,
                      "native": {"query": SQL, "template-tags": tags}},
    "parameters": parameter,
    "visualization_settings": {"column_settings": {
        json.dumps(["name", n], separators=(",", ":")): o for n, o in
        [("Gültig ab", DAT), ("Gültig bis", DAT),
         ("Zuletzt versendet", {**DAT, "time_enabled": "minutes", "time_style": "HH:mm"})]}},
}
if vorhanden:
    call(f"/api/card/{vorhanden['id']}", karte, m="PUT"); cid = vorhanden["id"]
    print(f"Frage aktualisiert (ID {cid})")
else:
    cid = call("/api/card", karte)["id"]
    print(f"Frage angelegt (ID {cid})")

# Probelauf mit der Vorbelegung
# (MONAT=JJJJ-MM für einen anderen Monat, etwa mit den Demo-Daten vom September)
monat = os.environ.get("MONAT", "thismonth")
def zaehlen(versendet=None):
    p = [{"id": tags["ticket"]["id"], "type": "string/=", "value": TICKETS,
          "target": ["dimension", ["template-tag", "ticket"]]},
         {"id": tags["monat"]["id"], "type": "date/all-options", "value": monat,
          "target": ["dimension", ["template-tag", "monat"]]}]
    if versendet:
        p.append({"id": tags["versendet"]["id"], "type": "string/=", "value": [versendet],
                  "target": ["variable", ["template-tag", "versendet"]]})
    # Über den CSV-Download zählen: die Abfrage selbst liefert höchstens 2000 Zeilen
    r = urllib.request.Request(f"{BASE}/api/card/{cid}/query/csv", method="POST",
        data=urllib.parse.urlencode({"parameters": json.dumps(p)}).encode(),
        headers={"X-Metabase-Session": tok})
    with urllib.request.urlopen(r, timeout=180) as x:
        zeilen = list(csv.reader(io.StringIO(x.read().decode("utf-8-sig"))))
    if not zeilen or zeilen[0][0] != "E-Mail":
        raise SystemExit(f"Probelauf fehlgeschlagen: {zeilen[:2]}")
    return len(zeilen) - 1
print(f"  {zaehlen()} Personen mit Ticket {' oder '.join(TICKETS)}")
print(f"  davon mit versendetem Ticket ({monat}): {zaehlen('ja')}, ohne: {zaehlen('nein')}")
print(f"  Öffnen: {BASE}/question/{cid}")
