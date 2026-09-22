#!/bin/bash
# =====================================================================
# Prüft die Ticket-API von außen: Funktion, Authentifizierung,
# Sperren, Nur-Lesen, Transport, Rate-Limit, Protokoll.
#   ./test.sh            (nimmt das Token aus geheim/demo_token)
# =====================================================================
set -uo pipefail
BASIS="$(cd "$(dirname "$0")" && pwd)"
URL="https://localhost:8443"
CA="$BASIS/geheim/ca.crt"
TOKEN="${TOKEN:-$(cat "$BASIS/geheim/demo_token")}"
DB="${DB:-lue_reporting}"
OK=0; FEHLER=0

pruefe() {  # pruefe "Beschreibung" erwartet tatsächlich
  if [ "$2" = "$3" ]; then echo "  ok      $1"; OK=$((OK+1))
  else echo "  FEHLER  $1 (erwartet $2, bekommen $3)"; FEHLER=$((FEHLER+1)); fi
}
PAUSE=2      # unter dem Rate-Limit bleiben (30/min je Token)
status() {  # status <token|-> <methode> <pfad> [body]
  sleep "$PAUSE"
  local auth="X-Kein-Token: 1"; [ "$1" != "-" ] && auth="Authorization: Bearer $1"
  curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" -X "$2" -H "$auth" \
       -H "Content-Type: application/json" "$URL$3" ${4:+-d "$4"}
}
jwt() {  # jwt '<json-inhalt>' [secret]  -> signiertes Token
  python3 - "$1" "${2:-$(cat "$BASIS/geheim/jwt_secret")}" <<'PY'
import base64, hashlib, hmac, json, sys
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
t = b64(b'{"alg":"HS256","typ":"JWT"}') + "." + b64(sys.argv[1].encode())
print(t + "." + b64(hmac.new(sys.argv[2].encode(), t.encode(), hashlib.sha256).digest()))
PY
}
KATJA='{"p_email":"katja.katze@swl-innovation.de"}'
JETZT=$(date +%s)

echo "Funktion"
ANTWORT=$(curl -s --cacert "$CA" -X POST "$URL/rpc/tickets_fuer_email" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$KATJA")
pruefe "Katja: 4 Tickets"                          4   "$(echo "$ANTWORT" | jq length)"
pruefe "Groß/klein + Leerzeichen egal"             200 "$(status "$TOKEN" POST /rpc/tickets_fuer_email '{"p_email":"  KATJA.Katze@swl-innovation.de "}')"
pruefe "Unbekannte Adresse: leere Liste, kein Fehler" "[]" "$(curl -s --cacert "$CA" -X POST "$URL/rpc/tickets_fuer_email" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"p_email":"niemand@example.org"}')"
pruefe "Keine E-Mail-Adresse -> 400"               400 "$(status "$TOKEN" POST /rpc/tickets_fuer_email '{"p_email":"DROP TABLE x"}')"

echo "Authentifizierung"
pruefe "Ohne Token -> 401"                         401 "$(status - POST /rpc/tickets_fuer_email "$KATJA")"
pruefe "Kaputtes Token -> 401"                     401 "$(status "abc.def.ghi" POST /rpc/tickets_fuer_email "$KATJA")"
pruefe "Falscher Schlüssel -> 401"                 401 "$(status "$(jwt '{"role":"hilfecenter","aud":"tickets-api","jti":"ee557e0a-3a84-4824-838c-194c25fb15ee","exp":9999999999}' falsch-falsch-falsch-falsch-falsch-falsch)" POST /rpc/tickets_fuer_email "$KATJA")"
T_ABGELAUFEN=$(jwt "$(printf '{"role":"hilfecenter","aud":"tickets-api","jti":"%s","exp":%d}' "$(uuidgen)" $((JETZT-60)))")
T_FREMD_AUD=$(jwt "$(printf '{"role":"hilfecenter","aud":"andere-api","exp":%d}' $((JETZT+600)))")
T_UNREGISTRIERT=$(jwt "$(printf '{"role":"hilfecenter","aud":"tickets-api","jti":"%s","exp":%d}' "$(uuidgen)" $((JETZT+600)))")
T_ADMIN=$(jwt "$(printf '{"role":"%s","aud":"tickets-api","exp":%d}' "$(whoami)" $((JETZT+600)))")
pruefe "Abgelaufen -> 401"                         401 "$(status "$T_ABGELAUFEN" POST /rpc/tickets_fuer_email "$KATJA")"
pruefe "Falsche Zielgruppe (aud) -> 401"           401 "$(status "$T_FREMD_AUD" POST /rpc/tickets_fuer_email "$KATJA")"
pruefe "Gültig signiert, aber nicht registriert -> 401" 401 "$(status "$T_UNREGISTRIERT" POST /rpc/tickets_fuer_email "$KATJA")"
ROLLE=$(status "$T_ADMIN" POST /rpc/tickets_fuer_email "$KATJA")
pruefe "Token mit Admin-Rolle -> abgewiesen"       abgewiesen "$( { [ "$ROLLE" = 401 ] || [ "$ROLLE" = 403 ]; } && echo abgewiesen || echo "$ROLLE")"

echo "Sperren"
NEU=$("$BASIS/token.sh" neu sperrtest 1 | sed -n 5p)
JTI=$("$BASIS/token.sh" liste | awk '/sperrtest/ && /aktiv/ {print $1; exit}')
pruefe "Neues Token funktioniert"                  200 "$(status "$NEU" POST /rpc/tickets_fuer_email "$KATJA")"
"$BASIS/token.sh" sperren "$JTI" >/dev/null
pruefe "Nach Sperren sofort 401"                   401 "$(status "$NEU" POST /rpc/tickets_fuer_email "$KATJA")"

echo "Nur lesen / nur ein Endpunkt"
pruefe "GET mit E-Mail in der URL -> 403"          403 "$(status "$TOKEN" GET '/rpc/tickets_fuer_email?p_email=katja.katze@swl-innovation.de')"
pruefe "PATCH -> 403"                              403 "$(status "$TOKEN" PATCH /rpc/tickets_fuer_email "$KATJA")"
pruefe "DELETE -> 403"                             403 "$(status "$TOKEN" DELETE /rpc/tickets_fuer_email)"
pruefe "Wurzel/OpenAPI -> 404"                     404 "$(status "$TOKEN" GET /)"
pruefe "Tabelle abfragen -> 404"                   404 "$(status "$TOKEN" GET /abfrage)"
pruefe "Andere Funktion -> 404"                    404 "$(status "$TOKEN" POST /rpc/token_pruefen '{}')"
pruefe "Schema umschalten (Header) -> 404/406"     ja  "$(c=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" -X POST "$URL/rpc/aufraeumen" -H "Authorization: Bearer $TOKEN" -H "Content-Profile: protokoll" -H "Content-Type: application/json" -d '{}'); [ "$c" != 200 ] && echo ja || echo "$c")"

echo "Transport"
pruefe "Unverschlüsselt (Port 8080) -> 403"        403 "$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8080/rpc/tickets_fuer_email -d "$KATJA")"
pruefe "HTTP auf HTTPS-Port -> 400"                400 "$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8443/rpc/tickets_fuer_email -d "$KATJA")"
pruefe "Unbekanntes Zertifikat wird abgelehnt"     60  "$(curl -s -o /dev/null -X POST https://localhost:8443/rpc/tickets_fuer_email; echo $?)"
pruefe "PostgREST nur auf 127.0.0.1"               "127.0.0.1:3100" "$(lsof -nP -iTCP:3100 -sTCP:LISTEN | awk 'NR==2{print $9}')"
pruefe "Großer Body -> 413"                        413 "$(status "$TOKEN" POST /rpc/tickets_fuer_email "{\"p_email\":\"$(head -c 2000 /dev/zero | tr '\0' a)@x.de\"}")"

echo "Protokoll"
pruefe "Abfrage steht im Protokoll"                ja "$(psql -d "$DB" -Atc "SELECT CASE WHEN count(*)>0 THEN 'ja' END FROM protokoll.abfrage WHERE email_gesucht='katja.katze@swl-innovation.de' AND anwendung='hilfecenter-demo' AND zeitpunkt > now()-interval '5 minutes'")"
pruefe "Keine E-Mail im nginx-Log"                 0  "$(grep -c '@' "$BASIS/laufzeit/zugriff.log")"

echo "Rate-Limit (40 Anfragen in schneller Folge)"
PAUSE=0; N429=0
for i in $(seq 40); do
  [ "$(status "$TOKEN" POST /rpc/tickets_fuer_email '{"p_email":"ratenlimit@example.org"}')" = 429 ] && N429=$((N429+1))
done
pruefe "Überzählige Anfragen -> 429"               ja "$([ $N429 -ge 20 ] && echo ja || echo "nur $N429")"

echo
echo "$OK bestanden, $FEHLER fehlgeschlagen"
[ $FEHLER -eq 0 ]
