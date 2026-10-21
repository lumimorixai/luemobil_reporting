# Werkzeug-Abbild für den nächtlichen Import und die Sicherung.
# Basis ist dasselbe PostgreSQL wie im Hilfecenter-Stack, damit psql, pg_dump
# und vacuumdb zur Serverversion passen.
FROM postgres:17-alpine

# bash für die Skripte, coreutils/findutils für stat, sha256sum und find -ctime,
# unzip (Info-ZIP, nicht das aus busybox: -t und -Z1) für die ZIP-Lieferung,
# zip nur für den Abnahmetest, python3 für die Metabase-Skripte (Dienst reports)
RUN apk add --no-cache bash coreutils findutils unzip zip python3

COPY import.sh sichern.sh test_import.sh /opt/luemobil/
RUN chmod 755 /opt/luemobil/import.sh /opt/luemobil/sichern.sh /opt/luemobil/test_import.sh

# Läuft als postgres (uid 70) — die gemounteten Verzeichnisse müssen ihm gehören,
# siehe BETRIEBSHANDBUCH.md, Abschnitt 4.2.
USER postgres
ENTRYPOINT ["/opt/luemobil/import.sh"]
