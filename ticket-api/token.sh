#!/bin/bash
# =====================================================================
# Tokens verwalten — ein Token je Anwendung.
#
#   ./token.sh neu <anwendung> [tage]   Token ausstellen (Standard 365 Tage)
#   ./token.sh liste                    Alle Tokens mit Status
#   ./token.sh sperren <jti>            Ein Token sofort sperren
#
# Das Token wird genau einmal angezeigt und nirgends gespeichert.
# In der Datenbank steht nur seine Kennung (jti).
# =====================================================================
set -euo pipefail
BASIS="$(cd "$(dirname "$0")" && pwd)"
DB="${DB:-lue_reporting}"
JWT_SECRET_DATEI="${JWT_SECRET_DATEI:-$BASIS/geheim/jwt_secret}"   # Server: /etc/luemobil/jwt_secret

case "${1:-}" in
  neu)
    ANWENDUNG="${2:?Anwendung angeben, z. B. ./token.sh neu zendesk}"
    TAGE="${3:-365}"
    [[ "$ANWENDUNG" =~ ^[a-z0-9_-]{2,40}$ ]] || { echo "Anwendung: nur a-z, 0-9, _ und -" >&2; exit 1; }
    [[ "$TAGE" =~ ^[0-9]{1,4}$ ]] || { echo "Tage: Zahl" >&2; exit 1; }

    JTI="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    TOKEN="$(JWT_SECRET_DATEI="$JWT_SECRET_DATEI" python3 - "$JTI" "$ANWENDUNG" "$TAGE" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
jti, anwendung, tage = sys.argv[1], sys.argv[2], int(sys.argv[3])
secret = open(os.environ["JWT_SECRET_DATEI"], "rb").read().strip()
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
jetzt = int(time.time())
kopf = {"alg": "HS256", "typ": "JWT"}
inhalt = {"role": "hilfecenter", "aud": "tickets-api", "jti": jti,
          "anwendung": anwendung, "iat": jetzt, "exp": jetzt + tage * 86400}
teil = b64(json.dumps(kopf, separators=(",", ":")).encode()) + "." + \
       b64(json.dumps(inhalt, separators=(",", ":")).encode())
sig = hmac.new(secret, teil.encode(), hashlib.sha256).digest()
print(teil + "." + b64(sig))
PY
)"
    psql -q -d "$DB" -v ON_ERROR_STOP=1 -v jti="$JTI" -v anw="$ANWENDUNG" -v tage="$TAGE" <<'SQL'
INSERT INTO protokoll.token (jti, anwendung, gueltig_bis)
VALUES (:'jti', :'anw', now() + make_interval(days => :'tage'::int));
SQL
    echo "Anwendung : $ANWENDUNG"
    echo "Kennung   : $JTI"
    echo "Gültig    : $TAGE Tage"
    echo
    echo "$TOKEN"
    echo
    echo "Nur jetzt sichtbar. Sicher an die Anwendung übergeben (Passwort-Tresor, nicht per E-Mail)."
    ;;

  liste)
    psql -d "$DB" -c "
      SELECT jti, anwendung, ausgestellt::date, gueltig_bis::date,
             CASE WHEN gesperrt_am IS NOT NULL THEN 'gesperrt ' || gesperrt_am::date
                  WHEN gueltig_bis < now()    THEN 'abgelaufen'
                  ELSE 'aktiv' END AS zustand,
             (SELECT count(*) FROM protokoll.abfrage a WHERE a.jti = t.jti) AS abfragen
      FROM protokoll.token t ORDER BY ausgestellt DESC;"
    ;;

  sperren)
    JTI="${2:?Kennung (jti) angeben — siehe ./token.sh liste}"
    psql -q -d "$DB" -v ON_ERROR_STOP=1 -v jti="$JTI" -At <<'SQL'
UPDATE protokoll.token SET gesperrt_am = now()
WHERE jti = :'jti' AND gesperrt_am IS NULL
RETURNING 'Gesperrt: ' || anwendung || ' (' || jti || ')';
SQL
    ;;

  *)
    sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
