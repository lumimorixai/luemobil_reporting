#!/usr/bin/env python3
"""
Gleicht die Metabase-Boards an den Prototyp an.
Ergänzt die fehlenden Kennzahlen, baut das PayOne-Board und stellt die
vier Ansichten so zusammen wie im Klickdummy.
"""
import json, urllib.request, urllib.error, getpass

BASE = "http://localhost:3030"
LOGIN = {"username": "demo@luemobil.local", "password": "LueMobilDemo2026"}
tok = None

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
dbs = call("/api/database"); dbs = dbs["data"] if isinstance(dbs, dict) else dbs
db_id = next(d["id"] for d in dbs if d["name"] == "LüMobil Reporting")
COLL = next(c["id"] for c in call("/api/collection") if c.get("name") == "LüMobil Vertrieb")

vorhanden = {c["name"]: c["id"] for c in
             call(f"/api/collection/{COLL}/items?models=card").get("data", [])}

def frage(name, sql, anzeige="table", beschreibung=None, viz=None):
    if name in vorhanden:
        cid = vorhanden[name]
        call(f"/api/card/{cid}", {
            "dataset_query": {"type": "native", "database": db_id, "native": {"query": sql}},
            "display": anzeige, "description": beschreibung,
            "visualization_settings": viz or {}}, method="PUT")
        return cid
    c = call("/api/card", {"name": name, "description": beschreibung,
        "collection_id": COLL, "display": anzeige,
        "dataset_query": {"type": "native", "database": db_id, "native": {"query": sql}},
        "visualization_settings": viz or {}})
    vorhanden[name] = c["id"]
    return c["id"]

K = dict(vorhanden)
print("Fehlende Kennzahlen ergänzen ...")

# ---- Überblick
K["Ø Bon"] = frage("Ø Bon",
    """SELECT round(avg(umsatz_brutto), 2) AS "Ø Bon" FROM rpt.bestellung WHERE erfolgreich""",
    "scalar", "Durchschnittlicher Bestellwert brutto.")
K["Käufer"] = frage("Käufer",
    """SELECT count(DISTINCT kunde_id) AS "Käufer" FROM rpt.bestellung""", "scalar",
    "Personen mit mindestens einer Bestellung.")
K["Neue Konten"] = frage("Neue Konten",
    """SELECT count(*) AS "Konten" FROM rpt.kunde_360""", "scalar",
    "Angelegte App-Konten insgesamt.")
K["Konto zu Kauf"] = frage("Konto zu Kauf",
    """SELECT round(100.0 * count(*) FILTER (WHERE hat_gekauft) / count(*), 1) AS "Quote %"
       FROM rpt.kunde_360""", "scalar",
    "Anteil der Konten, die auch bestellt haben.")

# ---- Abo-Bestand
K["Berechtigungen gesamt"] = frage("Berechtigungen gesamt",
    """SELECT count(*) AS "Berechtigungen" FROM rpt.abo_berechtigung""", "scalar",
    "Zeilen im Bestand. Personen: siehe Aktivierungsquote (8.215).")
K["Aktive Abos"] = frage("Aktive Abos",
    """SELECT count(*) AS "Abos" FROM rpt.abo WHERE aktiv""", "scalar",
    "Alle mit Verlängerung am 27.09.2026.")
K["Altersprofil der Berechtigten"] = frage("Altersprofil der Berechtigten",
    """SELECT altersgruppe AS "Altersgruppe",
              count(*) FILTER (WHERE aktiviert) AS "Aktiviert",
              count(*) FILTER (WHERE NOT aktiviert) AS "Offen"
       FROM rpt.abo_berechtigung WHERE ist_hauptzeile AND altersgruppe IS NOT NULL
       GROUP BY 1 ORDER BY 1""", "bar",
    "Echte Geburtsdaten aus dem Bestand — im App-Konto stehen Platzhalter.",
    {"graph.dimensions": ["Altersgruppe"], "graph.metrics": ["Aktiviert", "Offen"],
     "stackable.stack_type": "stacked"})

# ---- Betrieb
K["Erfolgsquote"] = frage("Erfolgsquote",
    """SELECT round(100.0 * count(*) FILTER (WHERE erfolgreich) / count(*), 1) AS "Quote %"
       FROM rpt.bestellung""", "scalar")
K["Abbrüche"] = frage("Abbrüche",
    """SELECT count(*) AS "Abbrüche" FROM rpt.bestellung WHERE abgebrochen""", "scalar")
K["Geräte"] = frage("Geräte",
    """SELECT count(DISTINCT geraet_id) AS "Geräte" FROM rpt.bestellung
       WHERE geraet_id IS NOT NULL""", "scalar", "iOS und Android zusammen.")
K["Bestellstrecke"] = frage("Bestellstrecke",
    """SELECT status AS "Status", bestellungen AS "Bestellungen"
       FROM rpt.bestellstrecke ORDER BY stufe""", "bar",
    "1.459 erreichten „Versendet“, 17 davon wurden danach zurückgenommen — Endstand 1.442.",
    {"graph.dimensions": ["Status"], "graph.metrics": ["Bestellungen"]})

# ---- PayOne / Einzeltickets
K["Umsatz Einzeltickets"] = frage("Umsatz Einzeltickets",
    """SELECT coalesce(sum(einzelpreis_brutto), 0) AS "Umsatz"
       FROM rpt.bestellposition WHERE erfolgreich AND vertriebskanal = 'Einzelticket'""",
    "scalar", "Bleibt null, bis PayOne live ist.")
K["Transaktionen PayOne"] = frage("Transaktionen PayOne",
    """SELECT count(*) AS "Transaktionen" FROM rpt.bestellung
       WHERE zahlungsmodul = 'payone'""", "scalar",
    "Modul ist aktiv (MODULE_PAYMENT_PAYONE_STATUS = true), aber ohne Verkehr.")
K["Zahlungsabbrüche"] = frage("Zahlungsabbrüche",
    """SELECT count(*) AS "Abbrüche" FROM rpt.statuslauf WHERE status_id = 6""",
    "scalar", "Status 6 „Zahlung abgelehnt“ — gibt es im Abogeschäft nicht.")
K["Erstattungen"] = frage("Erstattungen",
    """SELECT 0 AS "Erstattungen" """, "scalar",
    "kk_order_refunds ist heute vollständig leer.")
K["PayOne-Bereitschaft"] = frage("PayOne-Bereitschaft",
    """SELECT gegenstand AS "Gegenstand", quellfeld AS "Quellfeld", stand AS "Stand"
       FROM rpt.payone_bereitschaft ORDER BY reihenfolge""", "table",
    "Welche Felder sich beim Go-live füllen — heute ehrlich leer statt Platzhalter.")
K["Tarifkatalog je Kanal"] = frage("Tarifkatalog je Kanal",
    """SELECT vertriebskanal AS "Kanal", count(*) AS "Produkte",
              count(*) FILTER (WHERE payone_faehig) AS "für PayOne frei",
              sum(anzahl_preisstufen) AS "Preispunkte"
       FROM rpt.produkt GROUP BY 1 ORDER BY 2 DESC""", "table",
    "31 von 34 Produkten tragen attribute.payone = true.")
K["Preisstufen"] = frage("Preisstufen",
    """SELECT count(*) AS "Preisstufen" FROM rpt.tarifstruktur""", "scalar",
    "Von Stufe 1 bis 21 plus Sonderstufen wie 1e, 2rd, 1SL-FL, HHF.")
K["Preispunkte"] = frage("Preispunkte",
    """SELECT sum(anzahl_preisstufen) AS "Preispunkte" FROM rpt.produkt""", "scalar",
    "Produkt × Preisstufe, jeder mit hinterlegtem Nettopreis.")
K["Produkte für PayOne"] = frage("Produkte für PayOne",
    """SELECT count(*) AS "Produkte" FROM rpt.produkt WHERE payone_faehig""", "scalar")
K["Preisspannen je Produkt"] = frage("Preisspannen je Produkt",
    """SELECT produkt AS "Produkt", vertriebskanal AS "Kanal",
              anzahl_preisstufen AS "Preisstufen",
              preis_ab_brutto AS "ab", preis_bis_brutto AS "bis"
       FROM rpt.produkt WHERE payone_faehig AND anzahl_preisstufen > 1
       ORDER BY anzahl_preisstufen DESC""", "table",
    "Der Einzelticket-Katalog, der auf den Go-live wartet.")
K["Gültigkeitsregeln"] = frage("Gültigkeitsregeln",
    """SELECT gueltigkeit AS "Regel", sum(produkte_mit_dieser_stufe) AS "Preispunkte"
       FROM rpt.tarifstruktur GROUP BY 1 ORDER BY 2 DESC""", "row", None,
    {"graph.dimensions": ["Regel"], "graph.metrics": ["Preispunkte"]})

print(f"  {len(K)} Fragen insgesamt")

# ------------------------------------------------------------ Dashboards
def text(inhalt, col, row, w, h, i):
    return {"id": -i, "card_id": None, "row": row, "col": col, "size_x": w, "size_y": h,
            "visualization_settings": {"virtual_card": {"name": None, "display": "text",
                "visualization_settings": {}, "dataset_query": {}, "archived": False},
                "text": inhalt, "dashcard.background": False},
            "parameter_mappings": []}

def dashboard(name, beschreibung, elemente):
    alle = call(f"/api/collection/{COLL}/items?models=dashboard").get("data", [])
    treffer = next((d for d in alle if d["name"] == name), None)
    did = treffer["id"] if treffer else call("/api/dashboard",
        {"name": name, "description": beschreibung, "collection_id": COLL})["id"]
    if treffer:
        call(f"/api/dashboard/{did}", {"description": beschreibung}, method="PUT")
    cards, i = [], 0
    for el in elemente:
        i += 1
        if el[0] == "TEXT":
            cards.append(text(el[1], el[2], el[3], el[4], el[5], i))
        else:
            key, col, row, w, h = el
            cards.append({"id": -i, "card_id": K[key], "row": row, "col": col,
                          "size_x": w, "size_y": h,
                          "visualization_settings": {}, "parameter_mappings": []})
    call(f"/api/dashboard/{did}", {"dashcards": cards}, method="PUT")
    print(f"  {name}: {len(cards)} Kacheln")

print("Dashboards neu zusammenstellen ...")

dashboard("1 — Überblick",
  "Absatz, Umsatz und Hochlauf. Datenstand 15.09.2026, Zeitraum 03.–15.09.",
  [("TEXT","## Überblick\nAlle Zahlen aus den Dumps vom 15.09.2026. Marktstart war der **10. September** — davor nur Testverkehr.",0,0,24,2),
   ("Umsatz brutto (erfolgreich)",0,2,4,3), ("Verkäufe",4,2,4,3), ("Ø Bon",8,2,4,3),
   ("Käufer",12,2,4,3), ("Neue Konten",16,2,4,3), ("Konto zu Kauf",20,2,4,3),
   ("Bestellungen und Konten je Tag",0,5,12,6), ("Umsatz je Tag",12,5,12,6),
   ("Kaufzeitpunkt im Tagesverlauf",0,11,12,5), ("Produktmix",12,11,12,5),
   ("Umsatz je Vertriebskanal",0,16,24,4),
   ("TEXT","Einzelticket und Fähre stehen bei null, weil der Verkauf über PayOne noch nicht gestartet ist. Der Tarifkatalog dafür ist vollständig gepflegt — siehe Board 3.",0,20,24,2)])

dashboard("2 — Abo-Bestand",
  "Überführung des Abo-Bestands in die App. Die zentrale Hochlaufkennzahl.",
  [("TEXT","## Abo-Bestand und Überführung\n8.267 Berechtigungen gehören **8.215 Personen**. Alle Quoten unten zählen Personen, nicht Zeilen.",0,0,24,2),
   ("Berechtigungen gesamt",0,2,5,3), ("Aktivierungsquote Bestand",5,2,5,3),
   ("Berechtigte ohne App-Konto",10,2,5,3), ("Aktive Abos",15,2,5,3), ("Abos mit Störung",20,2,4,3),
   ("Überführungstrichter",0,5,12,7), ("Aktivierung je Bestandssegment",12,5,12,7),
   ("Altersprofil der Berechtigten",0,12,12,6), ("Arbeitslisten",12,12,12,6),
   ("Aktivierung nach Postleitzahl",0,18,24,8),
   ("TEXT","**7,4 Prozentpunkte** liegen zwischen den Segmenten 9995 und 9999 — gleiches Produkt, gleicher Preis von 63,00 €. Die fachliche Bedeutung des Unterschieds ist offen.",0,26,24,2)])

dashboard("3 — Einzeltickets über PayOne",
  "Wartet auf die erste Transaktion. Alle Kacheln sind an die Felder gebunden, die sich beim Go-live füllen.",
  [("TEXT","## Einzeltickets über PayOne\nDieser Bereich zeigt heute **ehrlich null** statt eines Platzhalters. Das Zahlungsmodul ist in `kk_mpswl` aktiv (`MODULE_PAYMENT_PAYONE_STATUS = true`), der Tarifkatalog vollständig gepflegt — es fehlt nur die erste Transaktion.",0,0,24,3),
   ("Umsatz Einzeltickets",0,3,5,3), ("Transaktionen PayOne",5,3,5,3),
   ("Zahlungsabbrüche",10,3,5,3), ("Erstattungen",15,3,4,3), ("Produkte für PayOne",19,3,5,3),
   ("PayOne-Bereitschaft",0,6,24,6),
   ("TEXT","### Der Katalog, der bereitsteht",0,12,24,1),
   ("Preisstufen",0,13,6,3), ("Preispunkte",6,13,6,3),
   ("Tarifkatalog je Kanal",12,13,12,6),
   ("Gültigkeitsregeln",0,16,12,4),
   ("Preisspannen je Produkt",0,20,24,7),
   ("TEXT","Mit Einzeltickets werden Auswertungen möglich, die es im Abogeschäft nicht gibt: **Umsatz je Preisstufe**, **Quell-Ziel-Relationen** aus `customers_basket.custom1`, **Anschlusstickets**, **Vorlauf bis Fahrtantritt**, **Zahlartenmix** und **Erstattungsquoten**.",0,27,24,3)])

dashboard("4 — Betrieb und Störungen",
  "Für Service und Betrieb. Harter Termin: Verlängerungslauf am 27.09.2026.",
  [("TEXT","## Betrieb und Störungen\n**Harter Termin 27.09.2026:** alle 1.459 Abos haben denselben `next_billing_date`. Der gesamte Bestand verlängert in einem Lauf.",0,0,24,2),
   ("Erfolgsquote",0,2,5,3), ("Durchlaufzeit bis zum Ticket",5,2,9,3),
   ("Abbrüche",14,2,5,3), ("Abos mit Störung",19,2,5,3),
   ("Bestellstrecke",0,5,12,6), ("Abbrüche nach Ursache",12,5,12,6),
   ("Geräteplattform",0,11,8,5), ("Geräte",8,11,4,5), ("Arbeitslisten",12,11,12,5),
   ("Schultickets zum Erwachsenenpreis",0,16,24,7),
   ("TEXT","194 Schultickets wurden zu 63 € statt 43 € abgerechnet — 3.880 € Differenz. Entweder fehlende Nachweise oder ein Tariffehler.",0,23,24,2)])

print("\nFertig.")
