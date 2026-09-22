#!/bin/bash
# Beendet nginx und PostgREST. Die Datenbank bleibt unberührt.
BASIS="$(cd "$(dirname "$0")" && pwd)"
LZ="$BASIS/laufzeit"

[ -f "$LZ/nginx.pid" ] && nginx -p "$LZ" -c "$LZ/nginx.conf" -s quit 2>/dev/null && echo "nginx beendet."
if [ -f "$LZ/postgrest.pid" ]; then
  kill "$(cat "$LZ/postgrest.pid")" 2>/dev/null && echo "PostgREST beendet."
  rm -f "$LZ/postgrest.pid"
fi
