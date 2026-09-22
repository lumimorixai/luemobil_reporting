-- =====================================================================
-- LüMobil — Ticket-API für das Hilfecenter: Datenbankteil
-- =====================================================================
-- Wird in "lue_reporting" ausgeführt, von einem Administrator.
-- Aufruf über einrichten.sh (setzt :db_passwort).
--
-- Rollenmodell — wer darf was:
--
--   api_zugang        LOGIN, NOINHERIT. Damit meldet sich PostgREST an.
--                     Darf selbst nichts, kann nur in "hilfecenter" wechseln.
--   hilfecenter       Die Rolle aus dem Token. Darf GENAU EINE Funktion
--                     ausführen. Keine Rechte auf Tabellen oder Views.
--   api_eigentuemer   Besitzt die Funktionen. Darf rpt.bestellung und
--                     rpt.bestellposition lesen und ins Protokoll schreiben.
--                     Sonst nichts — insbesondere kein Superuser.
--
-- "Nur lesend" heißt: Der API-Nutzer kann keine einzige Zeile anlegen,
-- ändern oder löschen. Die einzige Schreibstelle ist das Abfrageprotokoll,
-- und das schreibt die Funktion selbst, ohne dass der Aufrufer Einfluss hat.
--
-- Idempotent: kann beliebig oft ausgeführt werden.
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- --- Rollen ----------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_eigentuemer') THEN
    CREATE ROLE api_eigentuemer NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hilfecenter') THEN
    CREATE ROLE hilfecenter NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_zugang') THEN
    CREATE ROLE api_zugang LOGIN NOINHERIT;
  END IF;
END $$;

ALTER ROLE api_zugang PASSWORD :'db_passwort';
ALTER ROLE api_zugang CONNECTION LIMIT 20;
GRANT hilfecenter TO api_zugang;

-- Schutz vor teuren Abfragen: PostgREST übernimmt Rolleneinstellungen
ALTER ROLE hilfecenter SET statement_timeout = '5s';

-- --- Schemata --------------------------------------------------------
-- "api" ist das einzige Schema, das PostgREST veröffentlicht.
-- "protokoll" ist von außen unsichtbar.
CREATE SCHEMA IF NOT EXISTS api;
CREATE SCHEMA IF NOT EXISTS protokoll;

REVOKE ALL ON SCHEMA api, protokoll FROM PUBLIC;
GRANT USAGE ON SCHEMA api        TO hilfecenter, api_eigentuemer;
GRANT USAGE ON SCHEMA protokoll  TO hilfecenter, api_eigentuemer;  -- nur für die Tokenprüfung
GRANT USAGE ON SCHEMA rpt        TO api_eigentuemer;

-- Die Funktion liest nur diese beiden Sichten
GRANT SELECT ON rpt.bestellung, rpt.bestellposition TO api_eigentuemer;

-- --- Token-Register --------------------------------------------------
-- Ein Token je Anwendung. Gespeichert wird nur die Kennung (jti), nie
-- das Token selbst. Sperren = gesperrt_am setzen, wirkt sofort.
CREATE TABLE IF NOT EXISTS protokoll.token (
  jti           uuid        PRIMARY KEY,
  anwendung     text        NOT NULL,
  ausgestellt   timestamptz NOT NULL DEFAULT now(),
  gueltig_bis   timestamptz NOT NULL,
  gesperrt_am   timestamptz,
  bemerkung     text
);

-- --- Abfrageprotokoll ------------------------------------------------
-- Wer hat wann nach wem gesucht. Enthält personenbezogene Daten:
-- nur Administratoren dürfen lesen, Aufbewahrung siehe protokoll.aufraeumen().
CREATE TABLE IF NOT EXISTS protokoll.abfrage (
  id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  zeitpunkt     timestamptz NOT NULL DEFAULT now(),
  jti           uuid,
  anwendung     text,
  bearbeiter    text,       -- optional: Header "X-Bearbeiter" der Anwendung
  ip            text,
  email_gesucht text        NOT NULL,
  treffer       int         NOT NULL
);
CREATE INDEX IF NOT EXISTS abfrage_zeitpunkt_idx ON protokoll.abfrage (zeitpunkt);

REVOKE ALL ON protokoll.token, protokoll.abfrage FROM PUBLIC, hilfecenter, api_zugang;
GRANT SELECT ON protokoll.token   TO api_eigentuemer;
GRANT INSERT ON protokoll.abfrage TO api_eigentuemer;

-- --- Tokenprüfung vor jeder Anfrage ----------------------------------
-- PostgREST prüft Signatur, Ablauf und Zielgruppe (aud) selbst.
-- Hier kommt dazu: Ist das Token registriert und nicht gesperrt?
CREATE OR REPLACE FUNCTION protokoll.token_pruefen()
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_jti text := nullif(current_setting('request.jwt.claims', true), '')::json ->> 'jti';
BEGIN
  IF v_jti IS NULL OR NOT EXISTS (
       SELECT FROM protokoll.token t
       WHERE t.jti::text = v_jti
         AND t.gesperrt_am IS NULL
         AND t.gueltig_bis > now())
  THEN
    RAISE SQLSTATE 'PGRST' USING
      message = '{"code":"TOKEN","message":"Token unbekannt, gesperrt oder abgelaufen","details":null,"hint":null}',
      detail  = '{"status":401,"headers":{"WWW-Authenticate":"Bearer"}}';
  END IF;
END $$;

ALTER FUNCTION protokoll.token_pruefen() OWNER TO api_eigentuemer;
REVOKE ALL ON FUNCTION protokoll.token_pruefen() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION protokoll.token_pruefen() TO hilfecenter;

-- --- Suchschlüssel aus der E-Mail -----------------------------------
-- Produktion: nur normalisieren. 02_nur_demo.sql ersetzt diese Funktion
-- in der Demo, weil dort die E-Mails anonymisiert sind.
CREATE SCHEMA IF NOT EXISTS api_intern;
REVOKE ALL ON SCHEMA api_intern FROM PUBLIC;
GRANT USAGE ON SCHEMA api_intern TO api_eigentuemer;

DO $$
BEGIN
  IF to_regprocedure('api_intern.suchschluessel(text)') IS NULL THEN
    CREATE FUNCTION api_intern.suchschluessel(p_email text)
    RETURNS text LANGUAGE sql IMMUTABLE
    AS 'SELECT lower(btrim(p_email))';
  END IF;
END $$;

ALTER FUNCTION api_intern.suchschluessel(text) OWNER TO api_eigentuemer;
REVOKE ALL ON FUNCTION api_intern.suchschluessel(text) FROM PUBLIC;

-- --- Die eigentliche Schnittstelle -----------------------------------
-- VOLATILE, weil sie ins Protokoll schreibt. PostgREST führt sie deshalb
-- nur per POST aus — gewollt, so steht die E-Mail im Body statt in der URL.
DROP FUNCTION IF EXISTS api.tickets_fuer_email(text);
CREATE FUNCTION api.tickets_fuer_email(p_email text)
RETURNS TABLE (
  gekauft_am     timestamp,
  bestellnummer  text,
  produkt        text,
  sku            text,
  menge          int,
  preis_brutto   numeric,
  status         text,
  erfolgreich    boolean
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_email   text := lower(btrim(p_email));
  v_claims  json := nullif(current_setting('request.jwt.claims', true), '')::json;
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_treffer int;
BEGIN
  IF v_email IS NULL OR length(v_email) > 254 OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Ungültige E-Mail-Adresse' USING ERRCODE = '22023';  -- -> HTTP 400
  END IF;

  RETURN QUERY
    SELECT b.gekauft_am,
           b.bestellnummer::text,
           p.produkt::text,
           p.sku::text,
           p.menge,
           p.einzelpreis_brutto,
           p.status::text,
           p.erfolgreich
    FROM rpt.bestellposition p
    JOIN rpt.bestellung b ON b.bestellung_id = p.bestellung_id
    WHERE p.kunde_email = api_intern.suchschluessel(v_email)
    ORDER BY b.gekauft_am DESC
    LIMIT 500;

  GET DIAGNOSTICS v_treffer = ROW_COUNT;

  INSERT INTO protokoll.abfrage (jti, anwendung, bearbeiter, ip, email_gesucht, treffer)
  VALUES ((v_claims ->> 'jti')::uuid,
          v_claims ->> 'anwendung',
          left(v_headers ->> 'x-bearbeiter', 200),
          v_headers ->> 'x-real-ip',
          v_email,
          v_treffer);
END $$;

ALTER FUNCTION api.tickets_fuer_email(text) OWNER TO api_eigentuemer;
REVOKE ALL ON FUNCTION api.tickets_fuer_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.tickets_fuer_email(text) TO hilfecenter;

COMMENT ON FUNCTION api.tickets_fuer_email(text) IS
  'Alle Ticketpositionen zu einer E-Mail-Adresse, neueste zuerst. Groß-/Kleinschreibung und Leerzeichen der E-Mail sind egal. Jede Abfrage wird protokolliert.';

-- --- Aufbewahrung des Protokolls -------------------------------------
-- Vorschlag 12 Monate; mit dem Datenschutz abstimmen. Aufruf z. B. monatlich.
CREATE OR REPLACE FUNCTION protokoll.aufraeumen(p_monate int DEFAULT 12)
RETURNS bigint
LANGUAGE sql
AS $$
  WITH weg AS (
    DELETE FROM protokoll.abfrage
    WHERE zeitpunkt < now() - make_interval(months => p_monate)
    RETURNING 1)
  SELECT count(*) FROM weg;
$$;
REVOKE ALL ON FUNCTION protokoll.aufraeumen(int) FROM PUBLIC;

-- PostgREST neu einlesen lassen, falls es läuft
NOTIFY pgrst, 'reload schema';
