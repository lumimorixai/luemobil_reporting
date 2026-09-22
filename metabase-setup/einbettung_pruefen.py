#!/usr/bin/env python3
"""
Prüft die Metabase-Einbettung und erzeugt eine Testseite — ohne Zusatzpakete.

  METABASE_URL=http://localhost:3030 METABASE_EMBED_SECRET=<schlüssel> \\
    ./einbettung_pruefen.py [dashboard-id ...]          (Standard: 6 7 8 9)

Für jedes Dashboard wird ein Token signiert (wie es der Server des Hilfecenters
tut) und /api/embed/dashboard/<token> abgefragt. Danach liegt
einbettung_test.html im aktuellen Ordner: im Browser öffnen, alle Dashboards
müssen sichtbar sein. Die Seite enthält gültige Tokens (10 Minuten) — nicht weitergeben.
"""
import base64, hashlib, hmac, json, os, sys, time, urllib.error, urllib.request

URL = os.environ.get("METABASE_URL", "http://localhost:3030").rstrip("/")
SECRET = os.environ.get("METABASE_EMBED_SECRET", "")
IDS = [int(x) for x in sys.argv[1:]] or [6, 7, 8, 9]
if not SECRET:
    sys.exit("METABASE_EMBED_SECRET fehlt (Admin > Einbettung > Statische Einbettung > Schlüssel).")

b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def token(dashboard_id: int, minuten: int = 10) -> str:
    kopf = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    inhalt = b64(json.dumps({"resource": {"dashboard": dashboard_id}, "params": {},
                             "exp": int(time.time()) + minuten * 60}).encode())
    sig = hmac.new(SECRET.encode(), f"{kopf}.{inhalt}".encode(), hashlib.sha256).digest()
    return f"{kopf}.{inhalt}.{b64(sig)}"

fehler, rahmen = 0, []
for d in IDS:
    t = token(d)
    try:
        with urllib.request.urlopen(f"{URL}/api/embed/dashboard/{t}", timeout=15) as r:
            daten = json.load(r)
        print(f"  ok      Dashboard {d}: {daten.get('name')} ({len(daten.get('dashcards', []))} Kacheln)")
        rahmen.append(f'<h2>{daten.get("name")}</h2>\n<iframe src="{URL}/embed/dashboard/{t}#bordered=true&titled=false" '
                      f'width="100%" height="900" frameborder="0"></iframe>')
    except urllib.error.HTTPError as e:
        fehler += 1
        print(f"  FEHLER  Dashboard {d}: HTTP {e.code} — {e.read().decode(errors='replace')[:200]}")
    except OSError as e:
        fehler += 1
        print(f"  FEHLER  Dashboard {d}: Metabase nicht erreichbar ({e})")

if rahmen:
    with open("einbettung_test.html", "w", encoding="utf-8") as f:
        f.write('<!doctype html><meta charset="utf-8"><title>Einbettungstest</title>'
                '<body style="font-family:sans-serif;max-width:1400px;margin:auto">\n'
                + "\n".join(rahmen) + "\n</body>")
    print("Testseite: einbettung_test.html (Tokens 10 Minuten gültig)")
sys.exit(1 if fehler else 0)
