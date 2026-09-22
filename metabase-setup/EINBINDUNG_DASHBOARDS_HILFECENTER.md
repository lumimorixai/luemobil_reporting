# LüMobil-Dashboards im Hilfecenter einbinden

Diese Anleitung ist für das Team, das das Hilfecenter entwickelt. Sie beschreibt,
wie die vier LüMobil-Dashboards aus Metabase auf Seiten des Hilfecenters erscheinen,
ohne dass Metabase selbst öffentlich erreichbar ist.

**Kurzfassung:** Nach der Anmeldung im Hilfecenter erzeugt euer **Server** ein kurzlebiges,
signiertes Token für ein Dashboard. Die Seite zeigt das Dashboard dann in einem `<iframe>`.
Eigene Metabase-Konten braucht dafür niemand.

```
Browser                       Hilfecenter-Server                     LüMobil-Reporting
───────                       ──────────────────                     ─────────────────
Seite „Kennzahlen“ ─────────▶ 1. Ist die Person angemeldet und
                                 darf sie Dashboard X sehen?
                              2. Token signieren:
                                 {dashboard: X, exp: jetzt+10 min}
◀──── HTML mit <iframe> ───── 3. iframe-URL mit Token ausliefern

<iframe> ─────────────────────────────────────────────────────────▶ /embed/dashboard/<token>
                                                                    Metabase prüft die Signatur,
◀────────────────────────────── Dashboard ───────────────────────── liefert nur dieses Dashboard
```

---

## 1. Die Dashboards

| ID | Dashboard | Inhalt | Personenbezug |
|---:|---|---|---|
| 6 | 1 — Überblick | Umsatz, Verkäufe, Ø Bon, Käufer, Konten, Tagesverlauf, Produktmix, Kanäle | nur Summen |
| 7 | 2 — Abo-Bestand | Berechtigungen, Aktivierungsquote, Trichter, Segmente, Altersprofil, Aktivierung je PLZ | Summen, PLZ-Tabelle mit kleinen Fallzahlen |
| 8 | 3 — Einzeltickets über PayOne | Tarifkatalog, Preisstufen, Preispunkte, Gültigkeitsregeln | keiner |
| 9 | 4 — Betrieb und Störungen | Erfolgsquote, Durchlaufzeit, Abbrüche, Plattformen, Arbeitslisten | **Tabelle „Schultickets zum Erwachsenenpreis“ zeigt einzelne Bestellungen** (Bestellnummer, Kauftag, Produkt, Preis, Status) |

- Die Dashboards haben **keine Filter**. Das Token braucht deshalb keine Parameter.
- Die IDs gelten für die **Demo**. Auf dem Produktivserver können sie anders lauten.
  Deshalb die IDs **konfigurierbar** halten und nicht fest im Code verdrahten.
- Welche Rolle im Hilfecenter welches Dashboard sehen darf, entscheidet ihr (Abschnitt 3.3).
  Dashboard 9 enthält Bestelldaten und sollte nur sehen, wer sie auch fachlich braucht.

---

## 2. Was ihr von uns bekommt

| Wert | Beispiel | Hinweis |
|---|---|---|
| `METABASE_URL` | `https://reporting.luemobil.de` | Dev: wird mitgeteilt |
| `METABASE_EMBED_SECRET` | 64 Hex-Zeichen | **Geheim.** Über den Passwort-Tresor, nicht per Mail. Wer ihn hat, kann jedes freigegebene Dashboard abrufen |
| Dashboard-IDs | `6, 7, 8, 9` | siehe oben |

Wir tragen die Adresse eures Hilfecenters (z. B. `https://hilfe.luemobil.de`) als
einzige erlaubte einbettende Seite ein. Von anderen Seiten aus lassen sich die Dashboards
nicht anzeigen. Bitte nennt uns **alle** Adressen, also Dev, Test und Produktion.

### Lokale Entwicklung

Für die Entwicklung läuft eine Demo-Metabase auf dem Rechner des LüMobil-Teams, mit
anonymisierten Daten. Die Werte stehen in der Datei `hilfecenter-lokal.env`, die ihr getrennt
bekommt:

```bash
METABASE_URL=http://localhost:3030
METABASE_EMBED_SECRET=<aus hilfecenter-lokal.env>
METABASE_DASHBOARDS=ueberblick:6,abo:7,payone:8,betrieb:9
```

- **Euer Server braucht keine Verbindung zu Metabase.** Er signiert nur das Token. Das
  Dashboard lädt der **Browser** über `http://localhost:3030`. Das funktioniert auch, wenn das
  Hilfecenter in Docker läuft, solange der Browser auf demselben Rechner ist.
- **Metabase muss laufen:** `metabase-setup/start.sh` im LüMobil-Projekt, Start dauert ca. 1 Minute.
  Prüfen: `curl http://localhost:3030/api/health` liefert `{"status":"ok"}`.
- **HTTPS-Hilfecenter mit `http://localhost`-iframe:** Das erlauben Chrome und Firefox, weil
  `localhost` als sicher gilt. Andere Hostnamen als `localhost` gehen nur mit HTTPS.
- Lokal ist jede einbettende Seite erlaubt, eine Freigabe der Adresse braucht es hier nicht.
- Zum Gegenprüfen: Dashboard 6, Kachel „Umsatz brutto“ zeigt **81.926 €**.

---

## 3. Was das Hilfecenter umsetzen muss

### 3.1 Konfiguration

```bash
METABASE_URL=https://reporting.luemobil.de
METABASE_EMBED_SECRET=…                   # aus dem Secret-Store, nie im Repository
METABASE_DASHBOARDS=ueberblick:6,abo:7,payone:8,betrieb:9
```

### 3.2 Token erzeugen — nur auf dem Server

Das Token ist ein JWT, signiert mit **HS256** und dem `METABASE_EMBED_SECRET`:

```json
{
  "resource": { "dashboard": 6 },
  "params":   {},
  "exp":      1790080000
}
```

| Feld | Bedeutung |
|---|---|
| `resource.dashboard` | ID des Dashboards. Das Token gilt **nur** für dieses eine |
| `params` | feste Filterwerte. Hier leer, weil die Dashboards keine Filter haben. Muss trotzdem vorhanden sein |
| `exp` | Ablauf als Unix-Zeitstempel in Sekunden. **Empfehlung: jetzt + 10 Minuten** |

**Python** (`pip install pyjwt`)

```python
import os, time, jwt

def dashboard_url(dashboard_id: int) -> str:
    token = jwt.encode(
        {"resource": {"dashboard": dashboard_id}, "params": {},
         "exp": int(time.time()) + 10 * 60},
        os.environ["METABASE_EMBED_SECRET"],
        algorithm="HS256",
    )
    return f"{os.environ['METABASE_URL']}/embed/dashboard/{token}#bordered=false&titled=true"
```

**Node.js** (`npm install jsonwebtoken`)

```js
import jwt from "jsonwebtoken";

export function dashboardUrl(dashboardId) {
  const token = jwt.sign(
    { resource: { dashboard: dashboardId }, params: {},
      exp: Math.round(Date.now() / 1000) + 10 * 60 },
    process.env.METABASE_EMBED_SECRET,
    { algorithm: "HS256" }
  );
  return `${process.env.METABASE_URL}/embed/dashboard/${token}#bordered=false&titled=true`;
}
```

**PHP** (`composer require firebase/php-jwt`)

```php
use Firebase\JWT\JWT;

function dashboard_url(int $dashboardId): string {
    $token = JWT::encode(
        ['resource' => ['dashboard' => $dashboardId], 'params' => new stdClass(),
         'exp' => time() + 10 * 60],
        getenv('METABASE_EMBED_SECRET'),
        'HS256'
    );
    return getenv('METABASE_URL') . "/embed/dashboard/$token#bordered=false&titled=true";
}
```

> PHP: `'params' => new stdClass()` statt `[]`, sonst wird daraus eine JSON-Liste `[]` statt
> eines Objekts `{}`.

### 3.3 Seite ausliefern

Der Ablauf auf eurer Seite „Kennzahlen“:

1. **Anmeldung prüfen:** wie bei jeder anderen geschützten Seite des Hilfecenters.
2. **Berechtigung prüfen:** Darf diese Rolle dieses Dashboard sehen? Wenn nicht: `403`, und **kein Token erzeugen**.
3. **Token erzeugen** (3.2) und die URL in das `<iframe>` schreiben.

```html
<iframe
  src="{{ dashboard_url }}"
  title="LüMobil – Überblick"
  width="100%" height="1200"
  frameborder="0"
  referrerpolicy="no-referrer"
  loading="lazy"
></iframe>
```

**Höhe:** Die Dashboards sind lang (10 bis 14 Kacheln). Ein iframe passt seine Höhe nicht
selbst an. Entweder eine feste Höhe setzen (1200–1600 px, je nach Dashboard ausprobieren)
oder das Skript von Metabase einbinden, das die Höhe automatisch anpasst:

```html
<script src="{{ METABASE_URL }}/app/iframeResizer.js"></script>
<iframe src="{{ dashboard_url }}" onload="iFrameResize({}, this)" width="100%" frameborder="0"></iframe>
```

**Aussehen:** Hinter `#` in der URL steuert ihr die Darstellung, z. B. `bordered=false`
(kein Rahmen), `titled=true` (Titel anzeigen), `refresh=300` (alle 5 Minuten neu laden).

### 3.4 Ablauf des Tokens

Das Token wird bei jedem Nachladen von Daten geprüft. Nach Ablauf zeigt ein offenes Dashboard
beim nächsten Aktualisieren einen Fehler. Das ist gewollt: Eine kopierte URL ist nach
10 Minuten wertlos.

Bleibt die Seite länger offen, lasst das iframe regelmäßig mit frischem Token neu laden,
zum Beispiel über einen kleinen Endpunkt, der nur die neue URL liefert:

```js
// GET /kennzahlen/url?dashboard=ueberblick  -> {"url": "https://reporting…/embed/dashboard/…"}
setInterval(async () => {
  const r = await fetch("/kennzahlen/url?dashboard=ueberblick", { credentials: "same-origin" });
  if (r.ok) document.querySelector("#dashboard").src = (await r.json()).url;
}, 9 * 60 * 1000);
```

Dieser Endpunkt muss dieselbe Anmelde- und Rechteprüfung haben wie die Seite selbst.

---

## 4. Sicherheit — Pflicht

- **Token nur auf dem Server erzeugen.** Der Schlüssel `METABASE_EMBED_SECRET` darf nie in
  JavaScript, HTML, einer App oder im Repository landen. Mit ihm kann man sich selbst
  Tokens ausstellen.
- **Erst prüfen, dann signieren.** Wer ein Token erhält, sieht das Dashboard. Die
  Rechteprüfung aus 3.3 ist die einzige Zugangskontrolle.
- **Kurze Gültigkeit:** höchstens 10 Minuten. Die iframe-URL enthält das Token und kann in
  Browserverlauf, Screenshots oder Logs landen.
- **iframe-URLs nicht loggen**, weder im Server-Log noch im Tracking.
- **`referrerpolicy="no-referrer"`** am iframe setzen, damit das Token nicht über den
  Referer an Dritte geht.
- **Content-Security-Policy** eurer Seite um die Metabase-Adresse ergänzen, falls ihr eine
  habt: `frame-src https://reporting.luemobil.de;` und für das Resizer-Skript
  `script-src … https://reporting.luemobil.de;`.
- **Schlüsselwechsel einplanen:** Tauschen wir den Schlüssel aus (z. B. nach einem Vorfall),
  werden alle Tokens sofort ungültig. Der neue Schlüssel muss sich ohne neues Deployment
  einspielen lassen.

---

## 5. Einschränkungen

| | |
|---|---|
| Nur ansehen | Kein Durchklicken in Details, keine eigenen Auswertungen, kein Export. Dashboards ändert das LüMobil-Team in Metabase selbst |
| Hinweis „Powered by Metabase“ | erscheint unter jedem Dashboard. Entfernen lässt er sich nur mit einer kostenpflichtigen Metabase-Lizenz |
| Keine Rechte pro Person | Innerhalb eines Dashboards sehen alle dasselbe. Unterschiedliche Sichten nur über verschiedene Dashboards |
| Datenstand | Die Daten werden nachts aktualisiert. Das Dashboard zeigt den Stand der letzten Nacht |

---

## 6. Fehlerbilder

| Im iframe erscheint | Ursache | Lösung |
|---|---|---|
| „Der Einbettungs-Secret-Key wurde nicht gesetzt.“ | Einbettung in Metabase noch nicht eingeschaltet | LüMobil-Betrieb informieren |
| Meldung zu ungültiger oder manipulierter Nachricht | falscher Schlüssel, oder Token falsch erzeugt (Algorithmus nicht HS256, `params` fehlt) | Schlüssel und Code prüfen |
| „Token is expired (…)“ | `exp` überschritten, oder die Serveruhr geht falsch | Neu laden, Serverzeit per NTP prüfen |
| „Einbettung ist für dieses Objekt nicht aktiviert.“ | falsche Dashboard-ID, oder Dashboard nicht zur Einbettung freigegeben | ID prüfen, sonst LüMobil-Betrieb informieren |
| Leere Fläche, Browser-Konsole: „refused to frame“ | Die Adresse eures Hilfecenters ist bei uns nicht als einbettende Seite eingetragen | Adresse an den LüMobil-Betrieb melden |
| Leere Fläche, Konsole: Content Security Policy `frame-src` | eure eigene CSP blockiert Metabase | `frame-src` ergänzen (Abschnitt 4) |

---

## 7. Checkliste für die Abnahme

- [ ] Angemeldete Person mit Berechtigung sieht das Dashboard
- [ ] Person **ohne** Berechtigung erhält `403`, im HTML steht kein Token
- [ ] Nicht angemeldet: Weiterleitung zur Anmeldung, kein Token
- [ ] Kopierte iframe-URL funktioniert nach 10 Minuten nicht mehr
- [ ] `METABASE_EMBED_SECRET` steht weder im Repository noch im ausgelieferten JavaScript
      (`grep` über das Build-Verzeichnis)
- [ ] iframe-URLs erscheinen nicht im Server-Log
- [ ] Seite bleibt 30 Minuten offen und aktualisiert sich ohne Fehler (falls 3.4 umgesetzt)

---

## Anhang: Aufgaben auf LüMobil-Seite

Nur zur Information für das Hilfecenter-Team. Das erledigt der LüMobil-Betrieb.

1. **Metabase:** *Admin → Einbettung → Statische Einbettung* einschalten. Den Schlüssel
   notieren und über den Tresor übergeben.
2. **Je Dashboard:** *Teilen → Einbetten → Statische Einbettung → Veröffentlichen*.
   Nur die Dashboards freigeben, die das Hilfecenter zeigen soll.
3. **Prüfen:** `METABASE_URL=… METABASE_EMBED_SECRET=… ./einbettung_pruefen.py` meldet alle
   Dashboards mit „ok“ und erzeugt eine Testseite.
4. **nginx vor Metabase:** Metabase lauscht nur auf `127.0.0.1`. Nach außen werden nur
   `/embed/`, `/api/embed/` und `/app/` durchgereicht, alles andere gibt `404`. Zusätzlich
   `add_header Content-Security-Policy "frame-ancestors https://hilfe.luemobil.de" always;`,
   denn Metabase selbst erlaubt ohne diese Einschränkung jede einbettende Seite.
   Welche Pfade die Einbettung genau braucht, beim Einrichten mit der Testseite und der
   Netzwerkansicht des Browsers bestätigen.
5. **Metabase-Oberfläche** für Admins nur per SSH-Tunnel:
   `ssh -L 3030:127.0.0.1:3000 admin@server`, dann `http://localhost:3030`.
