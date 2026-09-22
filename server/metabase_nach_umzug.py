#!/usr/bin/env python3
"""
Passt eine frisch umgezogene Metabase (load-from-h2) an den Produktivbetrieb an.
Einmalig nach dem Umzug ausführen, über den SSH-Tunnel. Nur Standardbibliothek.

  ssh -L 3030:127.0.0.1:3000 admin@server        # in einem zweiten Fenster
  MB_URL=http://localhost:3030 \\
  LESER_PASSWORT=<pw_leser> \\
  ADMIN_EMAIL=vorname.nachname@luemobil.de ADMIN_VORNAME=… ADMIN_NACHNAME=… \\
  ADMIN_PASSWORT=<mind. 12 Zeichen> \\
    ./metabase_nach_umzug.py

Was es tut:
  1. Verbindung "LüMobil Reporting" auf metabase_leser umstellen (nur lesen)
  2. Beispieldatenbank und ihr Dashboard entfernen
  3. Zwischenspeicher abschalten: nach dem nächtlichen Import sofort neue Zahlen
  4. Persönliches Admin-Konto anlegen, Demo-Konto deaktivieren
  5. Prüfen: Dashboards 6–9 sind zur Einbettung freigegeben
"""
import json, os, sys, urllib.error, urllib.request

URL = os.environ.get("MB_URL", "http://localhost:3030").rstrip("/")
DEMO = {"username": os.environ.get("DEMO_EMAIL", "demo@luemobil.local"),
        "password": os.environ.get("DEMO_PASSWORT", "LueMobilDemo2026")}
LESER = {"host": os.environ.get("DB_HOST", "localhost"), "port": int(os.environ.get("DB_PORT", "5432")),
         "dbname": "lue_reporting", "user": "metabase_leser",
         "password": os.environ.get("LESER_PASSWORT", "")}
ADMIN = {k: os.environ.get(v, "") for k, v in
         [("email", "ADMIN_EMAIL"), ("first_name", "ADMIN_VORNAME"),
          ("last_name", "ADMIN_NACHNAME"), ("password", "ADMIN_PASSWORT")]}
DASHBOARDS = [6, 7, 8, 9]

fehlt = [n for n, w in [("LESER_PASSWORT", LESER["password"])] + [(f"ADMIN_{k}", v) for k, v in ADMIN.items()] if not w]
if fehlt:
    sys.exit("Fehlende Angaben: " + ", ".join(fehlt))

sitzung = None
def api(methode, pfad, daten=None):
    kopf = {"Content-Type": "application/json"}
    if sitzung:
        kopf["X-Metabase-Session"] = sitzung
    anfrage = urllib.request.Request(URL + pfad, method=methode, headers=kopf,
                                     data=json.dumps(daten).encode() if daten is not None else None)
    try:
        with urllib.request.urlopen(anfrage, timeout=120) as r:
            inhalt = r.read()
            return json.loads(inhalt) if inhalt else None
    except urllib.error.HTTPError as e:
        sys.exit(f"FEHLER {methode} {pfad}: HTTP {e.code} — {e.read().decode(errors='replace')[:300]}")

def schritt(text): print(f"  {text}")

print(f"Metabase: {URL}")
sitzung = api("POST", "/api/session", DEMO)["id"]
datenbanken = {d["name"]: d for d in api("GET", "/api/database")["data"]}

# 1. Reporting-Verbindung auf den Lesezugang umstellen
rep = datenbanken.get("LüMobil Reporting") or sys.exit("Datenbank 'LüMobil Reporting' nicht gefunden.")
details = {**rep["details"], **LESER, "ssl": False}
api("PUT", f"/api/database/{rep['id']}", {"engine": "postgres", "details": details})
schritt(f"1. Verbindung '{rep['name']}' nutzt jetzt {LESER['user']}@{LESER['host']}/{LESER['dbname']}")

# 2. Beispieldaten entfernen
for name, db in datenbanken.items():
    if db.get("is_sample") or name == "Sample Database":
        for d in api("GET", "/api/dashboard"):
            if d.get("name") == "E-commerce Insights":
                api("PUT", f"/api/dashboard/{d['id']}", {"archived": True})
        api("DELETE", f"/api/database/{db['id']}")
        schritt(f"2. Beispieldatenbank '{name}' entfernt")

# 3. Keine Zwischenspeicherung
api("PUT", "/api/cache", {"model": "root", "model_id": 0, "strategy": {"type": "nocache"}})
schritt("3. Zwischenspeicher aus (Standardregel: nocache)")

# 4. Persönliches Admin-Konto, Demo-Konto deaktivieren
konten = {u["email"]: u for u in api("GET", "/api/user")["data"]}
if ADMIN["email"] not in konten:
    neu = api("POST", "/api/user", ADMIN)
    api("PUT", f"/api/user/{neu['id']}", {"is_superuser": True})
    schritt(f"4. Admin-Konto {ADMIN['email']} angelegt")
sitzung = api("POST", "/api/session", {"username": ADMIN["email"], "password": ADMIN["password"]})["id"]
demo = konten.get(DEMO["username"])
if demo and demo.get("is_active"):
    api("DELETE", f"/api/user/{demo['id']}")
    schritt(f"   Demo-Konto {DEMO['username']} deaktiviert")

# 5. Einbettung der Dashboards
fehler = 0
for d in DASHBOARDS:
    info = api("GET", f"/api/dashboard/{d}")
    ok = info.get("enable_embedding")
    fehler += not ok
    schritt(f"5. Dashboard {d} '{info['name']}': Einbettung {'freigegeben' if ok else 'NICHT freigegeben'}")

print("Fertig." if not fehler else "Fertig, aber nicht alle Dashboards sind freigegeben (Teilen → Einbetten).")
print("Weiter: einbettung_pruefen.py mit METABASE_URL=https://<reporting-host> und dem Einbettungsschlüssel.")
