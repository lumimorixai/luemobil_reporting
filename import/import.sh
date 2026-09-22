#!/bin/bash
# =====================================================================
# LüMobil — nächtlicher Import der Datenbank-Dumps
# =====================================================================
#   import.sh             Neues Dump-Paar suchen und einspielen
#   import.sh --pruefen   Exit 1, wenn der letzte erfolgreiche Import zu alt ist
#   import.sh --status    Letzten Import anzeigen
#
# Konfiguration: $IMPORT_CONF, sonst /etc/luemobil/import.conf
#
# Ablauf (Details im BETRIEBSHANDBUCH.md):
#   1. Paar kk_mpswl-PROD-*.sql + kk_swl-PROD-*.sql vom selben Tag suchen
#   2. Vollständig? (Endmarke von pg_dump, Datei seit Minuten unverändert)
#   3. In <db>_neu einspielen — die laufenden Datenbanken bleiben unberührt
#   4. Plausibilität: Mindestmengen, kein Einbruch gegenüber gestern
#   5. Austausch per RENAME: <db> -> <db>_alt, <db>_neu -> <db>
#   6. Rauchtest über die Reporting-Sichten, bei Fehler sofort zurücktauschen
#   7. Dumps archivieren, Status schreiben, Altes aufräumen
#
# Bei jedem Fehler: Exit 1, Dumps nach fehler/, alte Daten bleiben aktiv.
# Läuft auf Linux (Server) und macOS (lokaler Test), bash >= 3.2.
# =====================================================================
set -euo pipefail

CONF="${IMPORT_CONF:-/etc/luemobil/import.conf}"
[ -r "$CONF" ] || { echo "Konfiguration fehlt: $CONF" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONF"

: "${EINGANG:?}" "${ARCHIV:?}" "${FEHLER:?}" "${STATUS:?}"
: "${DB_MPSWL:=kk_mpswl}" "${DB_SWL:=kk_swl}" "${DB_REPORTING:=lue_reporting}"
: "${MIN_KUNDEN:=100}" "${MIN_BESTELLUNGEN:=100}" "${MAX_RUECKGANG_PROZENT:=5}"
: "${RUHEZEIT_MINUTEN:=2}" "${WARTEN_AUF_PARTNER_MINUTEN:=360}"
: "${ARCHIV_TAGE:=7}" "${MAX_ALTER_STUNDEN:=30}"
# Rollen, die in den Dumps als Eigentümer vorkommen. Fehlen sie im Zielcluster
# (z. B. weil der Superuser dort "luemobil" heißt), legt der Import sie ohne
# Anmelderecht an — sonst scheitert jedes ALTER ... OWNER TO im Dump.
: "${DUMP_ROLLEN:=postgres}"
: "${RAUCHTEST_SQL:=SELECT count(*) FROM rpt.bestellposition}"

PSQL=(psql -X -q -v ON_ERROR_STOP=1)
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
[ -n "${PGHOST_IMPORT:-}" ] && export PGHOST="$PGHOST_IMPORT"

log()    { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
fehler() { log "FEHLER: $*"; exit 1; }

# --- Plattformunabhängige Helfer --------------------------------------
mtime()  { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# Ankunft auf diesem Server (ctime): kann der Absender nicht mitliefern, anders
# als mtime, das z. B. "sftp put -p" oder "rsync -t" vom Quellsystem übernimmt.
ankunft() { stat -c %Z "$1" 2>/dev/null || stat -f %c "$1"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
lesen()  { case "$1" in *.gz) gzip -dc "$1" ;; *) cat "$1" ;; esac; }
sql()    { "${PSQL[@]}" -At -d "$1" -c "$2"; }
db_da()  { [ "$(sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$1'")" = 1 ]; }

# --- Modus --pruefen / --status ---------------------------------------
case "${1:-}" in
  --status)
    cat "$STATUS/letzter_import.json" 2>/dev/null || echo "Noch kein erfolgreicher Import."
    exit 0 ;;
  --pruefen)
    [ -f "$STATUS/letzter_import.json" ] || fehler "Noch nie erfolgreich importiert."
    ALTER_H=$(( ($(date +%s) - $(mtime "$STATUS/letzter_import.json")) / 3600 ))
    [ "$ALTER_H" -le "$MAX_ALTER_STUNDEN" ] || fehler "Letzter erfolgreicher Import vor ${ALTER_H} h (Grenze ${MAX_ALTER_STUNDEN} h)."
    log "OK: letzter Import vor ${ALTER_H} h."
    exit 0 ;;
  "") ;;
  *) echo "Aufruf: $0 [--pruefen|--status]" >&2; exit 2 ;;
esac

mkdir -p "$ARCHIV" "$FEHLER" "$STATUS"
touch "$STATUS/importiert.txt"

# --- Sperre: nie zwei Läufe gleichzeitig -------------------------------
SPERRE="$STATUS/import.sperre"
if ! mkdir "$SPERRE" 2>/dev/null; then
  ALT_PID=$(cat "$SPERRE/pid" 2>/dev/null || echo "")
  if [ -n "$ALT_PID" ] && kill -0 "$ALT_PID" 2>/dev/null; then
    log "Ein Import läuft bereits (PID $ALT_PID). Nichts zu tun."; exit 0
  fi
  log "Verwaiste Sperre entfernt."; rm -rf "$SPERRE"; mkdir "$SPERRE"
fi
echo $$ > "$SPERRE/pid"

AKTIV_TAUSCH=""        # welche Datenbanken schon getauscht sind (für Rückbau)
PAAR=()
aufraeumen() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    # Zurück, wenn schon getauscht — oder wenn der Tausch mittendrin abbrach
    for db in "$DB_MPSWL" "$DB_SWL"; do
      if db_da "${db}_alt" && { [[ " $AKTIV_TAUSCH " == *" $db "* ]] || ! db_da "$db"; }; then
        zuruecktauschen "$db" || log "Rückbau von $db fehlgeschlagen — MANUELL PRÜFEN"
      fi
    done
    for db in "$DB_MPSWL" "$DB_SWL"; do
      "${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS \"${db}_neu\" WITH (FORCE)" 2>/dev/null || true
    done
    for f in "${PAAR[@]:-}"; do [ -n "$f" ] && [ -f "$f" ] && mv "$f" "$FEHLER/" && log "Nach fehler/ verschoben: $(basename "$f")"; done
    log "Import abgebrochen. Die bisherigen Daten sind weiter aktiv."
  fi
  rm -rf "$SPERRE"
}
trap aufraeumen EXIT

# --- 1. Dump-Paar finden ---------------------------------------------
neuester() {  # neuester <prefix> -> Pfad der neuesten passenden Datei
  ls -1 "$EINGANG" 2>/dev/null | grep -E "^$1-PROD-[0-9]{14}\.sql(\.gz)?$" | sort | tail -1 | sed "s|^|$EINGANG/|" || true
}
F_MPSWL=$(neuester kk_mpswl)
F_SWL=$(neuester kk_swl)

if [ -z "$F_MPSWL" ] && [ -z "$F_SWL" ]; then
  log "Keine neuen Dumps im Eingang."; exit 0
fi
if [ -z "$F_MPSWL" ] || [ -z "$F_SWL" ]; then
  DA="${F_MPSWL:-$F_SWL}"
  WARTEZEIT=$(( ($(date +%s) - $(ankunft "$DA")) / 60 ))
  if [ "$WARTEZEIT" -lt "$WARTEN_AUF_PARTNER_MINUTEN" ]; then
    log "Nur $(basename "$DA") da, warte auf den zweiten Dump (seit ${WARTEZEIT} min)."; exit 0
  fi
  PAAR=("$DA")
  fehler "Seit ${WARTEZEIT} min nur $(basename "$DA") vorhanden — zweiter Dump fehlt."
fi

TAG_MPSWL=$(basename "$F_MPSWL" | sed -E 's/.*-PROD-([0-9]{8}).*/\1/')
TAG_SWL=$(basename "$F_SWL"     | sed -E 's/.*-PROD-([0-9]{8}).*/\1/')
if [ "$TAG_MPSWL" != "$TAG_SWL" ]; then
  # Der ältere wartet nicht ewig: wenn der jüngere Tag auch nach der Wartezeit
  # keinen Partner hat, schlägt der Fall oben beim nächsten Lauf auf.
  log "Dumps von verschiedenen Tagen ($TAG_MPSWL / $TAG_SWL) — warte auf passendes Paar."
  ALT="$F_MPSWL"; [ "$TAG_SWL" \< "$TAG_MPSWL" ] && ALT="$F_SWL"
  mv "$ALT" "$ARCHIV/" && log "Älteren Dump ohne Partner archiviert: $(basename "$ALT")"
  exit 0
fi

# Ältere Dumps, die über Nacht liegen geblieben sind, werden übersprungen
for alt in $(ls -1 "$EINGANG" | grep -E '^kk_(mpswl|swl)-PROD-[0-9]{14}\.sql(\.gz)?$' | sort || true); do
  p="$EINGANG/$alt"
  if [ "$p" != "$F_MPSWL" ] && [ "$p" != "$F_SWL" ]; then
    mv "$p" "$ARCHIV/" && log "Übersprungen (es gibt einen neueren): $alt"
  fi
done

# --- 2. Vollständigkeit ----------------------------------------------
for f in "$F_MPSWL" "$F_SWL"; do
  ALTER_MIN=$(( ($(date +%s) - $(ankunft "$f")) / 60 ))
  if [ "$ALTER_MIN" -lt "$RUHEZEIT_MINUTEN" ]; then
    log "$(basename "$f") wurde vor ${ALTER_MIN} min noch geschrieben — nächster Lauf."; exit 0
  fi
done
PAAR=("$F_MPSWL" "$F_SWL")

for f in "$F_MPSWL" "$F_SWL"; do
  [ -r "$f" ] || fehler "$(basename "$f") ist nicht lesbar. Der Import läuft als uid $(id -u); die Datei gehört $(stat -c '%U:%G mit %a' "$f" 2>/dev/null || stat -f '%Su:%Sg mit %Lp' "$f"). Abhilfe: chmod 644 auf die Datei (das Verzeichnis bleibt geschlossen)."
done

for f in "$F_MPSWL" "$F_SWL"; do
  ENDE=$(lesen "$f" | tail -c 2000)
  [[ "$ENDE" == *"-- PostgreSQL database dump complete"* ]] \
    || fehler "$(basename "$f") ist unvollständig (Endmarke von pg_dump fehlt)."
done

H_MPSWL=$(sha256 "$F_MPSWL"); H_SWL=$(sha256 "$F_SWL")
if grep -q "$H_MPSWL" "$STATUS/importiert.txt" && grep -q "$H_SWL" "$STATUS/importiert.txt"; then
  log "Dieses Paar wurde bereits importiert — archiviert, nichts weiter zu tun."
  mv "$F_MPSWL" "$F_SWL" "$ARCHIV/"; PAAR=(); exit 0
fi
log "Importiere Paar vom $TAG_MPSWL: $(basename "$F_MPSWL"), $(basename "$F_SWL")"

# --- 3. In <db>_neu einspielen ---------------------------------------
# Die Dumps stammen aus PostgreSQL 17 und enthalten PG17-spezifische Objekte
# (u. a. metric_helpers.pg_stat_statements). Älter geht nicht.
SERVER_VERSION=$(sql postgres "SHOW server_version_num")
[ "$SERVER_VERSION" -ge 170000 ] || fehler "PostgreSQL 17 oder neuer nötig, gefunden: $SERVER_VERSION."

rollen_sicherstellen() {
  local rolle
  for rolle in $DUMP_ROLLEN; do
    if [ "$(sql postgres "SELECT count(*) FROM pg_roles WHERE rolname = '$rolle'")" = 0 ]; then
      "${PSQL[@]}" -d postgres -c "CREATE ROLE \"$rolle\" NOLOGIN"
      log "  Rolle $rolle angelegt (kommt in den Dumps als Eigentümer vor, kein Login)"
    fi
  done
}

einspielen() {  # einspielen <ziel-db> <datei>
  local ziel="$1_neu" datei="$2" start=$SECONDS
  "${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS \"$ziel\" WITH (FORCE)"
  "${PSQL[@]}" -d postgres -c "CREATE DATABASE \"$ziel\" TEMPLATE template0 ENCODING 'UTF8'"
  # Rohdaten mit Personenbezug: nur postgres (und über ihn die Reporting-Sichten)
  "${PSQL[@]}" -d postgres -c "REVOKE CONNECT, TEMPORARY ON DATABASE \"$ziel\" FROM PUBLIC"
  lesen "$datei" | "${PSQL[@]}" --single-transaction -d "$ziel" >/dev/null \
    || fehler "Einspielen von $(basename "$datei") nach $ziel fehlgeschlagen."
  vacuumdb -q --analyze-only -d "$ziel"
  log "  $ziel eingespielt ($((SECONDS - start)) s)"
}
rollen_sicherstellen
einspielen "$DB_MPSWL" "$F_MPSWL"
einspielen "$DB_SWL"   "$F_SWL"

# --- 4. Plausibilität ------------------------------------------------
zahl() { sql "$1" "SELECT count(*) FROM $2" 2>/dev/null || echo ""; }
pruefe_menge() {  # pruefe_menge <db> <tabelle> <minimum>
  local db="$1" tab="$2" min="$3" neu alt
  neu=$(zahl "${db}_neu" "$tab")
  [ -n "$neu" ] || fehler "$db: Tabelle $tab fehlt im neuen Dump."
  [ "$neu" -ge "$min" ] || fehler "$db.$tab: nur $neu Zeilen (Minimum $min)."
  if db_da "$db"; then
    alt=$(zahl "$db" "$tab")
    if [ -n "$alt" ] && [ "$alt" -gt 0 ] && [ $(( neu * 100 )) -lt $(( alt * (100 - MAX_RUECKGANG_PROZENT) )) ]; then
      fehler "$db.$tab: Rückgang von $alt auf $neu Zeilen (mehr als ${MAX_RUECKGANG_PROZENT} %)."
    fi
    log "  $db.$tab: $alt -> $neu"
  else
    log "  $db.$tab: $neu (Erstimport)"
  fi
  MENGEN="${MENGEN:+$MENGEN, }\"$db.$tab\": $neu"
}
MENGEN=""
pruefe_menge "$DB_MPSWL" customers                  "$MIN_KUNDEN"
pruefe_menge "$DB_MPSWL" orders                     "$MIN_BESTELLUNGEN"
pruefe_menge "$DB_MPSWL" abo_berechtigungen_luebeck 1
pruefe_menge "$DB_SWL"   orders                     "$MIN_BESTELLUNGEN"
pruefe_menge "$DB_SWL"   orders_products            "$MIN_BESTELLUNGEN"
pruefe_menge "$DB_SWL"   products                   1

# --- 5. Austausch ----------------------------------------------------
tauschen() {  # <db> -> <db>_alt, <db>_neu -> <db>
  local db="$1" versuch
  "${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS \"${db}_alt\" WITH (FORCE)"
  for versuch in 1 2 3 4 5; do
    if "${PSQL[@]}" -d postgres 2>/dev/null <<SQL
SELECT count(pg_terminate_backend(pid)) AS beendet FROM pg_stat_activity
 WHERE datname IN ('$db', '${db}_neu') AND pid <> pg_backend_pid() \gset
DO \$\$ BEGIN
  IF EXISTS (SELECT FROM pg_database WHERE datname = '$db') THEN
    EXECUTE 'ALTER DATABASE "$db" RENAME TO "${db}_alt"';
  END IF;
END \$\$;
ALTER DATABASE "${db}_neu" RENAME TO "$db";
SQL
    then
      AKTIV_TAUSCH="$db $AKTIV_TAUSCH"; return 0
    fi
    sleep 1
  done
  fehler "Austausch von $db nach 5 Versuchen nicht möglich (Verbindungen?)."
}
zuruecktauschen() {  # <db> -> weg, <db>_alt -> <db>
  local db="$1"
  log "  Rückbau: $db wird auf den Stand vor dem Import zurückgesetzt"
  "${PSQL[@]}" -d postgres <<SQL
SELECT count(pg_terminate_backend(pid)) AS beendet FROM pg_stat_activity
 WHERE datname IN ('$db', '${db}_alt') AND pid <> pg_backend_pid() \gset
DROP DATABASE IF EXISTS "$db" WITH (FORCE);
ALTER DATABASE "${db}_alt" RENAME TO "$db";
SQL
}

tauschen "$DB_MPSWL"
tauschen "$DB_SWL"
log "  Datenbanken ausgetauscht"

# --- 6. Rauchtest über die Reporting-Sichten --------------------------
if db_da "$DB_REPORTING"; then
  ERGEBNIS=$(sql "$DB_REPORTING" "$RAUCHTEST_SQL" 2>&1) \
    || fehler "Rauchtest fehlgeschlagen: $ERGEBNIS"
  [[ "$ERGEBNIS" =~ ^[0-9]+$ ]] && [ "$ERGEBNIS" -gt 0 ] \
    || fehler "Rauchtest liefert '$ERGEBNIS' statt einer Zahl > 0."
  log "  Rauchtest ok: $ERGEBNIS Zeilen über $DB_REPORTING"
else
  # Ersteinrichtung: Die Reporting-Datenbank wird erst NACH dem ersten Import angelegt
  ERGEBNIS=null
  log "  Rauchtest übersprungen: $DB_REPORTING existiert noch nicht (Ersteinrichtung)"
fi
AKTIV_TAUSCH=""   # ab hier gilt der Import

# --- 7. Abschluss ----------------------------------------------------
echo "$TAG_MPSWL $H_MPSWL $(basename "$F_MPSWL")" >> "$STATUS/importiert.txt"
echo "$TAG_SWL $H_SWL $(basename "$F_SWL")"       >> "$STATUS/importiert.txt"

# Ab hier gilt der Import. Klappt das Archivieren nicht (z. B. fehlendes
# Schreibrecht im Eingang), ist das eine Warnung — kein Grund, einen gültigen
# Import als gescheitert darzustellen. Die Dumps bleiben dann liegen und werden
# beim nächsten Lauf als "bereits importiert" erkannt.
PAAR=()
if mv "$F_MPSWL" "$F_SWL" "$ARCHIV/" 2>/dev/null; then
  log "  Dumps archiviert"
else
  log "  WARNUNG: Dumps konnten nicht nach $ARCHIV verschoben werden."
  log "  WARNUNG: Fehlt dem Import (uid $(id -u)) das Schreibrecht im Eingang? Sie bleiben liegen."
fi

cat > "$STATUS/letzter_import.json" <<EOF
{"zeitpunkt": "$(date '+%Y-%m-%dT%H:%M:%S%z')", "dump_tag": "$TAG_MPSWL",
 "dateien": ["$(basename "$F_MPSWL")", "$(basename "$F_SWL")"],
 "mengen": {$MENGEN}, "rauchtest": $ERGEBNIS}
EOF

# Dumps enthalten Personendaten: nicht länger als nötig aufheben
find "$ARCHIV" "$FEHLER" -type f -name 'kk_*-PROD-*' -ctime +"$ARCHIV_TAGE" -print -delete | sed 's/^/  gelöscht: /'
if db_da "${DB_MPSWL}_alt"; then
  log "Import erfolgreich. Vorheriger Stand liegt als ${DB_MPSWL}_alt / ${DB_SWL}_alt bereit."
else
  log "Import erfolgreich (Erstimport)."
fi
