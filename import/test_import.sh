#!/bin/bash
# =====================================================================
# Abnahmetest für import.sh — lokal und auf dem Server ausführbar.
#
#   ./test_import.sh <kk_mpswl-dump.sql> <kk_swl-dump.sql>
#
# Arbeitet NUR mit eigenen Testdatenbanken (imptest_mpswl, imptest_swl,
# imptest_reporting) und einem temporären Verzeichnis. Die echten
# Datenbanken werden nicht angefasst. Am Ende wird alles gelöscht.
# Voraussetzung: lue_reporting existiert (Schema wird als Vorlage kopiert).
# Verbindung über die üblichen PG-Variablen (PGHOST, PGPORT, PGUSER).
# Liegt lue_reporting auf einer anderen Instanz: VORLAGE="-h … -p …"
# =====================================================================
set -uo pipefail
HIER="$(cd "$(dirname "$0")" && pwd)"
QUELLE_MPSWL="${1:?Pfad zum kk_mpswl-Dump}"
QUELLE_SWL="${2:?Pfad zum kk_swl-Dump}"
T="$(mktemp -d)"
OK=0; FEHLER=0
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)

pruefe() {
  if [ "$2" = "$3" ]; then echo "  ok      $1"; OK=$((OK+1))
  else echo "  FEHLER  $1 (erwartet '$2', bekommen '$3')"; FEHLER=$((FEHLER+1)); fi
}
enthaelt() {  # enthaelt "Beschreibung" "muster" "text"
  if [[ "$3" == *"$2"* ]]; then echo "  ok      $1"; OK=$((OK+1))
  else echo "  FEHLER  $1 (erwartet '$2' in der Ausgabe)"; echo "$3" | sed 's/^/          | /'; FEHLER=$((FEHLER+1)); fi
}
bestellungen() { "${PSQL[@]}" -d imptest_mpswl -c "SELECT count(*) FROM orders" 2>/dev/null || echo "keine DB"; }
dbs()          { "${PSQL[@]}" -d postgres -c "SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database WHERE datname LIKE 'imptest_%'"; }
dateien()      { ls "$T/$1" 2>/dev/null | wc -l | tr -d ' '; }

konfig() {  # konfig [ZUSATZ=wert ...]
  cat > "$T/import.conf" <<EOF
EINGANG="$T/eingang"; ARCHIV="$T/archiv"; FEHLER="$T/fehler"; STATUS="$T/status"
DB_MPSWL=imptest_mpswl; DB_SWL=imptest_swl; DB_REPORTING=imptest_reporting
RUHEZEIT_MINUTEN=0
EOF
  for z in "$@"; do echo "$z" >> "$T/import.conf"; done
}
lauf() { IMPORT_CONF="$T/import.conf" "$HIER/import.sh" "$@" 2>&1; }

ablegen() {  # ablegen <tag JJJJMMTT> [variante: normal|abgeschnitten|kaputt|weniger] [nur: mpswl|swl]
  local tag="$1" art="${2:-normal}" nur="${3:-}"
  for paar in "kk_mpswl:$QUELLE_MPSWL" "kk_swl:$QUELLE_SWL"; do
    local name="${paar%%:*}" quelle="${paar#*:}"
    [ -n "$nur" ] && [ "kk_$nur" != "$name" ] && continue
    local ziel="$T/eingang/$name-PROD-${tag}020000.sql"
    { echo "-- Testvariante $tag $art"; cat "$quelle"; } > "$ziel"
    if [ "$name" = kk_mpswl ]; then
      case "$art" in
        abgeschnitten) head -c $(( $(wc -c < "$ziel") / 2 )) "$ziel" > "$ziel.x" && mv "$ziel.x" "$ziel" ;;
        kaputt)        awk '{print} /^CREATE TABLE public.orders / && !x {print "DAS IST KEIN SQL;"; x=1}' "$ziel" > "$ziel.x" && mv "$ziel.x" "$ziel" ;;
        weniger)       awk '/^COPY public.orders \(/ {b=1; n=0; print; next}
                            b && /^\\\.$/ {b=0}
                            b {n++; if (n > 100) next}
                            {print}' "$ziel" > "$ziel.x" && mv "$ziel.x" "$ziel" ;;
      esac
    fi
    touch -t "${tag:0:8}0300" "$ziel"
  done
}

aufraeumen() {
  "${PSQL[@]}" -d postgres -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname LIKE 'imptest_%'" >/dev/null
  for db in $("${PSQL[@]}" -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE 'imptest_%'"); do
    "${PSQL[@]}" -d postgres -c "DROP DATABASE \"$db\" WITH (FORCE)"
  done
  rm -rf "$T"
}
trap aufraeumen EXIT

# --- Vorbereitung ----------------------------------------------------
echo "Vorbereitung (Testverzeichnis $T)"
aufraeumen; mkdir -p "$T/eingang"
"${PSQL[@]}" -d postgres -c "CREATE DATABASE imptest_reporting"
for rolle in api_eigentuemer hilfecenter; do   # Rollen, auf die sich Rechte im Schema beziehen
  "${PSQL[@]}" -d postgres -c "DO \$\$BEGIN CREATE ROLE $rolle NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END\$\$"
done
pg_dump -s -O ${VORLAGE:-} lue_reporting | "${PSQL[@]}" -d imptest_reporting >/dev/null 2>&1
ICH=$("${PSQL[@]}" -d postgres -c "SELECT current_user")
# Fremdserver auf die Testdatenbanken umbiegen. Verbindung wie dieser Test:
# PGHOST gesetzt -> TCP, sonst Unix-Socket (Server: peer-Anmeldung als postgres).
"${PSQL[@]}" -d imptest_reporting -v h="${PGHOST:-}" -v p="${PGHOST:+${PGPORT:-5432}}" <<'SQL'
SELECT set_config('imptest.h', :'h', false), set_config('imptest.p', :'p', false) \gset
DO $$
DECLARE s text; o text; wert text; da boolean;
BEGIN
  FOREACH s IN ARRAY ARRAY['srv_mpswl', 'srv_swl'] LOOP
    EXECUTE format('ALTER SERVER %I OPTIONS (SET dbname %L)', s, replace(s, 'srv_', 'imptest_'));
    FOREACH o IN ARRAY ARRAY['host', 'port'] LOOP
      wert := current_setting('imptest.' || left(o, 1));
      da := EXISTS (SELECT FROM pg_foreign_server f, unnest(f.srvoptions) x
                    WHERE f.srvname = s AND x LIKE o || '=%');
      IF wert <> '' THEN
        EXECUTE format('ALTER SERVER %I OPTIONS (%s %I %L)', s, CASE WHEN da THEN 'SET' ELSE 'ADD' END, o, wert);
      ELSIF da THEN
        EXECUTE format('ALTER SERVER %I OPTIONS (DROP %I)', s, o);
      END IF;
    END LOOP;
  END LOOP;
END $$;
SQL
"${PSQL[@]}" -d imptest_reporting <<SQL
DROP USER MAPPING IF EXISTS FOR CURRENT_USER SERVER srv_mpswl;
DROP USER MAPPING IF EXISTS FOR CURRENT_USER SERVER srv_swl;
CREATE USER MAPPING FOR CURRENT_USER SERVER srv_mpswl OPTIONS (user '$ICH');
CREATE USER MAPPING FOR CURRENT_USER SERVER srv_swl   OPTIONS (user '$ICH');
SQL
[ "$("${PSQL[@]}" -d imptest_reporting -c "SELECT count(*) FROM pg_views WHERE schemaname = 'rpt'")" -gt 0 ] \
  || { echo "Vorlage aus lue_reporting konnte nicht kopiert werden."; exit 1; }
konfig

echo "1. Erstimport"
ablegen 20260901
AUSGABE=$(lauf); RC=$?
pruefe   "Exit 0"                                0 "$RC"
enthaelt "Rauchtest über Reporting-Sichten"      "Rauchtest ok" "$AUSGABE"
pruefe   "Datenbanken angelegt"                  "imptest_mpswl imptest_reporting imptest_swl" "$(dbs)"
pruefe   "Dumps archiviert"                      2 "$(dateien archiv)"
BASIS=$(bestellungen)
enthaelt "Status geschrieben"                    '"dump_tag": "20260901"' "$(lauf --status)"

echo "2. Dasselbe Paar noch einmal"
cp "$T/archiv/"* "$T/eingang/"
enthaelt "Wird erkannt und übersprungen"         "bereits importiert" "$(lauf)"

echo "3. Folgetag, während eine Reporting-Sitzung offen ist"
mkfifo "$T/fifo"
"${PSQL[@]}" -d imptest_reporting < "$T/fifo" > "$T/sitzung.txt" 2>&1 &
exec 3>"$T/fifo"
echo "SELECT 'vorher', count(*) FROM src_mpswl.orders;" >&3; sleep 1
ablegen 20260902
AUSGABE=$(lauf); RC=$?
pruefe   "Exit 0"                                0 "$RC"
pruefe   "Vorheriger Stand als _alt vorhanden"  "imptest_mpswl imptest_mpswl_alt imptest_reporting imptest_swl imptest_swl_alt" "$(dbs)"
echo "SELECT 'nachher', count(*) FROM src_mpswl.orders;" >&3; echo '\q' >&3; exec 3>&-; wait
enthaelt "Offene Sitzung verbindet sich neu"     "nachher|$BASIS" "$(cat "$T/sitzung.txt")"

echo "4. Abgeschnittener Dump"
ablegen 20260903 abgeschnitten
AUSGABE=$(lauf); RC=$?
pruefe   "Exit 1"                                1 "$RC"
enthaelt "Grund genannt"                         "unvollständig" "$AUSGABE"
pruefe   "Daten unverändert"                     "$BASIS" "$(bestellungen)"
pruefe   "Paar liegt in fehler/"                 2 "$(dateien fehler)"

echo "5. Dump mit SQL-Fehler"
ablegen 20260904 kaputt
AUSGABE=$(lauf); RC=$?
pruefe   "Exit 1"                                1 "$RC"
enthaelt "Grund genannt"                         "Einspielen von kk_mpswl" "$AUSGABE"
pruefe   "Daten unverändert"                     "$BASIS" "$(bestellungen)"
pruefe   "Keine _neu-Reste"                      "imptest_mpswl imptest_mpswl_alt imptest_reporting imptest_swl imptest_swl_alt" "$(dbs)"

echo "6. Dump mit eingebrochener Bestellmenge"
ablegen 20260905 weniger
AUSGABE=$(lauf); RC=$?
pruefe   "Exit 1"                                1 "$RC"
enthaelt "Grund genannt"                         "imptest_mpswl.orders: Rückgang" "$AUSGABE"
pruefe   "Daten unverändert"                     "$BASIS" "$(bestellungen)"

echo "7. Rauchtest schlägt nach dem Austausch fehl"
konfig "RAUCHTEST_SQL='SELECT count(*) FROM gibt_es_nicht'"
ablegen 20260906
AUSGABE=$(lauf); RC=$?
pruefe   "Exit 1"                                1 "$RC"
enthaelt "Rückbau durchgeführt"                  "Rückbau: imptest_mpswl" "$AUSGABE"
pruefe   "Daten wieder auf altem Stand"          "$BASIS" "$(bestellungen)"
pruefe   "Datenbanken vollständig"               "imptest_mpswl imptest_reporting imptest_swl" "$(dbs)"
enthaelt "Reporting funktioniert wieder"         "$BASIS" "$("${PSQL[@]}" -d imptest_reporting -c "SELECT count(*) FROM src_mpswl.orders")"
konfig

echo "8. Nur ein Dump angekommen"
ablegen 20260907 normal mpswl
enthaelt "Wartet zunächst"                       "warte auf den zweiten" "$(lauf)"
konfig "WARTEN_AUF_PARTNER_MINUTEN=0"
AUSGABE=$(lauf); RC=$?
pruefe   "Nach Wartezeit: Exit 1"                1 "$RC"
enthaelt "Grund genannt"                         "zweiter Dump fehlt" "$AUSGABE"
konfig

echo "9. Zweiter Lauf, während einer läuft"
mkdir -p "$T/status/import.sperre"; sleep 60 & SCHLAEFER=$!; echo $SCHLAEFER > "$T/status/import.sperre/pid"
enthaelt "Wird erkannt"                          "läuft bereits" "$(lauf)"
kill $SCHLAEFER 2>/dev/null; rm -rf "$T/status/import.sperre"

echo "10. Überwachung"
enthaelt "Frischer Import: ok"                   "OK: letzter Import" "$(lauf --pruefen)"
touch -t 202601010000 "$T/status/letzter_import.json"
lauf --pruefen >/dev/null; pruefe "Veralteter Import: Exit 1" 1 "$?"

echo "11. Leerer Eingang"
enthaelt "Nichts zu tun, Exit 0"                 "Keine neuen Dumps" "$(lauf)"

echo
echo "$OK bestanden, $FEHLER fehlgeschlagen"
[ $FEHLER -eq 0 ]
