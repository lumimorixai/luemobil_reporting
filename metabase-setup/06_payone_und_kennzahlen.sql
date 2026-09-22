-- =====================================================================
-- Nachtrag: PayOne-Bereitschaft, Tarifstruktur, Bestellstrecke
-- =====================================================================
-- Ergänzt, was im Prototyp enthalten war und in der ersten Metabase-
-- Fassung fehlte. Korrigiert ausserdem die Erkennung des Vertriebskanals:
-- in products.custom_attrs steht der Wert VOR dem Attributnamen.
-- =====================================================================

DROP VIEW IF EXISTS rpt.produkt CASCADE;

CREATE VIEW rpt.produkt AS
SELECT
  p.products_id                                   AS produkt_id,
  d.products_name                                 AS produkt,
  p.products_sku                                  AS sku,
  CASE c.categories_id WHEN 1 THEN 'ÖPNV'
                       WHEN 2 THEN 'Abo'
                       WHEN 3 THEN 'Fähre' END    AS kategorie,
  (p.custom_attrs ~ '<kk_v><!\[CDATA\[true\]\]></kk_v><kk_ty>4</kk_ty><kk_n><!\[CDATA\[payone\]\]>')
                                                  AS payone_faehig,
  (p.custom_attrs ~ '<kk_v><!\[CDATA\[true\]\]></kk_v><kk_ty>4</kk_ty><kk_n><!\[CDATA\[subscription\]\]>')
                                                  AS abo_faehig,
  CASE WHEN c.categories_id = 2 THEN 'Abo'
       WHEN c.categories_id = 3 THEN 'Fähre'
       ELSE 'Einzelticket' END                    AS vertriebskanal,
  (p.products_status = 1)                         AS aktiv,
  (SELECT count(*) FROM src_swl.products_attributes a
     WHERE a.products_id = p.products_id)         AS anzahl_preisstufen,
  (SELECT round(min(a.options_values_price) * 1.07, 2) FROM src_swl.products_attributes a
     WHERE a.products_id = p.products_id AND a.options_values_price > 0) AS preis_ab_brutto,
  (SELECT round(max(a.options_values_price) * 1.07, 2) FROM src_swl.products_attributes a
     WHERE a.products_id = p.products_id)         AS preis_bis_brutto
FROM src_swl.products p
JOIN src_swl.products_description d
  ON d.products_id = p.products_id AND d.language_id = 2
LEFT JOIN src_swl.products_to_categories c ON c.products_id = p.products_id;

-- Bestellpositionen und Arbeitsliste hängen an rpt.produkt -> neu anlegen
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
  coalesce(pr.vertriebskanal, 'unbekannt') AS vertriebskanal,
  -- Schulticket zum Erwachsenenpreis: die Tarifausnahme
  (op.products_name LIKE '%Schule%' AND op.final_price > 50) AS preisstufe_auffaellig
FROM rpt.bestellung b
JOIN src_swl.orders_products op ON op.orders_id = b.shop_bestellung_id
LEFT JOIN rpt.produkt pr ON pr.sku = op.products_sku;

CREATE VIEW rpt.arbeitsliste AS
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

-- =====================================================================
-- rpt.tarifstruktur — Preisstufen und Gültigkeitsregeln
-- =====================================================================
CREATE OR REPLACE VIEW rpt.tarifstruktur AS
SELECT
  v.products_options_values_name             AS preisstufe,
  count(*)                                   AS produkte_mit_dieser_stufe,
  round(min(a.options_values_price) * 1.07, 2) AS preis_ab_brutto,
  round(max(a.options_values_price) * 1.07, 2) AS preis_bis_brutto,
  max(CASE WHEN a.custom2 LIKE '%2 STD%'        THEN 'zwei Stunden'
           WHEN a.custom2 LIKE '%Betriebsschluss%' THEN 'bis Betriebsschluss'
           WHEN a.custom2 LIKE '%1 MON%'        THEN 'einen Monat'
           ELSE 'ohne Regel' END)             AS gueltigkeit
FROM src_swl.products_attributes a
JOIN src_swl.products_options_values v
  ON v.products_options_values_id = a.options_values_id AND v.language_id = 2
GROUP BY 1;

-- =====================================================================
-- rpt.payone_bereitschaft — was beim Go-live befüllt wird
-- =====================================================================
CREATE OR REPLACE VIEW rpt.payone_bereitschaft AS
SELECT * FROM (VALUES
  (1,'Zahlungsbeleg','ipn_history: gateway_transaction_id, gateway_result, transaction_amount',
     (SELECT count(*) FROM src_mpswl.ipn_history WHERE gateway_result IS NOT NULL),'Spalten leer'),
  (2,'Zahlart','orders.payment_module_subcode',
     (SELECT count(*) FROM src_mpswl.orders WHERE payment_module_subcode IS NOT NULL),'Spalte leer'),
  (3,'Zahlerkennung','kk_customers_to_tag: PAYONE_CUSTOMER_ID',
     (SELECT count(*) FROM src_mpswl.kk_customers_to_tag WHERE name='PAYONE_CUSTOMER_ID'),'0 Zeilen'),
  (4,'Erstattung','kk_order_refunds: refund_amount, gateway_credit_id',
     0,'Tabelle leer'),
  (5,'Preisstufe je Kauf','orders_products_attributes',
     (SELECT count(*) FROM src_swl.orders_products),'Schema bereit'),
  (6,'Start- und Zielzone','customers_basket.custom1: start.zone / stop.zone',
     (SELECT count(*) FROM src_swl.customers_basket WHERE custom1 IS NOT NULL),'Schema bereit')
) AS t(reihenfolge, gegenstand, quellfeld, datensaetze, stand);

-- =====================================================================
-- rpt.bestellstrecke — der Statustrichter aus dem Prototyp
-- =====================================================================
CREATE OR REPLACE VIEW rpt.bestellstrecke AS
SELECT 1 AS stufe, 'Offen' AS status,
       (SELECT count(DISTINCT bestellung_id) FROM rpt.statuslauf WHERE status_id=1) AS bestellungen
UNION ALL SELECT 2,'Warte auf Zahlung',
       (SELECT count(DISTINCT bestellung_id) FROM rpt.statuslauf WHERE status_id=4)
UNION ALL SELECT 3,'Zahlung erhalten',
       (SELECT count(DISTINCT bestellung_id) FROM rpt.statuslauf WHERE status_id=5)
UNION ALL SELECT 4,'Versendet',
       (SELECT count(DISTINCT bestellung_id) FROM rpt.statuslauf WHERE status_id=3)
UNION ALL SELECT 5,'Abgebrochen',
       (SELECT count(DISTINCT bestellung_id) FROM rpt.statuslauf WHERE status_id=8);
