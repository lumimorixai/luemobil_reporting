-- Korrektur 1: Kaufkennzahlen einheitlich über die Kundennummer, nicht
-- über die E-Mail. Sonst zeigt dasselbe Board 1.453 Käufer, aber 67,8 %
-- Kauf-Quote (die auf 1.445 beruhte).
DROP VIEW IF EXISTS rpt.kunde_360 CASCADE;

CREATE VIEW rpt.kunde_360 AS
WITH bestand AS (
  SELECT lower(btrim(email)) AS email,
         min(customer_number)                   AS abo_kundennummer,
         min(zip_code)                          AS plz,
         min(city)                              AS ort,
         min(product_number)                    AS bestandssegment,
         max(display_validity_end)              AS berechtigt_bis,
         min(nullif(btrim(birthday),''))::date  AS geburtsdatum,
         count(*)                               AS anzahl_berechtigungen
  FROM src_mpswl.abo_berechtigungen_luebeck
  WHERE email IS NOT NULL AND btrim(email) <> ''
  GROUP BY 1
),
bestellt AS (
  SELECT kunde_id,
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
  (c.email_verified = 1)                           AS email_bestaetigt,
  ci.customers_info_date_created                   AS konto_seit,
  ci.customers_info_date_created::date             AS registriert_am,
  ci.customers_info_date_last_logon                AS letzter_login,
  bs.abo_kundennummer, bs.plz, bs.ort, bs.bestandssegment,
  bs.berechtigt_bis, bs.geburtsdatum,
  CASE WHEN bs.geburtsdatum IS NOT NULL
       THEN extract(year FROM age(bs.geburtsdatum::timestamp))::int END AS alter_jahre,
  (bs.email IS NOT NULL)                           AS hat_abo_berechtigung,
  coalesce(bt.bestellungen, 0)                     AS bestellungen,
  coalesce(bt.bestellungen_erfolgreich, 0)         AS bestellungen_erfolgreich,
  coalesce(bt.umsatz_brutto, 0)                    AS umsatz_brutto,
  bt.erster_kauf, bt.letzter_kauf,
  (bt.kunde_id IS NOT NULL)                        AS hat_gekauft,
  (SELECT max(t.tag_value) FROM src_mpswl.kk_customers_to_tag t
     WHERE t.customers_id = c.customers_id AND t.name = 'TOS_ACCEPTED_DATE') AS agb_zugestimmt_am,
  (SELECT max(t.tag_value) FROM src_mpswl.kk_customers_to_tag t
     WHERE t.customers_id = c.customers_id AND t.name = 'MARKETING_PREFERENCES') AS marketing_einwilligung,
  EXISTS (SELECT 1 FROM src_mpswl.kk_customers_to_tag t
     WHERE t.customers_id = c.customers_id AND t.name = 'ACCOUNT_DELETION_REQUESTED') AS loeschung_beantragt
FROM src_mpswl.customers c
LEFT JOIN src_mpswl.customers_info ci ON ci.customers_info_id = c.customers_id
LEFT JOIN bestand  bs ON bs.email = lower(btrim(c.customers_email_address))
LEFT JOIN bestellt bt ON bt.kunde_id = c.customers_id;

-- Korrektur 2: Tarifstruktur über den Katalog, nicht über die Belegung.
-- 93 Preisstufen sind gepflegt, 70 davon in Preispunkten verwendet.
DROP VIEW IF EXISTS rpt.tarifstruktur CASCADE;
CREATE VIEW rpt.tarifstruktur AS
SELECT
  v.products_options_values_name               AS preisstufe,
  count(a.products_attributes_id)              AS preispunkte,
  round(min(a.options_values_price) * 1.07, 2) AS preis_ab_brutto,
  round(max(a.options_values_price) * 1.07, 2) AS preis_bis_brutto,
  (count(a.products_attributes_id) > 0)        AS in_verwendung
FROM src_swl.products_options_values v
LEFT JOIN src_swl.products_attributes a ON a.options_values_id = v.products_options_values_id
WHERE v.language_id = 2
GROUP BY 1;

-- Korrektur 3: Gültigkeitsregeln je Preispunkt, nicht je Preisstufe.
CREATE OR REPLACE VIEW rpt.gueltigkeitsregel AS
SELECT
  CASE WHEN a.custom2 LIKE '%2 STD%'           THEN 'zwei Stunden'
       WHEN a.custom2 LIKE '%Betriebsschluss%' THEN 'bis Betriebsschluss'
       WHEN a.custom2 LIKE '%1 MON%'           THEN 'einen Monat'
       ELSE 'ohne Regel' END AS regel,
  count(*)                   AS preispunkte
FROM src_swl.products_attributes a
GROUP BY 1;

-- Arbeitsliste hing an kunde_360
CREATE OR REPLACE VIEW rpt.arbeitsliste AS
SELECT 'Abos mit Störung' AS liste, 'Service ruft an' AS zweck,
       (SELECT count(*) FROM rpt.abo WHERE stoerung) AS faelle
UNION ALL SELECT 'Berechtigt, nicht aktiviert', 'Kampagnenselektion nach PLZ',
       (SELECT count(*) FROM rpt.abo_berechtigung WHERE NOT aktiviert AND ist_hauptzeile)
UNION ALL SELECT 'Konten ohne Kauf', 'registriert, nie bestellt',
       (SELECT count(*) FROM rpt.kunde_360 WHERE NOT hat_gekauft)
UNION ALL SELECT 'Konten ohne Berechtigung', 'Klärfälle beim Bestandsabgleich',
       (SELECT count(*) FROM rpt.kunde_360 WHERE NOT hat_abo_berechtigung)
UNION ALL SELECT 'Abgebrochene Bestellungen', 'Nacharbeit und Rückerstattung',
       (SELECT count(*) FROM rpt.bestellung WHERE abgebrochen)
UNION ALL SELECT 'Schulticket zum Vollpreis', 'Tarifprüfung',
       (SELECT count(*) FROM rpt.bestellposition WHERE preisstufe_auffaellig);

CREATE OR REPLACE VIEW rpt.trichter AS
SELECT 1 AS stufe, 'Abo-Berechtigte' AS schritt,
       (SELECT count(*) FROM rpt.abo_berechtigung WHERE ist_hauptzeile) AS anzahl
UNION ALL SELECT 2,'App-Konto angelegt',   (SELECT count(*) FROM rpt.kunde_360)
UNION ALL SELECT 3,'Konto mit Berechtigung',(SELECT count(*) FROM rpt.kunde_360 WHERE hat_abo_berechtigung)
UNION ALL SELECT 4,'Hat bestellt',          (SELECT count(*) FROM rpt.kunde_360 WHERE hat_gekauft)
UNION ALL SELECT 5,'Abo läuft störungsfrei',(SELECT count(*) FROM rpt.abo WHERE aktiv AND NOT stoerung);

-- Korrektur 4 / achte Falle: 8 Kundennummern in orders haben kein Konto
-- in customers (10 Bestellungen, davon 7 erfolgreich ausgeliefert).
-- Deshalb: 1.453 Kundennummern in Bestellungen, aber nur 1.445 Konten
-- mit Kauf. Die Differenz wird als Klärfall geführt, nicht verrechnet.
CREATE OR REPLACE VIEW rpt.bestellung_ohne_konto AS
SELECT b.bestellung_id, b.bestellnummer, b.kunde_id, b.kauftag,
       b.status, b.umsatz_brutto
FROM rpt.bestellung b
LEFT JOIN src_mpswl.customers c ON c.customers_id = b.kunde_id
WHERE c.customers_id IS NULL;

CREATE OR REPLACE VIEW rpt.arbeitsliste AS
SELECT 'Abos mit Störung' AS liste, 'Service ruft an' AS zweck,
       (SELECT count(*) FROM rpt.abo WHERE stoerung) AS faelle
UNION ALL SELECT 'Berechtigt, nicht aktiviert', 'Kampagnenselektion nach PLZ',
       (SELECT count(*) FROM rpt.abo_berechtigung WHERE NOT aktiviert AND ist_hauptzeile)
UNION ALL SELECT 'Konten ohne Kauf', 'registriert, nie bestellt',
       (SELECT count(*) FROM rpt.kunde_360 WHERE NOT hat_gekauft)
UNION ALL SELECT 'Konten ohne Berechtigung', 'Klärfälle beim Bestandsabgleich',
       (SELECT count(*) FROM rpt.kunde_360 WHERE NOT hat_abo_berechtigung)
UNION ALL SELECT 'Abgebrochene Bestellungen', 'Nacharbeit und Rückerstattung',
       (SELECT count(*) FROM rpt.bestellung WHERE abgebrochen)
UNION ALL SELECT 'Schulticket zum Vollpreis', 'Tarifprüfung',
       (SELECT count(*) FROM rpt.bestellposition WHERE preisstufe_auffaellig)
UNION ALL SELECT 'Bestellungen ohne Konto', 'Datenprüfung: Konto fehlt oder gelöscht',
       (SELECT count(*) FROM rpt.bestellung_ohne_konto);

-- rpt.tagesreihe hängt an kunde_360 und muss nach jedem Neuaufbau
-- von kunde_360 wieder angelegt werden.
CREATE OR REPLACE VIEW rpt.tagesreihe AS
WITH tage AS (
  SELECT generate_series((SELECT min(kauftag) FROM rpt.bestellung),
                         (SELECT max(kauftag) FROM rpt.bestellung),
                         interval '1 day')::date AS tag
)
SELECT t.tag,
  (SELECT count(*) FROM rpt.kunde_360 k WHERE k.registriert_am = t.tag)              AS neue_konten,
  (SELECT count(*) FROM rpt.bestellung b WHERE b.kauftag = t.tag)                    AS bestellungen,
  (SELECT count(*) FROM rpt.bestellung b WHERE b.kauftag = t.tag AND b.erfolgreich)  AS verkaeufe,
  (SELECT count(*) FROM rpt.bestellung b WHERE b.kauftag = t.tag AND b.abgebrochen)  AS abbrueche,
  (SELECT coalesce(sum(b.umsatz_brutto),0) FROM rpt.bestellung b
     WHERE b.kauftag = t.tag AND b.erfolgreich)                                      AS umsatz_brutto
FROM tage t;
