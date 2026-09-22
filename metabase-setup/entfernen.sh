#!/bin/bash
# Entfernt die komplette Demo-Umgebung wieder vom Rechner.
set -e
export PATH="/usr/local/opt/postgresql@16/bin:$PATH"
read -p "Demo-Datenbanken und Metabase entfernen? [ja/nein] " a
[ "$a" = "ja" ] || exit 0
pkill -f "metabase.jar" 2>/dev/null || true
dropdb --if-exists lue_reporting; dropdb --if-exists kk_mpswl; dropdb --if-exists kk_swl
rm -rf "$(dirname "$0")/metabase-app-db"* "$(dirname "$0")/metabase.jar" "$(dirname "$0")/metabase.log"
echo "Entfernt. PostgreSQL 16 und Java 21 bleiben installiert:"
echo "  brew services stop postgresql@16 && brew uninstall postgresql@16 openjdk@21"
