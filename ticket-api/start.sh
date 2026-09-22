#!/bin/bash
# Startet PostgREST (nur lokal, Port 3100) und nginx (HTTPS, Port 8443).
set -euo pipefail
BASIS="$(cd "$(dirname "$0")" && pwd)"
LZ="$BASIS/laufzeit"

[ -f "$BASIS/geheim/postgrest.conf" ] || { echo "Zuerst ./einrichten.sh ausführen." >&2; exit 1; }

if [ -f "$LZ/postgrest.pid" ] && kill -0 "$(cat "$LZ/postgrest.pid")" 2>/dev/null; then
  echo "PostgREST läuft bereits."
else
  nohup "$BASIS/bin/postgrest" "$BASIS/geheim/postgrest.conf" >> "$LZ/postgrest.log" 2>&1 &
  echo $! > "$LZ/postgrest.pid"
  echo "PostgREST gestartet (127.0.0.1:3100)."
fi

if [ -f "$LZ/nginx.pid" ] && kill -0 "$(cat "$LZ/nginx.pid")" 2>/dev/null; then
  nginx -p "$LZ" -c "$LZ/nginx.conf" -s reload
  echo "nginx neu geladen."
else
  nginx -p "$LZ" -c "$LZ/nginx.conf"
  echo "nginx gestartet (https://localhost:8443)."
fi
