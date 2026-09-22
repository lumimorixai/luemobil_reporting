# Anbindung Hilfecenter an die LüMobil Ticket-API

Diese Anleitung ist für das Team, das das Hilfecenter entwickelt.

## Was das Hilfecenter implementieren muss

Das Hilfecenter braucht einen **serverseitigen** HTTPS-Aufruf. Er nimmt eine E-Mail-Adresse
entgegen und zeigt die zurückgegebenen Tickets an.

### 1. Anfrage

```
POST {BASIS_URL}/rpc/tickets_fuer_email
Authorization: Bearer {TOKEN}
Content-Type: application/json
X-Bearbeiter: {Login der Person im Hilfecenter}     (empfohlen)

{"p_email": "katja.katze@swl-innovation.de"}
```

- **Nur POST.** Die E-Mail gehört in den JSON-Body, nie in die URL. GET wird abgewiesen.
- **Die E-Mail unverändert übergeben.** Groß- und Kleinschreibung sowie Leerzeichen am Rand
  normalisiert die API selbst.
- **`X-Bearbeiter`** setzen, also den Namen oder Login der Person, die sucht. Er steht dann im
  Abfrageprotokoll. Fehlt er, ist nur „Hilfecenter“ als Ganzes nachvollziehbar.

### 2. Antwort

`200` mit einer JSON-Liste, neueste Bestellung zuerst:

```json
[
  {
    "gekauft_am":    "2026-09-03T13:50:04.59",
    "bestellnummer": "1788436204117",
    "produkt":       "Deutschlandticket 2.Kl",
    "sku":           "541",
    "menge":         1,
    "preis_brutto":  63.00,
    "status":        "Versendet",
    "erfolgreich":   true
  }
]
```

| Feld | Typ | Hinweis |
|---|---|---|
| `gekauft_am` | Zeitstempel ohne Zeitzone | deutsche Ortszeit |
| `bestellnummer` | Text | Text, nicht Zahl: 13 Stellen, führende Nullen möglich |
| `produkt` | Text | Tarifname |
| `sku` | Text | Tarifnummer |
| `menge` | Ganzzahl | |
| `preis_brutto` | Dezimalzahl | Einzelpreis in Euro inkl. MwSt. Nicht als Float runden, sondern als Dezimalwert behandeln |
| `status` | Text | z. B. „Versendet“, „Abgebrochen“ |
| `erfolgreich` | Boolean | `true` = Ticket wurde ausgeliefert |

Eine Bestellung mit mehreren Tickets ergibt mehrere Zeilen mit derselben `bestellnummer`.
Zum Gruppieren bitte diese Nummer verwenden. **Leere Liste `[]`** heißt, dass es zu dieser
Adresse keine Bestellungen gibt. Das ist kein Fehler.

### 3. Fehler behandeln

| Code | Bedeutung | Was das Hilfecenter tun sollte |
|---|---|---|
| `400` | Keine gültige E-Mail-Adresse | Eingabe prüfen lassen |
| `401` | Token fehlt, ist falsch, abgelaufen oder gesperrt | Nicht wiederholen, Betrieb alarmieren |
| `403` | Methode falsch oder IP-Adresse nicht freigegeben | Konfiguration prüfen |
| `404` | Falscher Pfad | Konfiguration prüfen |
| `429` | Zu viele Anfragen | Hinweis „bitte kurz warten“, nicht automatisch wiederholen |
| `5xx` / Zeitüberschreitung | Störung | Hinweis „derzeit nicht verfügbar“, höchstens ein Wiederholungsversuch |

Timeout auf Client-Seite: **10 Sekunden**.

Grenzen: 30 Anfragen pro Minute je Token (kurzzeitig bis zu 10 zusätzlich), höchstens 500 Zeilen je Antwort.

### 4. Sicherheit — Pflicht

- **Aufruf nur vom Server des Hilfecenters**, nie aus dem Browser oder einer App. Das Token
  darf den Server nicht verlassen und nicht im Frontend-Code stehen.
- **Token nicht im Code und nicht im Repository**, sondern in der Secret-Verwaltung bzw. einer Umgebungsvariable
  (z. B. `LUEMOBIL_API_TOKEN`).
- **Token nicht loggen**, auch nicht in Fehlermeldungen. Das Gleiche gilt für die gesuchte
  E-Mail-Adresse in Debug-Logs.
- **Zertifikat prüfen**, nie `verify=false` oder `-k`. Im Dev-System wird dafür die mitgelieferte
  `ca.crt` als vertrauenswürdig hinterlegt, in Produktion ist das nicht nötig.
- **Token-Wechsel einplanen:** Tokens laufen ab. Das Token muss sich ohne neues Deployment
  austauschen lassen.

### 5. Beispiele

**curl**

```bash
curl --cacert ca.crt -X POST "$BASIS_URL/rpc/tickets_fuer_email" \
  -H "Authorization: Bearer $LUEMOBIL_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Bearbeiter: m.mustermann" \
  -d '{"p_email":"katja.katze@swl-innovation.de"}'
```

**Python**

```python
import os, requests

def tickets_fuer_email(email: str, bearbeiter: str) -> list[dict]:
    r = requests.post(
        f"{os.environ['LUEMOBIL_API_URL']}/rpc/tickets_fuer_email",
        headers={"Authorization": f"Bearer {os.environ['LUEMOBIL_API_TOKEN']}",
                 "X-Bearbeiter": bearbeiter},
        json={"p_email": email},
        timeout=10,
        verify=os.environ.get("LUEMOBIL_API_CA", True),  # Dev: Pfad zur ca.crt
    )
    if r.status_code == 429:
        raise RuntimeError("Zu viele Anfragen, bitte kurz warten")
    r.raise_for_status()
    return r.json()
```

**Node.js (ab 18)**

```js
import { readFileSync } from "node:fs";
import { Agent } from "undici";

const dispatcher = process.env.LUEMOBIL_API_CA
  ? new Agent({ connect: { ca: readFileSync(process.env.LUEMOBIL_API_CA) } })
  : undefined;

export async function ticketsFuerEmail(email, bearbeiter) {
  const res = await fetch(`${process.env.LUEMOBIL_API_URL}/rpc/tickets_fuer_email`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.LUEMOBIL_API_TOKEN}`,
      "Content-Type": "application/json",
      "X-Bearbeiter": bearbeiter,
    },
    body: JSON.stringify({ p_email: email }),
    signal: AbortSignal.timeout(10_000),
    dispatcher,
  });
  if (!res.ok) throw new Error(`Ticket-API: HTTP ${res.status}`);
  return res.json();
}
```

## Zugangsdaten

| | Dev | Produktion |
|---|---|---|
| `LUEMOBIL_API_URL` | `https://tickets-api.local:8443` | folgt |
| `LUEMOBIL_API_TOKEN` | wird separat und sicher übergeben | wird separat und sicher übergeben |
| `LUEMOBIL_API_CA` | `ca.crt` (wird mitgeliefert) | entfällt, öffentliches Zertifikat |
| Freigegebene IP | muss uns mitgeteilt werden | muss uns mitgeteilt werden |

**Dev-Daten sind anonymisiert.** Echte Adressen funktionieren trotzdem, weil die API sie intern
umrechnet. Die Beträge und Produkte sind echt, Namen gibt die API ohnehin nicht zurück.
Testadresse mit 4 Treffern: `katja.katze@swl-innovation.de`.
