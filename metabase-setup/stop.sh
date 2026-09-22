#!/bin/bash
# Beendet Metabase. PostgreSQL bleibt laufen (mit --alles auch das).
pkill -f "metabase.jar" && echo "Metabase beendet." || echo "Metabase lief nicht."
if [ "$1" = "--alles" ]; then
  brew services stop postgresql@16 && echo "PostgreSQL beendet."
fi
