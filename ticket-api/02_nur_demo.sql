-- =====================================================================
-- NUR DEMO — niemals in Produktion ausführen.
-- =====================================================================
-- Die Demo-Datenbank ist anonymisiert (metabase-setup/01_anonymisieren.sql).
-- Damit die API trotzdem mit echten Adressen gesucht werden kann, rechnet
-- der Suchschlüssel die Eingabe mit derselben Formel in den Ersatzwert um.
-- Protokolliert wird weiterhin die eingegebene Adresse.
-- =====================================================================
CREATE OR REPLACE FUNCTION api_intern.suchschluessel(p_email text)
RETURNS text LANGUAGE sql IMMUTABLE
AS $$
  SELECT 'nutzer' || substr(md5(lower(btrim(p_email))), 1, 10) || '@example.invalid'
$$;
ALTER FUNCTION api_intern.suchschluessel(text) OWNER TO api_eigentuemer;
REVOKE ALL ON FUNCTION api_intern.suchschluessel(text) FROM PUBLIC;
