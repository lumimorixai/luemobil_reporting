#!/bin/bash
# =====================================================================
# Sichert die beiden Datenbanken mit eigenem Inhalt:
#   lue_reporting  Sichten, API-Funktion, Token-Register, Abfrageprotokoll
#   metabase_app   Dashboards, Fragen, Konten, Einstellungen
#
# kk_mpswl und kk_swl werden NICHT gesichert — sie kommen jede Nacht neu.
# Aufruf:  docker compose run --rm sicherung
# =====================================================================
set -euo pipefail
ZIEL=/sicherung
TAGE="${AUFBEWAHRUNG_TAGE:-30}"
HEUTE=$(date +%Y%m%d)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

for db in lue_reporting metabase_app; do
  if ! psql -X -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
    log "$db gibt es nicht — übersprungen."
    continue
  fi
  datei="$ZIEL/$db-$HEUTE.dump"
  pg_dump -Fc -f "$datei.teil" "$db"
  mv "$datei.teil" "$datei"
  log "$db gesichert ($(du -h "$datei" | cut -f1))"
done

geloescht=$(find "$ZIEL" -name '*.dump' -mtime +"$TAGE" -print -delete | wc -l | tr -d ' ')
[ "$geloescht" -gt 0 ] && log "$geloescht alte Sicherungen gelöscht (älter als $TAGE Tage)"
log "Fertig."
