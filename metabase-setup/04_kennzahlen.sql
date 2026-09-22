-- =====================================================================
-- Eindeutige Zählebenen
-- =====================================================================
-- Eine Berechtigung ist eine Zeile, ein Berechtigter eine Person.
-- 8.267 Zeilen verteilen sich auf 8.215 Personen. Ohne feste Definition
-- liefert dieselbe Frage je nach Klickpfad zwei Antworten. Deshalb trägt
-- jede Zeile ab hier ein Kennzeichen, welche die "Hauptzeile" je Person
-- ist — Personenzählungen filtern darauf.
-- =====================================================================

-- Spaltenreihenfolge ändert sich, daher neu anlegen statt ersetzen.
DROP VIEW IF EXISTS rpt.aktivierung_plz CASCADE;
DROP VIEW IF EXISTS rpt.aktivierung_segment CASCADE;
DROP VIEW IF EXISTS rpt.abo_berechtigung CASCADE;

CREATE VIEW rpt.abo_berechtigung AS
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
  CASE WHEN extract(year FROM age(nullif(btrim(a.birthday),'')::timestamp)) < 18 THEN 'unter 18'
       WHEN extract(year FROM age(nullif(btrim(a.birthday),'')::timestamp)) < 26 THEN '18 bis 25'
       WHEN extract(year FROM age(nullif(btrim(a.birthday),'')::timestamp)) < 41 THEN '26 bis 40'
       WHEN extract(year FROM age(nullif(btrim(a.birthday),'')::timestamp)) < 61 THEN '41 bis 60'
       ELSE '61 und älter' END             AS altersgruppe,
  (a.phone IS NOT NULL AND a.phone <> '')  AS telefon_bekannt,
  a.imported_at                            AS importiert_am,
  EXISTS (SELECT 1 FROM src_mpswl.customers c
          WHERE lower(btrim(c.customers_email_address)) = lower(btrim(a.email))) AS aktiviert,
  -- true genau einmal je Person: Grundlage aller Personenzählungen
  (row_number() OVER (PARTITION BY lower(btrim(a.email)) ORDER BY a.id) = 1) AS ist_hauptzeile
FROM src_mpswl.abo_berechtigungen_luebeck a;

-- Gebietsauswertung: konsequent auf Personenebene
CREATE VIEW rpt.aktivierung_plz AS
SELECT
  plz, ort,
  count(*)                                      AS berechtigte,
  count(*) FILTER (WHERE aktiviert)             AS aktivierte,
  count(*) FILTER (WHERE NOT aktiviert)         AS offen,
  round(100.0 * count(*) FILTER (WHERE aktiviert) / nullif(count(*), 0), 1) AS quote_prozent
FROM rpt.abo_berechtigung
WHERE plz IS NOT NULL AND ist_hauptzeile
GROUP BY plz, ort;

-- Segmentvergleich, ebenfalls Personenebene
CREATE VIEW rpt.aktivierung_segment AS
SELECT
  bestandssegment,
  count(*)                                      AS berechtigte,
  count(*) FILTER (WHERE aktiviert)             AS aktivierte,
  count(*) FILTER (WHERE NOT aktiviert)         AS offen,
  round(100.0 * count(*) FILTER (WHERE aktiviert) / nullif(count(*), 0), 1) AS quote_prozent
FROM rpt.abo_berechtigung
WHERE ist_hauptzeile
GROUP BY bestandssegment;

-- =====================================================================
-- rpt.trichter — der Überführungstrichter als feste Kennzahlenliste
-- =====================================================================
CREATE OR REPLACE VIEW rpt.trichter AS
SELECT 1 AS stufe, 'Abo-Berechtigte'          AS schritt,
       (SELECT count(*) FROM rpt.abo_berechtigung WHERE ist_hauptzeile) AS anzahl
UNION ALL SELECT 2, 'App-Konto angelegt',
       (SELECT count(*) FROM rpt.kunde_360)
UNION ALL SELECT 3, 'Konto mit Berechtigung',
       (SELECT count(*) FROM rpt.kunde_360 WHERE hat_abo_berechtigung)
UNION ALL SELECT 4, 'Hat bestellt',
       (SELECT count(*) FROM rpt.kunde_360 WHERE hat_gekauft)
UNION ALL SELECT 5, 'Abo läuft störungsfrei',
       (SELECT count(*) FROM rpt.abo WHERE aktiv AND NOT stoerung);

-- =====================================================================
-- Korrektur: Bestellpositionen aus der Shop-Datenbank
-- =====================================================================
-- In kk_mpswl steht als SKU pauschal 'OEPNV'. Die echte Tarif-SKU (541,
-- 548, ...) und damit der Produktbezug liegen nur in kk_swl. Verknüpft
-- wird über orders.custom1 ->> 'externalOrderReference'.
-- =====================================================================
DROP VIEW IF EXISTS rpt.bestellposition CASCADE;

CREATE VIEW rpt.bestellposition AS
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
  coalesce(pr.kategorie, 'unbekannt')      AS kategorie,
  coalesce(pr.vertriebskanal, 'unbekannt') AS vertriebskanal
FROM rpt.bestellung b
JOIN src_swl.orders_products op ON op.orders_id = b.shop_bestellung_id
LEFT JOIN rpt.produkt pr ON pr.sku = op.products_sku;

-- =====================================================================
-- rpt.arbeitsliste — die gespeicherten Suchen als eine Tabelle
-- =====================================================================
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
       (SELECT count(*) FROM rpt.bestellposition
         WHERE produkt LIKE '%Schule%' AND einzelpreis_netto > 50);

