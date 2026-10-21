#!/bin/bash
# =====================================================================
# Reports einspielen: Sichten, Kundenliste, Dashboards — in dieser Reihenfolge.
#
#   Server:  docker compose run --rm reports
#   Demo:    metabase-setup/reports_einspielen.sh   (PG* und MB_* aus der Umgebung)
#
# Wiederholbar. Hängt das Einspielen der Sichten hinter einer laufenden
# Metabase-Abfrage, bricht es nach 60 s ab (lock_timeout) — dann einfach
# noch einmal starten.
# =====================================================================
set -euo pipefail
HIER="$(cd "$(dirname "$0")" && pwd)"
DB="${DB_REPORTING:-lue_reporting}"

echo "1/3 Reporting-Sichten in $DB ..."
PROTOKOLL="$(mktemp)"; trap 'rm -f "$PROTOKOLL"' EXIT
if ! psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$HIER/13_app_reports.sql" >"$PROTOKOLL" 2>&1; then
  grep -v 'already exists, skipping' "$PROTOKOLL" || true
  echo "Sichten konnten nicht eingespielt werden (siehe oben)."; exit 1
fi
psql -X -q -At -d "$DB" -c "SELECT rpt.monatsstand_schreiben()" >/dev/null
echo "    ok: $(psql -X -At -d "$DB" -c "SELECT count(*) FROM rpt.bestellposition") Ticketpositionen"

echo "2/3 Kundenliste ..."
python3 "$HIER/12_kundenliste.py"

echo "3/3 Dashboards ..."
python3 "$HIER/14_dashboards.py"
