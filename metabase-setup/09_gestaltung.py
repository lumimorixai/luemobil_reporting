#!/usr/bin/env python3
"""
Gestaltung der Metabase-Boards nach dem Prototyp.

Was in der Open-Source-Ausgabe möglich ist: Zahlenformate, Diagrammfarben,
Mini-Balken, bedingte Formatierung, Layout, Überschriften.
Nicht möglich: Markenfarbe, Logo und Schriftart der Oberfläche selbst
(das ist die Funktion "whitelabel" der kostenpflichtigen Ausgabe).
"""
import json, urllib.request, urllib.error

BASE  = "http://localhost:3030"
LOGIN = {"username": "demo@luemobil.local", "password": "LueMobilDemo2026"}
tok = None

# Palette aus dem Prototyp
TEAL, BLAU, GRUEN, AMBER, ROT, GUT, GRAU = (
    "#0F6F7E", "#2E5F92", "#4A7A63", "#8A5C0D", "#A63A33", "#2C7A5B", "#8E9EA4")

def call(path, data=None, method=None):
    req = urllib.request.Request(BASE + path,
        data=json.dumps(data).encode() if data is not None else None,
        method=method or ("POST" if data is not None else "GET"))
    req.add_header("Content-Type", "application/json")
    if tok: req.add_header("X-Metabase-Session", tok)
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method or 'GET'} {path} -> {e.code}: {e.read().decode()[:300]}")

tok = call("/api/session", LOGIN)["id"]

# ---------------------------------------------------- globale Formatierung
print("Globale Zahlenformate setzen ...")
call("/api/setting/custom-formatting", {"value": {
    "type/Temporal": {"date_style": "D.M.YYYY", "date_separator": "."},
    "type/Number":   {"number_separators": ",."},
    "type/Currency": {"currency": "EUR", "currency_style": "symbol",
                      "currency_in_header": False},
}}, method="PUT")
call("/api/setting/site-locale", {"value": "de"}, method="PUT")
call("/api/setting/start-of-week", {"value": "monday"}, method="PUT")
print("  erledigt")

COLL = next(c["id"] for c in call("/api/collection") if c.get("name") == "LüMobil Vertrieb")
karten = {c["name"]: c["id"] for c in
          call(f"/api/collection/{COLL}/items?models=card").get("data", [])}

def spalte(name, **opts):
    return (json.dumps(["name", name], separators=(",", ":")), opts)

def stil(kartenname, display=None, **viz):
    """Setzt Darstellung und Visualisierung einer Karte."""
    cid = karten.get(kartenname)
    if not cid:
        print(f"  fehlt: {kartenname}"); return
    card = call(f"/api/card/{cid}")
    vs = dict(card.get("visualization_settings") or {})
    cols = viz.pop("_spalten", None)
    if cols:
        cs = dict(vs.get("column_settings") or {})
        for key, opts in cols:
            cs[key] = {**(cs.get(key) or {}), **opts}
        vs["column_settings"] = cs
    vs.update(viz)
    payload = {"visualization_settings": vs}
    if display: payload["display"] = display
    call(f"/api/card/{cid}", payload, method="PUT")
    print(f"  {kartenname}")

EURO   = {"number_style": "currency", "currency": "EUR",
          "currency_style": "symbol", "decimals": 0, "number_separators": ",."}
EURO2  = {**EURO, "decimals": 2}
PROZ   = {"number_style": "percent", "decimals": 1, "scale": 0.01}
GANZ   = {"number_style": "decimal", "decimals": 0, "number_separators": ",."}
SEK    = {"number_style": "decimal", "decimals": 2, "suffix": " s"}

print("\nKennzahlen formatieren ...")
stil("Umsatz brutto (erfolgreich)", _spalten=[spalte("Umsatz brutto", **EURO)])
stil("Ø Bon",                        _spalten=[spalte("Ø Bon", **EURO2)])
stil("Verkäufe",                     _spalten=[spalte("Verkäufe", **GANZ)])
stil("Käufer",                       _spalten=[spalte("Käufer", **GANZ)])
stil("Neue Konten",                  _spalten=[spalte("Konten", **GANZ)])
stil("Konto zu Kauf",                _spalten=[spalte("Quote %", **PROZ)])
stil("Aktivierungsquote Bestand",    _spalten=[spalte("Quote %", **PROZ)])
stil("Erfolgsquote",                 _spalten=[spalte("Quote %", **PROZ)])
stil("Berechtigungen gesamt",        _spalten=[spalte("Berechtigungen", **GANZ)])
stil("Berechtigte ohne App-Konto",   _spalten=[spalte("Offen", **GANZ)])
stil("Aktive Abos",                  _spalten=[spalte("Abos", **GANZ)])
stil("Abos mit Störung",             _spalten=[spalte("Störungen", **GANZ)])
stil("Abbrüche",                     _spalten=[spalte("Abbrüche", **GANZ)])
stil("Geräte",                       _spalten=[spalte("Geräte", **GANZ)])
stil("Preisstufen",                  _spalten=[spalte("Preisstufen", **GANZ)])
stil("Preispunkte",                  _spalten=[spalte("Preispunkte", **GANZ)])
stil("Produkte für PayOne",          _spalten=[spalte("Produkte", **GANZ)])
stil("Umsatz Einzeltickets",         _spalten=[spalte("Umsatz", **EURO)])
stil("Transaktionen PayOne",         _spalten=[spalte("Transaktionen", **GANZ)])
stil("Zahlungsabbrüche",             _spalten=[spalte("Abbrüche", **GANZ)])
stil("Erstattungen",                 _spalten=[spalte("Erstattungen", **GANZ)])

print("\nDiagramme einfärben ...")
stil("Bestellungen und Konten je Tag", "combo",
     _spalten=[spalte("Bestellungen", **GANZ), spalte("Neue Konten", **GANZ)],
     **{"graph.dimensions": ["Tag"], "graph.metrics": ["Bestellungen", "Neue Konten"],
        "series_settings": {"Bestellungen": {"color": TEAL, "display": "bar"},
                            "Neue Konten": {"color": AMBER, "display": "line",
                                            "axis": "right", "line.marker_enabled": True}},
        "graph.x_axis.title_text": "September 2026",
        "graph.y_axis.title_text": "Bestellungen",
        "graph.show_values": False, "graph.label_value_formatting": "auto"})

stil("Umsatz je Tag", "bar",
     _spalten=[spalte("Umsatz brutto", **EURO)],
     **{"graph.dimensions": ["Tag"], "graph.metrics": ["Umsatz brutto"],
        "series_settings": {"Umsatz brutto": {"color": TEAL}},
        "graph.y_axis.title_text": "Umsatz brutto",
        "graph.x_axis.title_text": "September 2026"})

stil("Kaufzeitpunkt im Tagesverlauf", "bar",
     **{"graph.dimensions": ["Stunde"], "graph.metrics": ["Käufe"],
        "series_settings": {"Käufe": {"color": TEAL}},
        "graph.x_axis.title_text": "Stunde", "graph.y_axis.title_text": "Käufe"})

stil("Produktmix", "bar",
     _spalten=[spalte("Umsatz brutto", **EURO), spalte("Stück", **GANZ)],
     **{"graph.dimensions": ["Produkt"], "graph.metrics": ["Stück"],
        "series_settings": {"Stück": {"color": TEAL}},
        "graph.show_values": True})

stil("Umsatz je Vertriebskanal", "row",
     _spalten=[spalte("Umsatz brutto", **EURO), spalte("Verkäufe", **GANZ)],
     **{"graph.dimensions": ["Kanal"], "graph.metrics": ["Umsatz brutto"],
        "series_settings": {"Umsatz brutto": {"color": TEAL}},
        "graph.show_values": True})

stil("Aktivierung je Bestandssegment", "bar",
     _spalten=[spalte("Quote %", **PROZ), spalte("Berechtigte", **GANZ)],
     **{"graph.dimensions": ["Segment"], "graph.metrics": ["Quote %"],
        "series_settings": {"Quote %": {"color": TEAL}},
        "graph.show_values": True, "graph.y_axis.title_text": "Aktivierungsquote"})

stil("Altersprofil der Berechtigten", "bar",
     _spalten=[spalte("Aktiviert", **GANZ), spalte("Offen", **GANZ)],
     **{"graph.dimensions": ["Altersgruppe"], "graph.metrics": ["Aktiviert", "Offen"],
        "series_settings": {"Aktiviert": {"color": GUT}, "Offen": {"color": GRAU}},
        "stackable.stack_type": "stacked"})

stil("Bestellstrecke", "bar",
     _spalten=[spalte("Bestellungen", **GANZ)],
     **{"graph.dimensions": ["Status"], "graph.metrics": ["Bestellungen"],
        "series_settings": {"Bestellungen": {"color": TEAL}},
        "graph.show_values": True})

stil("Abbrüche nach Ursache", "row",
     _spalten=[spalte("Fälle", **GANZ)],
     **{"graph.dimensions": ["Ursache"], "graph.metrics": ["Fälle"],
        "series_settings": {"Fälle": {"color": ROT}},
        "graph.show_values": True})

stil("Geräteplattform", "pie",
     **{"pie.dimension": "Plattform", "pie.metric": "Geräte",
        "pie.colors": {"iOS": TEAL, "Android": BLAU},
        "pie.show_legend": True, "pie.percent_visibility": "inside"})

stil("Gültigkeitsregeln", "row",
     _spalten=[spalte("Preispunkte", **GANZ)],
     **{"graph.dimensions": ["Regel"], "graph.metrics": ["Preispunkte"],
        "series_settings": {"Preispunkte": {"color": BLAU}},
        "graph.show_values": True})

stil("Überführungstrichter", "funnel",
     **{"funnel.dimension": "Schritt", "funnel.metric": "Personen",
        "funnel.type": "funnel"})

print("\nTabellen gestalten ...")
stil("Aktivierung nach Postleitzahl", "table",
     _spalten=[spalte("Berechtigte", show_mini_bar=True, **GANZ),
               spalte("Aktivierte", **GANZ),
               spalte("Offen", show_mini_bar=True, **GANZ),
               spalte("Quote %", **PROZ)],
     **{"table.column_formatting": [
          {"columns": ["Quote %"], "type": "range", "colors": ["#F5DEDB", "#DCEDE4"],
           "min_type": "custom", "max_type": "custom", "min_value": 15, "max_value": 27}]})

stil("Arbeitslisten", "table",
     _spalten=[spalte("Fälle", show_mini_bar=True, **GANZ)])

stil("Tarifkatalog je Kanal", "table",
     _spalten=[spalte("Produkte", **GANZ), spalte("für PayOne frei", **GANZ),
               spalte("Preispunkte", show_mini_bar=True, **GANZ)])

stil("Preisspannen je Produkt", "table",
     _spalten=[spalte("Preisstufen", show_mini_bar=True, **GANZ),
               spalte("ab", **EURO2), spalte("bis", **EURO2)])

stil("PayOne-Bereitschaft", "table",
     **{"table.column_formatting": [
          {"columns": ["Stand"], "type": "single", "operator": "contains",
           "value": "bereit", "color": "#2C7A5B", "highlight_row": False}]})

stil("Durchlaufzeit bis zum Ticket", "table",
     _spalten=[spalte("Median s", **SEK), spalte("p95 s", **SEK), spalte("Maximum s", **SEK)])

stil("Schultickets zum Erwachsenenpreis", "table",
     _spalten=[spalte("Preis brutto", **EURO2)])

print("\nDashboards auf volle Breite ...")
for d in call(f"/api/collection/{COLL}/items?models=dashboard").get("data", []):
    call(f"/api/dashboard/{d['id']}", {"width": "full"}, method="PUT")
    print(f"  {d['name']}")

print("\nFertig.")
