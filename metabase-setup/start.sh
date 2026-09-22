#!/bin/bash
# Startet PostgreSQL und Metabase für die LüMobil-Demo.
SET="$(cd "$(dirname "$0")" && pwd)"
export PATH="/usr/local/opt/postgresql@16/bin:$PATH"

pg_isready -q || brew services start postgresql@16
until pg_isready -q; do sleep 2; done
echo "PostgreSQL läuft."

if lsof -nP -iTCP:3030 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Metabase läuft bereits auf http://localhost:3030"
else
  MB_DB_TYPE=h2 MB_DB_FILE="$SET/metabase-app-db" MB_JETTY_PORT=3030 \
    nohup /usr/local/opt/openjdk@21/bin/java -jar "$SET/metabase.jar" \
    > "$SET/metabase.log" 2>&1 &
  echo "Metabase startet — das dauert ein bis zwei Minuten."
  until curl -s -o /dev/null http://localhost:3030/api/health 2>/dev/null; do sleep 5; done
  echo "Bereit: http://localhost:3030"
fi
