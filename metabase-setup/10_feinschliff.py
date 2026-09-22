#!/usr/bin/env python3
"""Feinschliff nach der Sichtprüfung des ersten Boards."""
import json, urllib.request, urllib.error
BASE="http://localhost:3030"; tok=None
TEAL,BLAU,AMBER="#0F6F7E","#2E5F92","#8A5C0D"
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

def patch(kartenname,**payload):
    cid=K.get(kartenname)
    if not cid: print("  fehlt:",kartenname); return
    card=call(f"/api/card/{cid}")
    vs=dict(card.get("visualization_settings") or {})
    cols=payload.pop("_spalten",None)
    if cols:
        cs=dict(vs.get("column_settings") or {})
        for key,opts in cols: cs[key]={**(cs.get(key) or {}),**opts}
        vs["column_settings"]=cs
    entf=payload.pop("_entfernen",[])
    for k in entf: vs.pop(k,None)
    vs.update(payload.pop("_viz",{}))
    body={"visualization_settings":vs}; body.update(payload)
    call(f"/api/card/{cid}",body,m="PUT"); print("  ",kartenname)

sp=lambda n,**o:(json.dumps(["name",n],separators=(",",":")),o)
EUR0={"number_style":"currency","currency":"EUR","currency_style":"symbol","decimals":0,"number_separators":",."}
DAT={"date_style":"D.M.YYYY","date_abbreviate":True}

print("1) Kennzahlen nicht mehr abkürzen, Titel kürzen ...")
patch("Umsatz brutto (erfolgreich)", name="Umsatz brutto",
      description="Summe brutto über alle erfolgreich abgeschlossenen Bestellungen.",
      _viz={"scalar.compact_primary_number": False},
      _spalten=[sp("Umsatz brutto",**EUR0)])
for n,c in [("Verkäufe","Verkäufe"),("Käufer","Käufer"),("Neue Konten","Konten"),
            ("Berechtigungen gesamt","Berechtigungen"),("Berechtigte ohne App-Konto","Offen"),
            ("Aktive Abos","Abos"),("Preispunkte","Preispunkte"),("Geräte","Geräte"),
            ("Umsatz Einzeltickets","Umsatz")]:
    patch(n, _viz={"scalar.compact_primary_number": False})

print("2) Kombi-Diagramm: Achsen sich selbst beschriften lassen ...")
patch("Bestellungen und Konten je Tag",
      _entfernen=["graph.y_axis.title_text"],
      _viz={"graph.dimensions":["Tag"],"graph.metrics":["Bestellungen","Neue Konten"],
            "series_settings":{"Bestellungen":{"color":TEAL,"display":"bar"},
                               "Neue Konten":{"color":AMBER,"display":"line","axis":"right",
                                              "line.marker_enabled":True}},
            "graph.x_axis.title_text":"September 2026",
            "graph.y_axis.auto_split":True},
      _spalten=[sp("Tag",**DAT)])

print("3) Datumsformat in den Zeitreihen ...")
patch("Umsatz je Tag", _spalten=[sp("Tag",**DAT)])
patch("Schultickets zum Erwachsenenpreis", _spalten=[sp("Kauftag",**DAT)])

print("4) Trichter und Produktmix lesbarer ...")
patch("Produktmix", _viz={"graph.dimensions":["Produkt"],"graph.metrics":["Stück"],
      "series_settings":{"Stück":{"color":TEAL}},"graph.show_values":True,
      "graph.x_axis.axis_enabled":False})
patch("Aktivierung je Bestandssegment",
      _viz={"graph.y_axis.min":0,"graph.y_axis.max":30})

print("5) Kachelbreiten anpassen ...")
DB=call(f"/api/collection/{COLL}/items?models=dashboard")["data"]
b1=next(d for d in DB if d["name"]=="1 — Überblick")
full=call(f"/api/dashboard/{b1['id']}")
namen={c["id"]:c.get("card",{}).get("name") for c in full["dashcards"]}
neu=[]
for c in full["dashcards"]:
    d={k:c[k] for k in ("id","card_id","row","col","size_x","size_y") if k in c}
    d["visualization_settings"]=c.get("visualization_settings",{})
    d["parameter_mappings"]=c.get("parameter_mappings",[])
    if namen.get(c["id"])=="Umsatz brutto":
        d["size_x"]=5
    elif namen.get(c["id"]) in ("Verkäufe","Ø Bon","Käufer","Neue Konten"):
        d["size_x"]=4
    elif namen.get(c["id"])=="Konto zu Kauf":
        d["size_x"]=5; d["col"]=19
    neu.append(d)
# Spalten neu ausrichten
x=0
for d in sorted([n for n in neu if n["row"]==2], key=lambda n:n["col"]):
    d["col"]=x; x+=d["size_x"]
call(f"/api/dashboard/{b1['id']}",{"dashcards":neu},m="PUT")
print("   Kennzahlenzeile neu ausgerichtet")
print("\nFertig.")
