#!/usr/bin/env python3
"""Kundenliste der Abo-Berechtigten nach Ticket (Bestandssegment 9995 / 9999).

Legt in der Sammlung "LüMobil Vertrieb" eine Frage an, die je Person eine
Zeile liefert: E-Mail, Name, Kundennummer, Ticket, PLZ, Gültigkeit, App-Konto,
Abo-Status und ob für den gewählten Monat ein Abo-Ticket ausgestellt
(versendet) wurde. Maßgeblich ist die Gültigkeit des Tickets, nicht das
Kaufdatum: Das Ticket für Oktober wird am 27. September ausgestellt.
Setzt 13_app_reports.sql voraus (rpt.bestellposition.gueltigkeitsmonat).
Filter oben: Ticket (vorbelegt: beide), Monat (vorbelegt: aktueller),
Ticket versendet ja/nein (leer: alle). Unten lädt man die Liste als CSV.

Mit --csv schreibt es die Liste zusätzlich als CSV auf die Standardausgabe,
ganz ohne Browser. Meldungen gehen dann auf die Fehlerausgabe.

Enthält Personendaten. Die Frage gehört NICHT auf ein Dashboard fürs
Hilfecenter, sondern ist nur in der Metabase-Oberfläche erreichbar.

  Demo:    python3 metabase-setup/12_kundenliste.py [--csv …]
  Server:  docker compose run --rm kundenliste                      # einrichten
           docker compose run --rm -T kundenliste --csv --versendet ja > liste.csv
           (-T ist Pflicht: ohne landen Meldungen in der Datei)
  Tunnel:  MB_URL=http://localhost:3001 MB_EMAIL=… MB_PASSWORT=… \\
             python3 metabase-setup/12_kundenliste.py

Idempotent: Gibt es die Frage schon, wird sie auf diesen Stand gebracht.
"""
import argparse, csv, io, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request, uuid

BASE = os.environ.get("MB_URL", "http://localhost:3030").rstrip("/")
ANMELDUNG = {"username": os.environ.get("MB_EMAIL", "demo@luemobil.local"),
             "password": os.environ.get("MB_PASSWORT", "LueMobilDemo2026")}
NAME = "Kundenliste nach Ticket (9995 / 9999)"
TICKETS = ["9995", "9999"]
tok = None

def monat_pruefen(w):
    if w != "thismonth" and not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", w):
        raise argparse.ArgumentTypeError("Monat als JJJJ-MM angeben, z. B. 2026-10")
    return w
ap = argparse.ArgumentParser(description="Kundenliste der Abo-Berechtigten nach Ticket")
ap.add_argument("--csv", action="store_true", help="Liste als CSV auf die Standardausgabe")
ap.add_argument("--monat", default="thismonth", type=monat_pruefen,
                help="Monat, in dem das Ticket gilt, JJJJ-MM (Standard: aktueller Monat)")
ap.add_argument("--versendet", choices=["ja", "nein"], help="nur mit / ohne versendetes Ticket")
ap.add_argument("--ticket", action="append", choices=TICKETS,
                help="nur dieses Ticket (mehrfach möglich, Standard: beide)")
ap.add_argument("--stoerung", nargs="?", const="offen", choices=["offen", "alle"],
                help="mit --csv: statt der Kundenliste die Klärliste der gestörten Abos "
                     "(Standard: nur offene Fälle)")
args = ap.parse_args()
# Bei --csv gehört die Standardausgabe allein der Liste
melden = lambda *t: print(*t, file=sys.stderr if args.csv else sys.stdout)

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
    t = next((t for t in call("/api/table") if t["schema"] == "rpt" and t["name"] == tabelle), None)
    if not t: return None
    return next((f["id"] for f in call(f"/api/table/{t['id']}/query_metadata")["fields"]
                 if f["name"] == spalte), None)
def feld_abwarten(tabelle, spalte):
    """Neue Spalten kennt Metabase erst nach einem Schema-Abgleich."""
    fid = feld(tabelle, spalte)
    if fid: return fid
    melden(f"  Metabase gleicht das Schema ab (neue Spalte {tabelle}.{spalte}) ...")
    call(f"/api/database/{db_id}/sync_schema", {})
    for _ in range(60):
        time.sleep(5)
        fid = feld(tabelle, spalte)
        if fid: return fid
    raise SystemExit(f"Metabase kennt {tabelle}.{spalte} nicht. Ist 13_app_reports.sql eingespielt?")
FELD_TICKET = feld_abwarten("abo_berechtigung", "bestandssegment")
FELD_MONAT = feld_abwarten("bestellposition", "gueltigkeitsmonat")
call(f"/api/field/{FELD_TICKET}", {"display_name": "Ticket", "has_field_values": "list"}, m="PUT")

# Je Person eine Zeile (Personenebene wie überall: normalisierte E-Mail).
# Wer beide Tickets hat, erscheint einmal mit "9995, 9999".
# Versendet = ausgestelltes Abo-Ticket (Status 3 "Versendet"), das im
# gewählten Monat gilt. Die Berechtigung kennt keine Bestellnummer
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
  FROM rpt.bestellposition
  WHERE vertriebskanal = 'Abo' AND erfolgreich AND {{monat}}
  GROUP BY kunde_email
), abo AS (
  SELECT kunde_email, bool_or(aktiv) AS aktiv, bool_or(stoerung) AS gestoert
  FROM rpt.abo WHERE kunde_email IS NOT NULL GROUP BY kunde_email
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
  coalesce(a.aktiv, false)   AS "Aktives Abo",
  coalesce(a.gestoert, false) AS "Abo stillgelegt",
  v.kunde_email IS NOT NULL  AS "Ticket versendet",
  coalesce(v.anzahl, 0)      AS "Versendete Tickets",
  v.zuletzt                  AS "Ausgestellt am"
FROM liste l
LEFT JOIN versand v ON v.kunde_email = l.kunde_email
LEFT JOIN abo a     ON a.kunde_email = l.kunde_email
WHERE true
[[AND (v.kunde_email IS NOT NULL) = ({{versendet}} = 'ja')]]
ORDER BY "Name", "E-Mail\""""

# Filter: Kennung bei einer vorhandenen Frage behalten, sonst verlieren
# gespeicherte Links ihre Auswahl.
vorhanden = next((c for c in call(f"/api/collection/{COLL}/items?models=card")["data"]
                  if c["name"] == NAME), None)
alte_tags = {}
if vorhanden:  # Metabase ab 0.63 liefert die Abfrage in "stages" zurück
    alt = call(f"/api/card/{vorhanden['id']}")["dataset_query"]
    alte_tags = (alt.get("native") or (alt.get("stages") or [{}])[0]).get("template-tags", {}) or {}
    if isinstance(alte_tags, list):  # neues Format: Liste statt Name -> Tag
        alte_tags = {t["name"]: t for t in alte_tags}
tid = lambda n: alte_tags.get(n, {}).get("id") or str(uuid.uuid4())

FILTER = [  # Name, Anzeige, Art, Feld, Vorbelegung
    ("ticket", "Ticket", "string/=", FELD_TICKET, TICKETS),
    ("monat", "Ticket gültig im Monat", "date/all-options", FELD_MONAT, "thismonth"),
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
                   "dazu ob für den gewählten Monat (vorbelegt: aktueller) ein Abo-Ticket ausgestellt "
                   "wurde. Gezählt wird die Gültigkeit, nicht das Kaufdatum. "
                   "Oben filtern, unten rechts als CSV herunterladen. "
                   "Enthält Personendaten — nicht weitergeben, nicht einbetten.",
    "collection_id": COLL, "display": "table",
    "dataset_query": {"type": "native", "database": db_id,
                      "native": {"query": SQL, "template-tags": tags}},
    "parameters": parameter,
    "visualization_settings": {"column_settings": {
        json.dumps(["name", n], separators=(",", ":")): o for n, o in
        [("Gültig ab", DAT), ("Gültig bis", DAT),
         ("Ausgestellt am", {**DAT, "time_enabled": "minutes", "time_style": "HH:mm"})]}},
}
if vorhanden:
    call(f"/api/card/{vorhanden['id']}", karte, m="PUT"); cid = vorhanden["id"]
    melden(f"Frage aktualisiert (ID {cid})")
else:
    cid = call("/api/card", karte)["id"]
    melden(f"Frage angelegt (ID {cid})")

def liste(tickets, monat, versendet=None, formatiert=False):
    """Die Liste über den CSV-Download — die Abfrage selbst liefert höchstens 2000 Zeilen."""
    p = [{"id": tags["ticket"]["id"], "type": "string/=", "value": tickets,
          "target": ["dimension", ["template-tag", "ticket"]]},
         {"id": tags["monat"]["id"], "type": "date/all-options", "value": monat,
          "target": ["dimension", ["template-tag", "monat"]]}]
    if versendet:
        p.append({"id": tags["versendet"]["id"], "type": "string/=", "value": [versendet],
                  "target": ["variable", ["template-tag", "versendet"]]})
    daten = {"parameters": json.dumps(p)}
    if formatiert:  # wie der Download in der Oberfläche: Datum als 1.9.2026
        daten["format_rows"] = "true"
    r = urllib.request.Request(f"{BASE}/api/card/{cid}/query/csv", method="POST",
        data=urllib.parse.urlencode(daten).encode(), headers={"X-Metabase-Session": tok})
    with urllib.request.urlopen(r, timeout=600) as x:
        text = x.read().decode("utf-8-sig")
    if not text.startswith("E-Mail,"):
        raise SystemExit(f"Abfrage fehlgeschlagen: {text[:250]}")
    return text

# --- Klärliste der gestörten Abos ---------------------------------------
# Die Quelle markiert jedes stillgelegte Abo als gestört. rpt.abo_stoerung
# ordnet jedes über den Fahrgast ein (siehe 13_app_reports.sql). Enthält
# Personendaten: nur in Metabase, auf keinem Board.
KLAER = "Gestörte Abos – Klärliste"
KLAER_SQL = """SELECT klaerung AS "Klärung", abo_code AS "Abo-Code", produkt AS "Produkt",
       fahrgast AS "Fahrgast", geburtsdatum AS "Geburtsdatum Fahrgast",
       kunde_email AS "E-Mail Konto", kontoinhaber AS "Kontoinhaber", konto_vorhanden AS "Konto vorhanden",
       laeuft_seit AS "Läuft seit", letzte_abrechnung AS "Letzte Abrechnung", stillgelegt_am AS "Stillgelegt am",
       ticket_im_monat AS "Ticket im Monat", ticket_vormonat AS "Ticket im Vormonat",
       berechtigt_im_monat AS "Berechtigt im Monat", bestandsmonat AS "Bestandsmonat"
FROM rpt.abo_stoerung
ORDER BY klaerung_nr = 4 DESC, klaerung_nr, "E-Mail Konto", "Fahrgast\""""
def liste_sichern(name, sql, beschreibung, datumsspalten=()):
    """Gespeicherte Liste mit Personendaten: in der Sammlung, auf keinem Board.
    Die Boards (14_dashboards.py) verlinken per Klick hierher."""
    alt = next((c for c in call(f"/api/collection/{COLL}/items?models=card")["data"]
                if c["name"] == name), None)
    karte = {"name": name, "collection_id": COLL, "display": "table",
             "description": beschreibung + " Enthält Personendaten — nicht weitergeben, nicht einbetten.",
             "dataset_query": {"type": "native", "database": db_id, "native": {"query": sql}},
             "visualization_settings": {"column_settings": {
                 json.dumps(["name", n], separators=(",", ":")): DAT for n in datumsspalten}}}
    if alt:
        call(f"/api/card/{alt['id']}", karte, m="PUT"); return alt["id"]
    return call("/api/card", karte)["id"]

kid = liste_sichern(KLAER, KLAER_SQL,
    "Jedes als gestört markierte (stillgelegte) Abo mit Klärung über den Fahrgast. "
    "Handlungsbedarf nur bei „offen“.",
    ("Läuft seit", "Letzte Abrechnung", "Stillgelegt am", "Bestandsmonat"))
liste_sichern("Gestörte Abos, offen – Liste",
    KLAER_SQL.replace("FROM rpt.abo_stoerung\n", "FROM rpt.abo_stoerung\nWHERE klaerung_nr = 4\n"),
    "Stillgelegte Abos, deren Fahrgast berechtigt ist, aber weder Abo noch Ticket hat: "
    "die Fälle für den Service.",
    ("Läuft seit", "Letzte Abrechnung", "Stillgelegt am", "Bestandsmonat"))
liste_sichern("Konten ohne Ticket – Liste",
    """SELECT fall AS "Fall", kunde_email AS "E-Mail", kontoinhaber AS "Kontoinhaber",
       segment AS "Ticket", plz AS "PLZ", ort AS "Ort", altersgruppe AS "Altersgruppe",
       registriert_am AS "Konto angelegt", tage_seit_anlage AS "Tage seit Anlage",
       ovs_verknuepft AS "Mit Abo-Kundenkonto verknüpft", bestellungen AS "Bestellungen",
       abo_stillgelegt AS "Abo stillgelegt", ticket_vormonat AS "Ticket im Vormonat",
       coalesce(plattform, '–') AS "Plattform (aus Bestellungen)"
FROM rpt.konto_ohne_ticket
ORDER BY fall_nr, registriert_am, kunde_email""",
    "Berechtigte mit App-Konto, aber ohne Ticket im laufenden Monat. Meist ist das Konto mit "
    "dem Abo-Kundenkonto verknüpft, das Ticket aber nie angefordert.",
    ("Konto angelegt",))

def klaerliste(formatiert=False):
    daten = {"format_rows": "true"} if formatiert else {}
    r = urllib.request.Request(f"{BASE}/api/card/{kid}/query/csv", method="POST",
        data=urllib.parse.urlencode(daten).encode(), headers={"X-Metabase-Session": tok})
    with urllib.request.urlopen(r, timeout=600) as x:
        text = x.read().decode("utf-8-sig")
    if not text.startswith("Klärung,"):
        raise SystemExit(f"Abfrage fehlgeschlagen: {text[:250]}")
    return list(csv.reader(io.StringIO(text)))

tickets = args.ticket or TICKETS
if args.csv and args.stoerung:
    zeilen = klaerliste(formatiert=True)
    if args.stoerung == "offen":
        zeilen = zeilen[:1] + [z for z in zeilen[1:] if z[0].startswith("offen")]
    csv.writer(sys.stdout, lineterminator="\n").writerows(zeilen)
    melden(f"  {len(zeilen) - 1} gestörte Abos ({args.stoerung})")
elif args.csv:
    text = liste(tickets, args.monat, args.versendet, formatiert=True)
    sys.stdout.write(text)
    melden(f"  {len(list(csv.reader(io.StringIO(text)))) - 1} Personen "
           f"(Ticket {' oder '.join(tickets)}, Monat {args.monat}, versendet: {args.versendet or 'alle'})")
else:
    zaehlen = lambda v=None: len(list(csv.reader(io.StringIO(liste(tickets, args.monat, v))))) - 1
    melden(f"  {zaehlen()} Personen mit Ticket {' oder '.join(tickets)}")
    melden(f"  davon mit versendetem Ticket ({args.monat}): {zaehlen('ja')}, ohne: {zaehlen('nein')}")
    melden(f"  Öffnen: {BASE}/question/{cid}")
    stand = {}
    for z in klaerliste()[1:]: stand[z[0]] = stand.get(z[0], 0) + 1
    melden(f"{KLAER} (ID {kid}): " + ", ".join(f"{n} {k}" for k, n in sorted(stand.items())))
