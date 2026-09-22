#!/bin/bash
# Schickt eine Mail, wenn ein LüMobil-Dienst fehlgeschlagen ist.
# Aufruf durch systemd: OnFailure=luemobil-meldung@%n.service
# Braucht ein funktionierendes "mail" (z. B. Paket bsd-mailx + msmtp oder postfix).
set -uo pipefail
DIENST="${1:?Dienstname}"
. /etc/luemobil/import.conf
EMPFAENGER="${MELDUNG_AN:?MELDUNG_AN in /etc/luemobil/import.conf setzen}"

{
  echo "Der Dienst $DIENST auf $(hostname -f) ist fehlgeschlagen."
  echo "Die bisherigen Daten sind weiter aktiv (der Import tauscht nur bei Erfolg aus)."
  echo
  echo "Letzte Protokollzeilen:"
  echo "----------------------------------------------------------------"
  journalctl -u "$DIENST" -n 40 --no-pager -o short-iso
  echo "----------------------------------------------------------------"
  echo "Vorgehen: siehe BETRIEBSHANDBUCH.md, Abschnitt Störungen."
} | mail -s "[LüMobil] FEHLER: $DIENST auf $(hostname -s)" "$EMPFAENGER"
