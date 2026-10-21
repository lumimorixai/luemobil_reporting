-- =====================================================================
-- Zusatz-Anonymisierung, nur für kk_mpswl
-- Setzt 01_anonymisieren.sql voraus (Hilfsfunktionen).
-- =====================================================================

-- --- Abo-Berechtigungen ----------------------------------------------
-- Die E-Mail wird mit derselben Funktion ersetzt wie in customers.
-- Dadurch bleibt der Abgleich Bestand <-> App-Konto exakt erhalten.
-- Name und Geburtsdatum wie beim Fahrgast im Ticket (anon_person, siehe 01),
-- damit der Abgleich Ticket <-> Bestand über die Person erhalten bleibt.
UPDATE public.abo_berechtigungen_luebeck SET
  first_name     = anon_vorname(anon_person(first_name, last_name)),
  last_name      = anon_nachname(anon_person(first_name, last_name)),
  birthday       = anon_gebdat(birthday::timestamp, anon_person(first_name, last_name))::date,
  phone          = anon_telefon(phone),
  street         = anon_strasse(street),
  street_number  = anon_hausnr(street_number),
  -- entitlement_id trägt die Kundennummer als Präfix: Präfix tauschen, Rest behalten
  entitlement_id = anon_kundennr(customer_number) || substr(entitlement_id, length(customer_number) + 1),
  customer_number = anon_kundennr(customer_number),
  customer_photo = NULL,
  barcode        = NULL,
  stb_hex        = NULL,
  email          = anon_email(email);

-- --- Abo-Codes -------------------------------------------------------
-- Format LUB#<Nummer>#<lfd>, stillgelegte Abos R-<Datum>-<Nr>-LUB#<Nummer>#<lfd>.
-- Die Nummer ersetzen, Präfix und laufende Nummer behalten. custom3 trägt
-- die Kundennummer des Bestands: gleich ersetzen wie customer_number oben.
UPDATE public.kk_subscription SET
  subscription_code = substring(subscription_code FROM '^(.*?)LUB#') || 'LUB#'
                      || anon_kundennr(split_part(substring(subscription_code FROM 'LUB#.*$'), '#', 2))
                      || '#' || split_part(substring(subscription_code FROM 'LUB#.*$'), '#', 3)
WHERE subscription_code LIKE '%LUB#%';
UPDATE public.kk_subscription SET custom3 = anon_kundennr(custom3)
WHERE coalesce(custom3, '') <> '';

-- --- Kundentags mit personenbezogenem Inhalt -------------------------
UPDATE public.kk_customers_to_tag SET tag_value = anon_email(tag_value)
  WHERE name = 'OVS_EMAIL_ADDRESS';
UPDATE public.kk_customers_to_tag SET tag_value = '<entfernt>'
  WHERE name IN ('OVS_PASSWORD','IBAN','BIC');
UPDATE public.kk_customers_to_tag SET tag_value = anon_kundennr(tag_value)
  WHERE name = 'OVS_CUSTOMER_ID';
-- Ab Oktober 2026: Fahrzeugdaten (Kennzeichen) und PayOne-Kundennummer
UPDATE public.kk_customers_to_tag SET tag_value = '<entfernt>'
  WHERE name = 'CUSTOMER_VEHICLE_DATA';
UPDATE public.kk_customers_to_tag SET tag_value = anon_kundennr(tag_value)
  WHERE name = 'PAYONE_CUSTOMER_ID';

-- --- Migrationstabelle der Abo-Codes (Ticket LUB-3873) ---------------
-- Enthält zugeordnete Namen, für keine Auswertung nötig
DO $$ BEGIN
  IF to_regclass('public.lub_3873_subscription_code_migration') IS NOT NULL THEN
    TRUNCATE public.lub_3873_subscription_code_migration;
  END IF;
END $$;

-- --- SSO-Token entwerten ---------------------------------------------
UPDATE public.kk_sso SET sesskey = 'demo-' || md5(sesskey), secret_key = 'demo';

-- --- Gerätekennungen in orders.custom1 --------------------------------
-- deviceId wird pseudonymisiert, Plattformformat (UUID vs. Hex) bleibt
-- erhalten, damit die iOS/Android-Auswertung weiter funktioniert.
UPDATE public.orders SET custom1 = jsonb_set(
    custom1::jsonb, '{deviceId}',
    to_jsonb(CASE WHEN length(custom1::jsonb ->> 'deviceId') = 36
      THEN upper(substr(md5(custom1::jsonb ->> 'deviceId'),1,8) || '-' ||
                 substr(md5(custom1::jsonb ->> 'deviceId'),9,4) || '-' ||
                 substr(md5(custom1::jsonb ->> 'deviceId'),13,4) || '-' ||
                 substr(md5(custom1::jsonb ->> 'deviceId'),17,4) || '-' ||
                 substr(md5(custom1::jsonb ->> 'deviceId'),21,12))
      ELSE substr(md5(custom1::jsonb ->> 'deviceId'), 1, 16) END)
  )::text
WHERE custom1 IS NOT NULL AND custom1 <> '' AND (custom1::jsonb ? 'deviceId');

-- --- Kontrolle: die Kennzahlen müssen unverändert sein ---------------
-- Sollwerte: Produktiv-Dumps vom 21.10.2026 vor der Anonymisierung
\echo '--- Prüfung nach Anonymisierung (Sollwerte in Klammern) ---'
SELECT 'App-Konten (7529)'        AS kennzahl, count(*)::text AS wert FROM public.customers
UNION ALL SELECT 'Berechtigungen (8380)', count(*)::text FROM public.abo_berechtigungen_luebeck
UNION ALL SELECT 'Aktiviert (5304)',
  (SELECT count(DISTINCT lower(a.email))::text FROM public.abo_berechtigungen_luebeck a
     JOIN public.customers c ON lower(c.customers_email_address) = lower(a.email))
UNION ALL SELECT 'Bestellungen (8617)', count(*)::text FROM public.orders
UNION ALL SELECT 'Abos (5033)', count(*)::text FROM public.kk_subscription
UNION ALL SELECT 'Distinct Geräte (4961)',
  (SELECT count(DISTINCT custom1::jsonb ->> 'deviceId')::text FROM public.orders WHERE custom1 IS NOT NULL);
