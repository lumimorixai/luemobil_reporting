-- =====================================================================
-- LüMobil — Datenbanken und Rollen für Metabase auf dem Server
-- =====================================================================
-- Aufruf (als postgres, idempotent):
--   sudo -u postgres psql -d lue_reporting \
--     -v pw_app=<passwort> -v pw_leser=<passwort> -v eigentuemer=postgres \
--     -f metabase_datenbank.sql
--
-- Zwei getrennte Zugänge:
--   metabase_app    besitzt die Datenbank metabase_app (Dashboards, Konten,
--                   Einstellungen von Metabase). Darf sonst nichts.
--   metabase_leser  liest die Reporting-Sichten rpt.* in lue_reporting.
--                   Nur lesen, nichts anderes.
--
-- Der nächtliche Import tauscht nur kk_mpswl/kk_swl aus. lue_reporting und
-- metabase_app bleiben unberührt, die Rechte hier also auch.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- --- Rollen ----------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'metabase_app') THEN
    CREATE ROLE metabase_app LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'metabase_leser') THEN
    CREATE ROLE metabase_leser LOGIN;
  END IF;
END $$;

ALTER ROLE metabase_app   PASSWORD :'pw_app'   CONNECTION LIMIT 30;
ALTER ROLE metabase_leser PASSWORD :'pw_leser' CONNECTION LIMIT 15;

-- Auch ein Fehler in einer Metabase-Frage kann nichts verändern
ALTER ROLE metabase_leser SET default_transaction_read_only = on;
ALTER ROLE metabase_leser SET statement_timeout = '120s';

-- --- Anwendungsdatenbank von Metabase --------------------------------
SELECT 'CREATE DATABASE metabase_app OWNER metabase_app ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'metabase_app') \gexec
REVOKE CONNECT ON DATABASE metabase_app FROM PUBLIC;
GRANT  CONNECT ON DATABASE metabase_app TO metabase_app;

-- --- Lesezugriff auf die Reporting-Sichten ---------------------------
GRANT CONNECT ON DATABASE lue_reporting TO metabase_leser;
GRANT USAGE  ON SCHEMA rpt TO metabase_leser;
GRANT SELECT ON ALL TABLES IN SCHEMA rpt TO metabase_leser;

-- Sichten, die später neu angelegt werden (metabase-setup/*.sql mit
-- DROP … CASCADE), bekommen das Leserecht automatisch.
ALTER DEFAULT PRIVILEGES FOR ROLE :"eigentuemer" IN SCHEMA rpt
  GRANT SELECT ON TABLES TO metabase_leser;
