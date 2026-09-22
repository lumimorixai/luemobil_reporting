-- =====================================================================
-- LüMobil — Reporting-Datenbank
-- =====================================================================
-- Wird in der Datenbank "lue_reporting" ausgeführt.
--
-- Bindet kk_mpswl und kk_swl per postgres_fdw ein und legt darüber die
-- Auswertungssichten an. Metabase sieht danach nur noch das Schema
-- "rpt" und muss von den Fallen im Quellschema nichts wissen.
--
-- Gekapselte Fallen:
--   1. customers_id bedeutet in beiden Datenbanken NICHT dasselbe.
--      Verknüpft wird über orders.custom1 ->> 'externalOrderReference'
--      und auf Personenebene über kleingeschriebene, getrimmte E-Mail.
--   2. ot_total ist brutto, orders_products.final_price ist netto (7 %).
--   3. Status 3 = erfolgreich, 8 = abgebrochen. 1.459 Bestellungen
--      erreichten Status 3, Endstand sind 1.442.
--   4. Bestandsabgleich nur über lower(btrim(email)).
--   5. Geburtsdatum aus der Berechtigung, nicht aus dem App-Konto
--      (dort zu 82 % Platzhalter 1800-01-01).
--   6. Kundentags überleben gelöschte Kunden -> immer gegen customers joinen.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SCHEMA IF NOT EXISTS rpt;

-- --- Fremdserver -----------------------------------------------------
DROP SERVER IF EXISTS srv_mpswl CASCADE;
DROP SERVER IF EXISTS srv_swl   CASCADE;

CREATE SERVER srv_mpswl FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'localhost', port '5432', dbname 'kk_mpswl');
CREATE SERVER srv_swl FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'localhost', port '5432', dbname 'kk_swl');

CREATE USER MAPPING FOR CURRENT_USER SERVER srv_mpswl OPTIONS (user 'PGUSER_PLACEHOLDER');
CREATE USER MAPPING FOR CURRENT_USER SERVER srv_swl   OPTIONS (user 'PGUSER_PLACEHOLDER');

CREATE SCHEMA IF NOT EXISTS src_mpswl;
CREATE SCHEMA IF NOT EXISTS src_swl;

IMPORT FOREIGN SCHEMA public
  LIMIT TO (customers, customers_info, orders, orders_products, orders_total,
            orders_status, orders_status_history, kk_subscription, kk_customers_to_tag,
            abo_berechtigungen_luebeck, abo_import_file_hashes, ipn_history, sessions)
  FROM SERVER srv_mpswl INTO src_mpswl;

IMPORT FOREIGN SCHEMA public
  LIMIT TO (products, products_description, products_to_categories, categories_description,
            products_attributes, products_options, products_options_values,
            orders, orders_products, orders_total, customers_basket, kk_digital_download_1)
  FROM SERVER srv_swl INTO src_swl;

-- =====================================================================
-- rpt.produkt — Tarifkatalog mit Vertriebskanal
-- =====================================================================
CREATE OR REPLACE VIEW rpt.produkt AS
SELECT
  p.products_id                                   AS produkt_id,
  d.products_name                                 AS produkt,
  p.products_sku                                  AS sku,
  CASE c.categories_id WHEN '1' THEN 'ÖPNV'
                       WHEN '2' THEN 'Abo'
                       WHEN '3' THEN 'Fähre' END  AS kategorie,
  -- Vertriebskanal steckt als XML-Attribut in custom_attrs
  (p.custom_attrs LIKE '%attribute.payone%CDATA[true]%'
   OR p.custom_attrs ~ 'payone.{0,400}')          AS payone_faehig,
  CASE WHEN c.categories_id = '2' THEN 'Abo'
       WHEN c.categories_id = '3' THEN 'Fähre'
       ELSE 'Einzelticket' END                    AS vertriebskanal,
  p.products_status = 1                           AS aktiv,
  (SELECT count(*) FROM src_swl.products_attributes a
     WHERE a.products_id = p.products_id)         AS anzahl_preisstufen
FROM src_swl.products p
JOIN src_swl.products_description d
  ON d.products_id = p.products_id AND d.language_id = 2
LEFT JOIN src_swl.products_to_categories c
  ON c.products_id = p.products_id;

-- =====================================================================
-- rpt.bestellung — eine Zeile je Bestellung, Brutto und Netto getrennt
-- =====================================================================
CREATE OR REPLACE VIEW rpt.bestellung AS
SELECT
  o.orders_id                                        AS bestellung_id,
  o.orders_number                                    AS bestellnummer,
  o.date_purchased                                   AS gekauft_am,
  o.date_purchased::date                             AS kauftag,
  extract(hour FROM o.date_purchased)::int           AS kaufstunde,
  to_char(o.date_purchased, 'ID')::int               AS wochentag_nr,
  o.customers_id                                     AS kunde_id,
  lower(btrim(o.customers_email_address))            AS kunde_email,
  o.orders_status                                    AS status_id,
  s.orders_status_name                               AS status,
  o.orders_status = 3                                AS erfolgreich,
  o.orders_status = 8                                AS abgebrochen,
  coalesce(o.payment_module_code, 'unbekannt')       AS zahlungsmodul,
  o.payment_module_subcode                           AS zahlart,
  -- Falle 2: ot_total ist brutto
  (SELECT t.value FROM src_mpswl.orders_total t
     WHERE t.orders_id = o.orders_id AND t.class = 'ot_total')      AS umsatz_brutto,
  (SELECT t.value FROM src_mpswl.orders_total t
     WHERE t.orders_id = o.orders_id AND t.class = 'ot_tax')        AS steuer,
  (SELECT t.value FROM src_mpswl.orders_total t
     WHERE t.orders_id = o.orders_id AND t.class = 'ot_total')
  - coalesce((SELECT t.value FROM src_mpswl.orders_total t
     WHERE t.orders_id = o.orders_id AND t.class = 'ot_tax'), 0)    AS umsatz_netto,
  -- Gerät und Plattform aus dem JSON in custom1
  o.custom1::jsonb ->> 'deviceId'                    AS geraet_id,
  CASE WHEN length(o.custom1::jsonb ->> 'deviceId') = 36 THEN 'iOS'
       WHEN (o.custom1::jsonb ->> 'deviceId') IS NOT NULL THEN 'Android'
       ELSE 'unbekannt' END                          AS plattform,
  -- Falle 1: DAS ist der belastbare Schlüssel in die Shop-Datenbank
  (o.custom1::jsonb ->> 'externalOrderReference')::int AS shop_bestellung_id,
  -- Durchlaufzeit bis zur Ticketauslieferung
  (SELECT extract(epoch FROM
       min(h.date_added) FILTER (WHERE h.orders_status_id = 3)
     - min(h.date_added) FILTER (WHERE h.orders_status_id = 1))
     FROM src_mpswl.orders_status_history h WHERE h.orders_id = o.orders_id)
                                                     AS sekunden_bis_ticket
FROM src_mpswl.orders o
LEFT JOIN src_mpswl.orders_status s
  ON s.orders_status_id = o.orders_status AND s.language_id = 2;

-- =====================================================================
-- rpt.bestellposition — je verkauftem Ticket, mit Vertriebskanal
-- =====================================================================
CREATE OR REPLACE VIEW rpt.bestellposition AS
SELECT
  op.orders_products_id                    AS position_id,
  b.bestellung_id, b.kauftag, b.kunde_email,
  b.status, b.erfolgreich, b.abgebrochen,
  op.products_name                         AS produkt,
  op.products_sku                          AS sku,
  op.products_quantity                     AS menge,
  op.final_price                           AS einzelpreis_netto,
  round(op.final_price * 1.07, 2)          AS einzelpreis_brutto,
  op.final_price * op.products_quantity    AS positionswert_netto,
  pr.kategorie, pr.vertriebskanal
FROM src_mpswl.orders_products op
JOIN rpt.bestellung b ON b.bestellung_id = op.orders_id
LEFT JOIN rpt.produkt pr ON pr.sku = op.products_sku;

-- =====================================================================
-- rpt.kunde_360 — App-Konto, Abo-Bestand und Bestellverhalten in einem
-- =====================================================================
CREATE OR REPLACE VIEW rpt.kunde_360 AS
WITH bestand AS (
  -- Falle 5: das brauchbare Geburtsdatum kommt aus der Berechtigung
  SELECT lower(btrim(email)) AS email,
         min(customer_number)                       AS abo_kundennummer,
         min(zip_code)                              AS plz,
         min(city)                                  AS ort,
         min(product_number)                        AS bestandssegment,
         max(display_validity_end)                  AS berechtigt_bis,
         min(nullif(btrim(birthday),''))::date       AS geburtsdatum,
         count(*)                                   AS anzahl_berechtigungen
  FROM src_mpswl.abo_berechtigungen_luebeck
  WHERE email IS NOT NULL AND btrim(email) <> ''
  GROUP BY 1
),
bestellt AS (
  SELECT kunde_email,
         count(*)                                       AS bestellungen,
         count(*) FILTER (WHERE erfolgreich)            AS bestellungen_erfolgreich,
         sum(umsatz_brutto) FILTER (WHERE erfolgreich)  AS umsatz_brutto,
         min(kauftag)                                   AS erster_kauf,
         max(kauftag)                                   AS letzter_kauf
  FROM rpt.bestellung GROUP BY 1
)
SELECT
  c.customers_id                                   AS kunde_id,
  lower(btrim(c.customers_email_address))          AS kunde_email,
  c.customers_firstname || ' ' || c.customers_lastname AS name,
  c.email_verified = 1                             AS email_bestaetigt,
  ci.customers_info_date_created                   AS konto_seit,
  ci.customers_info_date_created::date             AS registriert_am,
  ci.customers_info_date_last_logon                AS letzter_login,
  -- Bestandsabgleich (Falle 4: nur über normalisierte E-Mail)
  bs.abo_kundennummer, bs.plz, bs.ort, bs.bestandssegment,
  bs.berechtigt_bis, bs.geburtsdatum,
  CASE WHEN bs.geburtsdatum IS NOT NULL
       THEN extract(year FROM age(bs.geburtsdatum::timestamp))::int END AS alter_jahre,
  (bs.email IS NOT NULL)                           AS hat_abo_berechtigung,
  coalesce(bt.bestellungen, 0)                     AS bestellungen,
  coalesce(bt.bestellungen_erfolgreich, 0)         AS bestellungen_erfolgreich,
  coalesce(bt.umsatz_brutto, 0)                    AS umsatz_brutto,
  bt.erster_kauf, bt.letzter_kauf,
  (bt.kunde_email IS NOT NULL)                     AS hat_gekauft,
  -- Falle 6: Tags nur über einen Join auf customers, nie allein zählen
  (SELECT max(t.tag_value) FROM src_mpswl.kk_customers_to_tag t
     WHERE t.customers_id = c.customers_id AND t.name = 'TOS_ACCEPTED_DATE') AS agb_zugestimmt_am,
  (SELECT max(t.tag_value) FROM src_mpswl.kk_customers_to_tag t
     WHERE t.customers_id = c.customers_id AND t.name = 'MARKETING_PREFERENCES') AS marketing_einwilligung,
  EXISTS (SELECT 1 FROM src_mpswl.kk_customers_to_tag t
     WHERE t.customers_id = c.customers_id AND t.name = 'ACCOUNT_DELETION_REQUESTED') AS loeschung_beantragt
FROM src_mpswl.customers c
LEFT JOIN src_mpswl.customers_info ci ON ci.customers_info_id = c.customers_id
LEFT JOIN bestand  bs ON bs.email = lower(btrim(c.customers_email_address))
LEFT JOIN bestellt bt ON bt.kunde_email = lower(btrim(c.customers_email_address));

-- =====================================================================
-- rpt.abo_berechtigung — Bestand mit Aktivierungskennzeichen
-- =====================================================================
CREATE OR REPLACE VIEW rpt.abo_berechtigung AS
SELECT
  a.id                                     AS berechtigung_id,
  a.entitlement_id                         AS berechtigungsnummer,
  a.customer_number                        AS abo_kundennummer,
  lower(btrim(a.email))                    AS kunde_email,
  a.first_name || ' ' || a.last_name       AS name,
  a.zip_code                               AS plz,
  a.city                                   AS ort,
  a.product_number                         AS bestandssegment,
  a.product_name                           AS produkt,
  a.price                                  AS preis,
  a.display_validity_begin                 AS gueltig_ab,
  a.display_validity_end                   AS gueltig_bis,
  nullif(btrim(a.birthday),'')::date       AS geburtsdatum,
  extract(year FROM age(nullif(btrim(a.birthday),'')::timestamp))::int AS alter_jahre,
  a.phone IS NOT NULL AND a.phone <> ''    AS telefon_bekannt,
  a.imported_at                            AS importiert_am,
  EXISTS (SELECT 1 FROM src_mpswl.customers c
          WHERE lower(btrim(c.customers_email_address)) = lower(btrim(a.email)))
                                           AS aktiviert
FROM src_mpswl.abo_berechtigungen_luebeck a;

-- =====================================================================
-- rpt.abo — laufende Abonnements
-- =====================================================================
CREATE OR REPLACE VIEW rpt.abo AS
SELECT
  s.kk_subscription_id            AS abo_id,
  s.subscription_code             AS abo_code,
  s.orders_id                     AS bestellung_id,
  s.customers_id                  AS kunde_id,
  s.products_sku                  AS sku,
  CASE s.products_sku WHEN '541' THEN 'Deutschlandticket 2. Kl'
                      WHEN '548' THEN 'Deutschlandticket Schule'
                      ELSE s.products_sku END AS produkt,
  s.start_date::date              AS laeuft_seit,
  s.next_billing_date::date       AS naechste_abrechnung,
  s.last_billing_date::date       AS letzte_abrechnung,
  s.active = 1                    AS aktiv,
  s.problem = 1                   AS stoerung,
  s.problem_description           AS stoerungstext,
  s.date_added                    AS angelegt_am
FROM src_mpswl.kk_subscription s;

-- =====================================================================
-- rpt.aktivierung_plz — die Kampagnengrundlage
-- =====================================================================
CREATE OR REPLACE VIEW rpt.aktivierung_plz AS
SELECT
  plz, ort,
  count(*)                                      AS berechtigt,
  count(*) FILTER (WHERE aktiviert)             AS aktiviert,
  count(*) FILTER (WHERE NOT aktiviert)         AS offen,
  round(100.0 * count(*) FILTER (WHERE aktiviert) / nullif(count(*), 0), 1) AS quote_prozent
FROM rpt.abo_berechtigung
WHERE plz IS NOT NULL
GROUP BY plz, ort;

-- =====================================================================
-- rpt.statuslauf — Bestellstrecke und Abbruchursachen
-- =====================================================================
CREATE OR REPLACE VIEW rpt.statuslauf AS
SELECT
  h.orders_status_history_id  AS schritt_id,
  h.orders_id                 AS bestellung_id,
  h.date_added                AS zeitpunkt,
  h.date_added::date          AS tag,
  h.orders_status_id          AS status_id,
  s.orders_status_name        AS status,
  h.comments                  AS bemerkung,
  CASE WHEN h.orders_status_id = 8 AND h.comments ILIKE '%cleaner%' THEN 'Order cleaner-Job'
       WHEN h.orders_status_id = 8 AND h.comments ILIKE '%Invalid Subscription%' THEN 'Invalid Subscription'
       WHEN h.orders_status_id = 8 THEN 'sonstiger Abbruch' END AS abbruchursache
FROM src_mpswl.orders_status_history h
LEFT JOIN src_mpswl.orders_status s
  ON s.orders_status_id = h.orders_status_id AND s.language_id = 2;

-- =====================================================================
-- rpt.tagesreihe — eine Zeile je Tag, für die Verlaufskacheln
-- =====================================================================
CREATE OR REPLACE VIEW rpt.tagesreihe AS
WITH tage AS (
  SELECT generate_series(
    (SELECT min(kauftag) FROM rpt.bestellung),
    (SELECT max(kauftag) FROM rpt.bestellung), interval '1 day')::date AS tag
)
SELECT
  t.tag,
  (SELECT count(*) FROM rpt.kunde_360 k WHERE k.registriert_am = t.tag)                  AS neue_konten,
  (SELECT count(*) FROM rpt.bestellung b WHERE b.kauftag = t.tag)                        AS bestellungen,
  (SELECT count(*) FROM rpt.bestellung b WHERE b.kauftag = t.tag AND b.erfolgreich)      AS verkaeufe,
  (SELECT count(*) FROM rpt.bestellung b WHERE b.kauftag = t.tag AND b.abgebrochen)      AS abbrueche,
  (SELECT coalesce(sum(b.umsatz_brutto),0) FROM rpt.bestellung b
     WHERE b.kauftag = t.tag AND b.erfolgreich)                                          AS umsatz_brutto
FROM tage t;

-- =====================================================================
-- Leserechte für den Metabase-Benutzer
-- =====================================================================
-- CREATE ROLE metabase LOGIN PASSWORD '...';
-- GRANT USAGE ON SCHEMA rpt TO metabase;
-- GRANT SELECT ON ALL TABLES IN SCHEMA rpt TO metabase;
-- Kein Zugriff auf src_mpswl / src_swl: der Vertrieb sieht nur rpt.
