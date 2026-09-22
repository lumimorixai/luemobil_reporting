-- =====================================================================
-- Zusatz-Anonymisierung, nur für kk_mpswl
-- Setzt 01_anonymisieren.sql voraus (Hilfsfunktionen).
-- =====================================================================

-- --- Abo-Berechtigungen ----------------------------------------------
-- Die E-Mail wird mit derselben Funktion ersetzt wie in customers.
-- Dadurch bleibt der Abgleich Bestand <-> App-Konto exakt erhalten.
UPDATE public.abo_berechtigungen_luebeck SET
  first_name     = anon_vorname(email),
  last_name      = anon_nachname(email),
  birthday       = anon_gebdat(birthday::timestamp, email)::date,
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
-- Format LUB#<OVS-Kundennummer>#<lfd>. Mittelteil ersetzen.
UPDATE public.kk_subscription SET
  subscription_code = 'LUB#' || anon_kundennr(split_part(subscription_code, '#', 2))
                      || '#' || split_part(subscription_code, '#', 3)
WHERE subscription_code LIKE 'LUB#%';

-- --- Kundentags mit personenbezogenem Inhalt -------------------------
UPDATE public.kk_customers_to_tag SET tag_value = anon_email(tag_value)
  WHERE name = 'OVS_EMAIL_ADDRESS';
UPDATE public.kk_customers_to_tag SET tag_value = '<entfernt>'
  WHERE name IN ('OVS_PASSWORD','IBAN','BIC');
UPDATE public.kk_customers_to_tag SET tag_value = anon_kundennr(tag_value)
  WHERE name = 'OVS_CUSTOMER_ID';

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
\echo '--- Prüfung nach Anonymisierung (Sollwerte in Klammern) ---'
SELECT 'App-Konten (2132)'        AS kennzahl, count(*)::text AS wert FROM public.customers
UNION ALL SELECT 'Berechtigungen (8267)', count(*)::text FROM public.abo_berechtigungen_luebeck
UNION ALL SELECT 'Aktiviert (1698)',
  (SELECT count(DISTINCT lower(a.email))::text FROM public.abo_berechtigungen_luebeck a
     JOIN public.customers c ON lower(c.customers_email_address) = lower(a.email))
UNION ALL SELECT 'Bestellungen (1551)', count(*)::text FROM public.orders
UNION ALL SELECT 'Aktive Abos (1459)', count(*)::text FROM public.kk_subscription
UNION ALL SELECT 'Distinct Geräte (1443)',
  (SELECT count(DISTINCT custom1::jsonb ->> 'deviceId')::text FROM public.orders WHERE custom1 IS NOT NULL);
