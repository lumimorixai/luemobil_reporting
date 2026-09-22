-- =====================================================================
-- LüMobil — Anonymisierung für die lokale Demo-Instanz
-- =====================================================================
-- Wird in JEDER der beiden Datenbanken (kk_mpswl, kk_swl) ausgeführt.
--
-- Grundsatz: deterministisch über md5(). Dieselbe Original-E-Mail ergibt
-- in beiden Datenbanken denselben Ersatzwert. Nur so bleiben die Joins
-- zwischen Abo-Bestand und App-Konto erhalten und die Aktivierungsquote
-- von 1.698 stimmt weiterhin.
--
-- Erhalten bleiben: PLZ, Ort, alle Beträge, Zeitstempel, Status,
-- Produktbezüge, Geburtsjahr. Ersetzt werden: Name, E-Mail, Telefon,
-- Straße, Hausnummer, Tag/Monat des Geburtsdatums, Abo-Kundennummer.
-- =====================================================================

-- --- Hilfsfunktionen -------------------------------------------------

CREATE OR REPLACE FUNCTION anon_email(orig text) RETURNS text AS $$
  SELECT CASE WHEN orig IS NULL OR orig = '' THEN orig
    ELSE 'nutzer' || substr(md5(lower(btrim(orig))), 1, 10) || '@example.invalid' END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION anon_vorname(seed text) RETURNS text AS $$
  SELECT (ARRAY['Mara','Jonas','Lena','Finn','Hanna','Ole','Greta','Malte','Frieda','Bjarne',
                'Thies','Wiebke','Nils','Silke','Hauke','Antje','Sven','Imke','Lars','Meike',
                'Karsten','Birte','Torben','Anke','Jannik','Swantje','Enno','Femke','Bendix','Nele'])
         [ (('x' || substr(md5(coalesce(seed,'')), 1, 8))::bit(32)::bigint % 30) + 1 ];
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION anon_nachname(seed text) RETURNS text AS $$
  SELECT (ARRAY['Brinkmann','Petersen','Harms','Jessen','Struve','Lorenzen','Thomsen','Möller',
                'Carstens','Reimers','Boysen','Nissen','Clausen','Hinrichsen','Paulsen','Rohwer',
                'Steffen','Wulf','Bruhn','Dethlefsen','Gosch','Kruse','Timm','Voß','Sierks',
                'Ohlsen','Rathje','Sievers','Delfs','Bargmann'])
         [ (('x' || substr(md5(coalesce(seed,'') || 'n'), 1, 8))::bit(32)::bigint % 30) + 1 ];
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION anon_strasse(seed text) RETURNS text AS $$
  SELECT (ARRAY['Möllenkamp','Krähenteich','Wakenitzufer','Fackenburger Allee','Roeckstraße',
                'Kanalstraße','Travemünder Allee','Ratzeburger Allee','Moislinger Allee',
                'Schwartauer Allee','Katharinenstraße','Marlistraße','Padelügger Weg',
                'Steinrader Weg','Dornestraße','Brandenbaumer Landstraße'])
         [ (('x' || substr(md5(coalesce(seed,'') || 's'), 1, 8))::bit(32)::bigint % 16) + 1 ];
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION anon_hausnr(seed text) RETURNS text AS $$
  SELECT ((('x' || substr(md5(coalesce(seed,'') || 'h'), 1, 8))::bit(32)::bigint % 120) + 1)::text;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION anon_telefon(seed text) RETURNS text AS $$
  SELECT CASE WHEN seed IS NULL OR seed = '' THEN seed
    ELSE '+4945155' || lpad(((('x' || substr(md5(seed || 't'), 1, 8))::bit(32)::bigint % 100000))::text, 5, '0') END;
$$ LANGUAGE sql IMMUTABLE;

-- Geburtsdatum: Jahr bleibt, Tag und Monat werden verschoben.
-- Die Altersverteilung im Dashboard bleibt damit korrekt.
CREATE OR REPLACE FUNCTION anon_gebdat(d timestamp, seed text) RETURNS timestamp AS $$
  SELECT CASE WHEN d IS NULL THEN NULL
    ELSE make_timestamp(extract(year from d)::int,
           ((('x' || substr(md5(coalesce(seed,'') || 'm'), 1, 8))::bit(32)::bigint % 12) + 1)::int,
           ((('x' || substr(md5(coalesce(seed,'') || 'd'), 1, 8))::bit(32)::bigint % 28) + 1)::int,
           0, 0, 0) END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION anon_kundennr(orig text) RETURNS text AS $$
  SELECT CASE WHEN orig IS NULL OR orig = '' THEN orig
    ELSE '39' || lpad(((('x' || substr(md5(orig || 'k'), 1, 8))::bit(32)::bigint % 1000000))::text, 6, '0') END;
$$ LANGUAGE sql IMMUTABLE;

-- --- customers -------------------------------------------------------
UPDATE public.customers SET
  customers_firstname   = anon_vorname(customers_email_address),
  customers_lastname    = anon_nachname(customers_email_address),
  customers_dob         = anon_gebdat(customers_dob, customers_email_address),
  customers_telephone   = anon_telefon(customers_telephone),
  customers_telephone_1 = anon_telefon(customers_telephone_1),
  customers_password    = '',
  customers_email_address = anon_email(customers_email_address)
WHERE customers_email_address IS NOT NULL;

-- --- address_book ----------------------------------------------------
UPDATE public.address_book SET
  entry_firstname      = anon_vorname(entry_firstname || entry_lastname),
  entry_lastname       = anon_nachname(entry_firstname || entry_lastname),
  entry_street_address = anon_strasse(entry_street_address) || ' ' || anon_hausnr(entry_street_address),
  entry_telephone      = anon_telefon(entry_telephone);

-- --- orders (Rechnungs- und Lieferanschrift) -------------------------
-- PLZ und Ort bleiben unverändert, sie tragen die Gebietsauswertung.
UPDATE public.orders SET
  customers_name           = anon_vorname(customers_email_address) || ' ' || anon_nachname(customers_email_address),
  delivery_name            = anon_vorname(customers_email_address) || ' ' || anon_nachname(customers_email_address),
  billing_name             = anon_vorname(customers_email_address) || ' ' || anon_nachname(customers_email_address),
  customers_street_address = anon_strasse(customers_street_address) || ' ' || anon_hausnr(customers_street_address),
  delivery_street_address  = anon_strasse(delivery_street_address)  || ' ' || anon_hausnr(delivery_street_address),
  billing_street_address   = anon_strasse(billing_street_address)   || ' ' || anon_hausnr(billing_street_address),
  customers_telephone      = anon_telefon(customers_telephone),
  delivery_telephone       = anon_telefon(delivery_telephone),
  billing_telephone        = anon_telefon(billing_telephone),
  delivery_email_address   = anon_email(delivery_email_address),
  billing_email_address    = anon_email(billing_email_address),
  cc_owner = NULL, cc_number = NULL, cc_cvv = NULL,
  customers_email_address  = anon_email(customers_email_address);

-- --- Sitzungsschlüssel entwerten -------------------------------------
UPDATE public.sessions SET sesskey = 'demo-' || md5(sesskey);
