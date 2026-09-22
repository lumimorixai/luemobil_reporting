#!/bin/bash
# =====================================================================
# Einmalig einrichten (oder nach Änderungen erneut — idempotent).
#   - erzeugt Geheimnisse: JWT-Schlüssel, DB-Passwort (nur falls fehlend)
#   - erzeugt eine lokale Zertifizierungsstelle und das Serverzertifikat
#   - legt Rollen, Funktion, Token-Register und Protokoll in der DB an
#   - schreibt die Konfiguration für PostgREST und nginx
# =====================================================================
set -euo pipefail
BASIS="$(cd "$(dirname "$0")" && pwd)"
GEHEIM="$BASIS/geheim"
DB="${DB:-lue_reporting}"

mkdir -p "$GEHEIM" "$BASIS/laufzeit/tmp"
chmod 700 "$GEHEIM"
umask 077

# --- Geheimnisse ------------------------------------------------------
[ -f "$GEHEIM/jwt_secret" ]  || openssl rand -base64 48 | tr -d '\n' > "$GEHEIM/jwt_secret"
[ -f "$GEHEIM/db_passwort" ] || openssl rand -hex 24 | tr -d '\n'    > "$GEHEIM/db_passwort"

# --- TLS: lokale CA + Serverzertifikat -------------------------------
# Produktion: stattdessen ein echtes Zertifikat (Let's Encrypt o. ä.)
if [ ! -f "$GEHEIM/server.crt" ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -days 825 \
    -keyout "$GEHEIM/ca.key" -out "$GEHEIM/ca.crt" \
    -subj "/CN=LueMobil lokale Test-CA" 2>/dev/null
  openssl req -newkey rsa:3072 -nodes \
    -keyout "$GEHEIM/server.key" -out "$GEHEIM/server.csr" \
    -subj "/CN=tickets-api.local" 2>/dev/null
  printf "subjectAltName=DNS:tickets-api.local,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n" > "$GEHEIM/server.ext"
  openssl x509 -req -in "$GEHEIM/server.csr" -CA "$GEHEIM/ca.crt" -CAkey "$GEHEIM/ca.key" \
    -CAcreateserial -days 825 -extfile "$GEHEIM/server.ext" -out "$GEHEIM/server.crt" 2>/dev/null
  rm -f "$GEHEIM/server.csr" "$GEHEIM/server.ext"
  echo "Zertifikat erzeugt. Clients vertrauen: $GEHEIM/ca.crt"
fi

# --- Datenbank --------------------------------------------------------
psql -q -d "$DB" -v db_passwort="$(cat "$GEHEIM/db_passwort")" -f "$BASIS/01_datenbank.sql"
echo "Datenbank eingerichtet."

# --- PostgREST-Konfiguration (enthält Passwort -> im Ordner geheim) ---
cat > "$GEHEIM/postgrest.conf" <<EOF
db-uri        = "postgres://api_zugang:$(cat "$GEHEIM/db_passwort")@localhost:5432/$DB"
db-schemas    = "api"
# Kein db-anon-role: ohne gültiges Token gibt es nichts.
db-pre-request = "protokoll.token_pruefen"
db-max-rows   = 500
db-pool       = 5
db-channel-enabled = true

jwt-secret    = "$(cat "$GEHEIM/jwt_secret")"
jwt-aud       = "tickets-api"

# Nur lokal erreichbar — von außen ausschließlich über nginx/TLS
server-host   = "127.0.0.1"
server-port   = 3100

openapi-mode  = "disabled"
log-level     = "warn"
EOF

# --- nginx-Konfiguration ----------------------------------------------
umask 022
sed "s|@@BASIS@@|$BASIS|g" "$BASIS/nginx.conf.vorlage" > "$BASIS/laufzeit/nginx.conf"

echo "Fertig. Weiter mit: ./start.sh  und  ./token.sh neu <anwendung>"
