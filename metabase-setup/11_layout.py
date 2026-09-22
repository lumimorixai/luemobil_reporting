#!/usr/bin/env python3
"""Raster der Boards sauber setzen (Metabase rechnet mit 24 Spalten)."""
import json, urllib.request, urllib.error
BASE="http://localhost:3030"; tok=None
def call(p,d=None,m=None):
    r=urllib.request.Request(BASE+p,data=json.dumps(d).encode() if d is not None else None,
        method=m or ("POST" if d is not None else "GET"))
    r.add_header("Content-Type","application/json")
    if tok: r.add_header("X-Metabase-Session",tok)
    try:
        with urllib.request.urlopen(r,timeout=180) as x:
            raw=x.read().decode(); return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{p} -> {e.code}: {e.read().decode()[:250]}")
tok=call("/api/session",{"username":"demo@luemobil.local","password":"LueMobilDemo2026"})["id"]
COLL=next(c["id"] for c in call("/api/collection") if c.get("name")=="LüMobil Vertrieb")
K={c["name"]:c["id"] for c in call(f"/api/collection/{COLL}/items?models=card")["data"]}

# Datumsformat: D/M/YYYY mit Punkt als Trenner ergibt 3.9.2026
DAT={"date_style":"D/M/YYYY","date_separator":".","date_abbreviate":False}
sp=lambda n,**o:(json.dumps(["name",n],separators=(",",":")),o)
def datum(karte,spalte):
    cid=K.get(karte)
    if not cid: return
    c=call(f"/api/card/{cid}"); vs=dict(c.get("visualization_settings") or {})
    cs=dict(vs.get("column_settings") or {})
    key=json.dumps(["name",spalte],separators=(",",":"))
    cs[key]={**(cs.get(key) or {}),**DAT}
    vs["column_settings"]=cs
    call(f"/api/card/{cid}",{"visualization_settings":vs},m="PUT"); print("  Datum:",karte)

print("Datumsformat setzen ...")
datum("Bestellungen und Konten je Tag","Tag")
datum("Umsatz je Tag","Tag")
datum("Schultickets zum Erwachsenenpreis","Kauftag")

def text(inhalt,col,row,w,h,i):
    return {"id":-i,"card_id":None,"row":row,"col":col,"size_x":w,"size_y":h,
            "visualization_settings":{"virtual_card":{"name":None,"display":"text",
                "visualization_settings":{},"dataset_query":{},"archived":False},
                "text":inhalt,"dashcard.background":False},
            "parameter_mappings":[]}

def baue(name,beschreibung,elemente):
    d=next(x for x in call(f"/api/collection/{COLL}/items?models=dashboard")["data"]
           if x["name"]==name)
    cards=[];i=0
    for el in elemente:
        i+=1
        if el[0]=="TEXT": cards.append(text(el[1],el[2],el[3],el[4],el[5],i))
        else:
            k,col,row,w,h=el
            cards.append({"id":-i,"card_id":K[k],"row":row,"col":col,"size_x":w,"size_y":h,
                          "visualization_settings":{},"parameter_mappings":[]})
    call(f"/api/dashboard/{d['id']}",{"dashcards":cards,"description":beschreibung},m="PUT")
    breiten={}
    for c in cards: breiten.setdefault(c["row"],0); breiten[c["row"]]+=c["size_x"]
    schief=[r for r,b in breiten.items() if b>24]
    print(f"  {name}: {len(cards)} Kacheln" + (f"  ACHTUNG Zeilen zu breit: {schief}" if schief else "  Raster ok"))

print("\nBoards neu setzen ...")

baue("1 — Überblick","Absatz, Umsatz und Hochlauf. Datenstand 15.09.2026, Zeitraum 03.–15.09.",
 [("TEXT","## Überblick\nAlle Zahlen aus den Dumps vom 15.09.2026. Marktstart war der **10. September** — davor nur Testverkehr.",0,0,24,2),
  ("Umsatz brutto",0,2,4,3),("Verkäufe",4,2,4,3),("Ø Bon",8,2,4,3),
  ("Käufer",12,2,4,3),("Neue Konten",16,2,4,3),("Konto zu Kauf",20,2,4,3),
  ("Bestellungen und Konten je Tag",0,5,12,7),("Umsatz je Tag",12,5,12,7),
  ("Kaufzeitpunkt im Tagesverlauf",0,12,12,6),("Produktmix",12,12,12,6),
  ("Umsatz je Vertriebskanal",0,18,24,4),
  ("TEXT","Einzelticket und Fähre stehen bei null, weil der Verkauf über PayOne noch nicht gestartet ist. Der Tarifkatalog dafür ist vollständig gepflegt — siehe Board 3.",0,22,24,2)])

baue("2 — Abo-Bestand","Überführung des Abo-Bestands in die App. Die zentrale Hochlaufkennzahl.",
 [("TEXT","## Abo-Bestand und Überführung\n8.267 Berechtigungen gehören **8.215 Personen**. Alle Quoten zählen Personen, nicht Zeilen.",0,0,24,2),
  ("Berechtigungen gesamt",0,2,5,3),("Aktivierungsquote Bestand",5,2,5,3),
  ("Berechtigte ohne App-Konto",10,2,5,3),("Aktive Abos",15,2,5,3),("Abos mit Störung",20,2,4,3),
  ("Überführungstrichter",0,5,12,7),("Aktivierung je Bestandssegment",12,5,12,7),
  ("Altersprofil der Berechtigten",0,12,12,6),("Arbeitslisten",12,12,12,6),
  ("Aktivierung nach Postleitzahl",0,18,24,9),
  ("TEXT","**7,4 Prozentpunkte** liegen zwischen den Segmenten 9995 und 9999 — gleiches Produkt, gleicher Preis von 63,00 €. Die fachliche Bedeutung des Unterschieds ist offen.",0,27,24,2)])

baue("3 — Einzeltickets über PayOne","Wartet auf die erste Transaktion. Alle Kacheln sind an die Felder gebunden, die sich beim Go-live füllen.",
 [("TEXT","## Einzeltickets über PayOne\nDieser Bereich zeigt heute **ehrlich null** statt eines Platzhalters. Das Zahlungsmodul ist in `kk_mpswl` aktiv, der Tarifkatalog vollständig gepflegt — es fehlt nur die erste Transaktion.",0,0,24,3),
  ("Umsatz Einzeltickets",0,3,5,3),("Transaktionen PayOne",5,3,5,3),
  ("Zahlungsabbrüche",10,3,5,3),("Erstattungen",15,3,4,3),("Produkte für PayOne",19,3,5,3),
  ("PayOne-Bereitschaft",0,6,24,7),
  ("TEXT","### Der Tarifkatalog, der bereitsteht",0,13,24,1),
  ("Preisstufen",0,14,6,3),("Preispunkte",6,14,6,3),("Tarifkatalog je Kanal",12,14,12,6),
  ("Gültigkeitsregeln",0,17,12,3),
  ("Preisspannen je Produkt",0,20,24,8),
  ("TEXT","Mit Einzeltickets werden Auswertungen möglich, die es im Abogeschäft nicht gibt: **Umsatz je Preisstufe**, **Quell-Ziel-Relationen** aus `customers_basket.custom1`, **Anschlusstickets**, **Vorlauf bis Fahrtantritt**, **Zahlartenmix** und **Erstattungsquoten**.",0,28,24,3)])

baue("4 — Betrieb und Störungen","Für Service und Betrieb. Harter Termin: Verlängerungslauf am 27.09.2026.",
 [("TEXT","## Betrieb und Störungen\n**Harter Termin 27.09.2026:** alle 1.459 Abos haben denselben `next_billing_date`. Der gesamte Bestand verlängert in einem Lauf.",0,0,24,2),
  ("Erfolgsquote",0,2,5,3),("Abbrüche",5,2,5,3),("Abos mit Störung",10,2,5,3),
  ("Geräte",15,2,4,3),("Durchlaufzeit bis zum Ticket",19,2,5,3),
  ("Bestellstrecke",0,5,12,6),("Abbrüche nach Ursache",12,5,12,6),
  ("Geräteplattform",0,11,12,6),("Arbeitslisten",12,11,12,6),
  ("Schultickets zum Erwachsenenpreis",0,17,24,8),
  ("TEXT","194 Schultickets wurden zu 63 € statt 43 € abgerechnet — 3.880 € Differenz. Entweder fehlende Nachweise oder ein Tariffehler.",0,25,24,2)])
print("\nFertig.")
