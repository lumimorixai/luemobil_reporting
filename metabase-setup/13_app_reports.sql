-- =====================================================================
-- Reports für den Livebetrieb (Stand der Daten: Oktober 2026)
-- =====================================================================
-- Korrigiert, was der neue Produktkatalog (7.10.2026) und PayOne gebrochen
-- haben, und ergänzt die Sichten für Monatsbilanz, Abo-Verlängerung,
-- PayOne, Erstattungen, App-Nutzung und Datenstand.
--
-- Wiederholbar. Ändert vorhandene Sichten nur mit CREATE OR REPLACE und
-- hängt neue Spalten hinten an: Die Rechte der Ticket-API (api_eigentuemer)
-- und von Metabase (metabase_leser) bleiben erhalten, 4.6 muss NICHT
-- erneut laufen.
--
-- Zehnte Falle — eine SKU ist kein Produkt. Seit dem 7.10. gibt es jede
-- Einzel- und Fähr-SKU zwei- bis dreimal (alter und neuer Katalog). Der
-- Join über die SKU vervielfachte die Positionen (8.785 statt 8.629).
-- Verknüpft wird deshalb über products_id.
--
-- Elfte Falle — gekauft ist nicht gültig. Das Abo-Ticket für Oktober wird
-- am 27.9. ausgestellt. Wer wissen will, wer im Oktober ein Ticket hat,
-- fragt die Gültigkeit (orders_products.custom1 -> timeValidity), nicht
-- das Kaufdatum.
-- =====================================================================

-- Nicht ewig hinter einer laufenden Metabase-Abfrage warten: lieber mit
-- klarer Meldung abbrechen und neu starten.
SET lock_timeout = '60s';

-- --- Monatsname für Diagrammachsen ("Oktober 2026"), unabhängig von lc_time
CREATE OR REPLACE FUNCTION rpt.monatsname(d date) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY['Januar','Februar','März','April','Mai','Juni','Juli','August',
                'September','Oktober','November','Dezember'])[extract(month FROM d)::int]
         || ' ' || extract(year FROM d)::int
$$;

-- --- Zusätzliche Quelltabellen ----------------------------------------
DO $$
BEGIN
  IF to_regclass('src_mpswl.kk_order_refunds') IS NULL THEN
    IMPORT FOREIGN SCHEMA public LIMIT TO (kk_order_refunds) FROM SERVER srv_mpswl INTO src_mpswl;
  END IF;
  IF to_regclass('src_swl.categories') IS NULL THEN
    IMPORT FOREIGN SCHEMA public LIMIT TO (categories) FROM SERVER srv_swl INTO src_swl;
  END IF;
END $$;

-- =====================================================================
-- rpt.bestellung und rpt.kunde_360 — gleiche Spalten, ohne Unterabfragen je Zeile
-- =====================================================================
-- Jede Unterabfrage je Zeile ist über postgres_fdw eine eigene Abfrage an
-- die Quelldatenbank: bei 8.600 Bestellungen 6 Sekunden je Spalte. Statt-
-- dessen werden die Quellen einmal gruppiert und gejoint. Fragt niemand
-- nach einer dieser Spalten (z. B. die Ticket-API), entfällt der Join ganz:
-- die gruppierte Teilmenge ist je Bestellung eindeutig.
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
  tot.brutto                                         AS umsatz_brutto,
  tot.steuer                                         AS steuer,
  tot.brutto - coalesce(tot.steuer, 0)               AS umsatz_netto,
  -- Gerät und Plattform aus dem JSON in custom1
  o.custom1::jsonb ->> 'deviceId'                    AS geraet_id,
  CASE WHEN length(o.custom1::jsonb ->> 'deviceId') = 36 THEN 'iOS'
       WHEN (o.custom1::jsonb ->> 'deviceId') IS NOT NULL THEN 'Android'
       ELSE 'unbekannt' END                          AS plattform,
  -- Falle 1: DAS ist der belastbare Schlüssel in die Shop-Datenbank
  (o.custom1::jsonb ->> 'externalOrderReference')::int AS shop_bestellung_id,
  -- Durchlaufzeit bis zur Ticketauslieferung
  h.sekunden                                         AS sekunden_bis_ticket
FROM src_mpswl.orders o
LEFT JOIN src_mpswl.orders_status s
  ON s.orders_status_id = o.orders_status AND s.language_id = 2
LEFT JOIN (
  SELECT orders_id,
         (max(value) FILTER (WHERE class = 'ot_total'))::numeric(15,4) AS brutto,
         (max(value) FILTER (WHERE class = 'ot_tax'))::numeric(15,4)   AS steuer
  FROM src_mpswl.orders_total WHERE class IN ('ot_total', 'ot_tax')
  GROUP BY orders_id
) tot ON tot.orders_id = o.orders_id
LEFT JOIN (
  SELECT orders_id,
         extract(epoch FROM min(date_added) FILTER (WHERE orders_status_id = 3)
                          - min(date_added) FILTER (WHERE orders_status_id = 1)) AS sekunden
  FROM src_mpswl.orders_status_history
  GROUP BY orders_id
) h ON h.orders_id = o.orders_id;

CREATE OR REPLACE VIEW rpt.kunde_360 AS
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
),
tags AS (
  SELECT customers_id,
         max(tag_value::text) FILTER (WHERE name = 'TOS_ACCEPTED_DATE')     AS agb,
         max(tag_value::text) FILTER (WHERE name = 'MARKETING_PREFERENCES') AS marketing,
         bool_or(name = 'ACCOUNT_DELETION_REQUESTED')                       AS loeschung
  FROM src_mpswl.kk_customers_to_tag
  WHERE name IN ('TOS_ACCEPTED_DATE', 'MARKETING_PREFERENCES', 'ACCOUNT_DELETION_REQUESTED')
  GROUP BY customers_id
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
  tg.agb                                           AS agb_zugestimmt_am,
  tg.marketing                                     AS marketing_einwilligung,
  coalesce(tg.loeschung, false)                    AS loeschung_beantragt
FROM src_mpswl.customers c
LEFT JOIN src_mpswl.customers_info ci ON ci.customers_info_id = c.customers_id
LEFT JOIN bestand  bs ON bs.email = lower(btrim(c.customers_email_address))
LEFT JOIN bestellt bt ON bt.kunde_id = c.customers_id
LEFT JOIN tags     tg ON tg.customers_id = c.customers_id;

-- =====================================================================
-- rpt.produkt — Kategorie über die Oberkategorie
-- =====================================================================
-- Der neue Katalog hängt Produkte in Unterkategorien (Zeitkarten,
-- Einzelkarten unter ÖPNV; Personen, Fahrrad, Fahrzeuge unter Fähre).
CREATE OR REPLACE VIEW rpt.produkt AS
-- Kategorie und Preisstufen als gruppierte Joins, nicht als Unterabfrage je
-- Produkt: rpt.bestellposition joint diese Sicht je Ticketposition, sonst
-- fragt PostgreSQL die Quelle tausendfach ab.
SELECT
  p.products_id                                   AS produkt_id,
  d.products_name                                 AS produkt,
  p.products_sku                                  AS sku,
  CASE k.oberkategorie WHEN 1 THEN 'ÖPNV'
                       WHEN 2 THEN 'Abo'
                       WHEN 3 THEN 'Fähre' END    AS kategorie,
  (p.custom_attrs ~ '<kk_v><!\[CDATA\[true\]\]></kk_v><kk_ty>4</kk_ty><kk_n><!\[CDATA\[payone\]\]>')
                                                  AS payone_faehig,
  (p.custom_attrs ~ '<kk_v><!\[CDATA\[true\]\]></kk_v><kk_ty>4</kk_ty><kk_n><!\[CDATA\[subscription\]\]>')
                                                  AS abo_faehig,
  CASE k.oberkategorie WHEN 2 THEN 'Abo'
                       WHEN 3 THEN 'Fähre'
                       ELSE 'Einzelticket' END    AS vertriebskanal,
  (p.products_status = 1)                         AS aktiv,
  coalesce(a.anzahl, 0)                           AS anzahl_preisstufen,
  a.preis_ab_brutto,
  a.preis_bis_brutto,
  -- neu
  k.unterkategorie,
  p.products_date_added::date                     AS angelegt_am
FROM src_swl.products p
JOIN src_swl.products_description d
  ON d.products_id = p.products_id AND d.language_id = 2
LEFT JOIN (
  -- Ein Produkt hängt in genau einer Kategorie; bei mehreren gewinnt die Unterkategorie
  SELECT pc.products_id,
         (array_agg(CASE WHEN c.parent_id = 0 THEN c.categories_id ELSE c.parent_id END
                    ORDER BY c.parent_id DESC))[1]                         AS oberkategorie,
         (array_agg(cd.categories_name ORDER BY c.parent_id DESC)
            FILTER (WHERE c.parent_id <> 0))[1]                            AS unterkategorie
  FROM src_swl.products_to_categories pc
  JOIN src_swl.categories c ON c.categories_id = pc.categories_id
  LEFT JOIN src_swl.categories_description cd
    ON cd.categories_id = c.categories_id AND cd.language_id = 2
  GROUP BY pc.products_id
) k ON k.products_id = p.products_id
LEFT JOIN (
  SELECT products_id,
         count(*)                                                          AS anzahl,
         round(min(options_values_price) FILTER (WHERE options_values_price > 0) * 1.07, 2) AS preis_ab_brutto,
         round(max(options_values_price) * 1.07, 2)                        AS preis_bis_brutto
  FROM src_swl.products_attributes
  GROUP BY products_id
) a ON a.products_id = p.products_id;

-- =====================================================================
-- rpt.bestellposition — je Ticket, jetzt mit Gültigkeit und Relation
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
  coalesce(pr.kategorie, 'unbekannt')      AS kategorie,
  coalesce(pr.vertriebskanal, 'unbekannt') AS vertriebskanal,
  -- Schulticket zum Erwachsenenpreis: die Tarifausnahme
  (op.products_name LIKE '%Schule%' AND op.final_price > 50) AS preisstufe_auffaellig,
  -- neu
  op.products_id                           AS produkt_id,
  pr.unterkategorie,
  t.gueltig_ab,
  t.gueltig_bis,
  date_trunc('month', coalesce(t.abo_start, t.gueltig_ab))::date AS gueltigkeitsmonat,
  nullif(t.j -> 'start' -> 'zone' ->> 'name', '') AS von_zone,
  nullif(t.j -> 'stop'  -> 'zone' ->> 'name', '') AS nach_zone,
  b.zahlungsmodul,
  b.gekauft_am,
  b.kunde_id,
  b.plattform
FROM rpt.bestellung b
JOIN src_swl.orders_products op ON op.orders_id = b.shop_bestellung_id
LEFT JOIN rpt.produkt pr ON pr.produkt_id = op.products_id
LEFT JOIN LATERAL (
  SELECT j,
         -- Abo: timeValidity am Ticket, Einzelticket: product.timeValidity.
         -- Zeitstempel kommen mit Nanosekunden: auf Sekunden kürzen.
         left(coalesce(j -> 'timeValidity' ->> 'validFrom',
                       j -> 'product' -> 'timeValidity' ->> 'validFrom'), 19)::timestamp AS gueltig_ab,
         left(coalesce(j -> 'timeValidity' ->> 'validTo',
                       j -> 'product' -> 'timeValidity' ->> 'validTo'), 19)::timestamp   AS gueltig_bis,
         (j -> 'timeValidity' ->> 'start')::date AS abo_start
  FROM (SELECT CASE WHEN op.custom1 LIKE '{%' THEN op.custom1::jsonb END AS j) x
) t ON true;

-- =====================================================================
-- rpt.abo — E-Mail angehängt (für den Abgleich mit dem Bestand)
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
  s.date_added                    AS angelegt_am,
  -- neu
  lower(btrim(c.customers_email_address)) AS kunde_email
FROM src_mpswl.kk_subscription s
LEFT JOIN src_mpswl.customers c ON c.customers_id = s.customers_id;

-- =====================================================================
-- rpt.abo_ticket — wer hat für welchen Monat ein Abo-Ticket
-- =====================================================================
-- Eine Zeile je Person und Gültigkeitsmonat. Nur ausgestellte Tickets
-- (Status 3 "Versendet"), keine abgebrochenen oder erstatteten.
CREATE OR REPLACE VIEW rpt.abo_ticket AS
-- MATERIALIZED: Filter von außen (z. B. auf den Monat) dürfen nicht in die
-- Positionen geschoben werden, sonst plant PostgreSQL Schleifen über die Quelle.
WITH pos AS MATERIALIZED (
  SELECT kunde_email, gueltigkeitsmonat, sku, gekauft_am
  FROM rpt.bestellposition
  WHERE vertriebskanal = 'Abo' AND erfolgreich AND gueltigkeitsmonat IS NOT NULL
)
SELECT
  kunde_email,
  gueltigkeitsmonat,
  count(*)                                   AS tickets,
  string_agg(DISTINCT sku, ', ' ORDER BY sku) AS skus,
  min(gekauft_am)                            AS erstes_ticket_am,
  max(gekauft_am)                            AS letztes_ticket_am
FROM pos
GROUP BY 1, 2;

-- =====================================================================
-- rpt.berechtigte_person — eine Zeile je Berechtigtem, Stand heute
-- =====================================================================
-- Bestandsmonat = Monat, für den der aktuelle Bestand gilt. Der Bestand
-- wird jeden Monat vollständig ersetzt.
CREATE OR REPLACE VIEW rpt.berechtigte_person AS
-- Mengenbasiert: jede Quelle wird einmal gelesen und gejoint. Ein EXISTS
-- je Person gegen rpt.abo_ticket kostete bei 8.300 Personen 6 Minuten.
WITH monat AS (
  SELECT date_trunc('month', max(gueltig_ab))::date AS m FROM rpt.abo_berechtigung
), person AS (
  SELECT kunde_email,
         min(name)                                    AS name,
         string_agg(DISTINCT bestandssegment, ', ' ORDER BY bestandssegment) AS segment,
         min(plz) AS plz, min(ort) AS ort,
         min(altersgruppe)                            AS altersgruppe,
         bool_or(aktiviert)                           AS app_konto
  FROM rpt.abo_berechtigung
  GROUP BY 1
), abo AS (
  SELECT kunde_email, bool_or(aktiv) AS aktiv, bool_or(stoerung) AS gestoert
  FROM rpt.abo WHERE kunde_email IS NOT NULL GROUP BY 1
), ticket AS (
  SELECT t.kunde_email,
         bool_or(t.gueltigkeitsmonat = m.m)                                  AS im_monat,
         bool_or(t.gueltigkeitsmonat = (m.m + interval '1 month')::date)     AS folgemonat,
         bool_or(t.gueltigkeitsmonat = (m.m - interval '1 month')::date)     AS vormonat
  FROM rpt.abo_ticket t CROSS JOIN monat m GROUP BY 1
)
SELECT
  p.kunde_email, p.name, p.segment, p.plz, p.ort, p.altersgruppe,
  (SELECT m FROM monat)               AS bestandsmonat,
  p.app_konto,
  coalesce(a.aktiv, false)            AS aktives_abo,
  coalesce(a.gestoert, false)         AS abo_gestoert,
  coalesce(t.im_monat, false)         AS ticket_im_monat,
  coalesce(t.folgemonat, false)       AS ticket_folgemonat,
  coalesce(t.vormonat, false)         AS ticket_vormonat
FROM person p
LEFT JOIN abo a    ON a.kunde_email = p.kunde_email
LEFT JOIN ticket t ON t.kunde_email = p.kunde_email;

-- =====================================================================
-- rpt.monatsbilanz — die Hochlaufkette je Bestandssegment
-- =====================================================================
CREATE OR REPLACE VIEW rpt.monatsbilanz AS
SELECT
  coalesce(segment, 'Gesamt')                          AS segment,
  min(bestandsmonat)                                   AS bestandsmonat,
  count(*)                                             AS berechtigte,
  count(*) FILTER (WHERE app_konto)                    AS mit_app_konto,
  count(*) FILTER (WHERE aktives_abo)                  AS mit_aktivem_abo,
  count(*) FILTER (WHERE ticket_im_monat)              AS mit_ticket_im_monat,
  count(*) FILTER (WHERE ticket_folgemonat)            AS mit_ticket_folgemonat,
  count(*) FILTER (WHERE NOT app_konto)                AS ohne_app_konto,
  count(*) FILTER (WHERE app_konto AND NOT ticket_im_monat) AS konto_ohne_ticket,
  round(100.0 * count(*) FILTER (WHERE ticket_im_monat) / nullif(count(*), 0), 1) AS ticketquote_prozent
FROM rpt.berechtigte_person
GROUP BY ROLLUP (segment);

-- =====================================================================
-- rpt.monatsstand — tägliche Momentaufnahme der Monatsbilanz
-- =====================================================================
-- Der Bestand des Vormonats ist nach dem Monatswechsel weg. Damit der
-- Verlauf erhalten bleibt, schreibt der Import nach jedem erfolgreichen
-- Lauf eine Zeile je Segment (nur Zahlen, keine Personendaten).
CREATE TABLE IF NOT EXISTS rpt.monatsstand (
  stichtag              date        NOT NULL,
  segment               text        NOT NULL,
  bestandsmonat         date,
  berechtigte           int,
  mit_app_konto         int,
  mit_aktivem_abo       int,
  mit_ticket_im_monat   int,
  mit_ticket_folgemonat int,
  konten_gesamt         int,
  erfasst_am            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (stichtag, segment)
);

CREATE OR REPLACE FUNCTION rpt.monatsstand_schreiben() RETURNS int
LANGUAGE sql AS $$
  WITH neu AS (
    INSERT INTO rpt.monatsstand AS m (stichtag, segment, bestandsmonat, berechtigte, mit_app_konto,
           mit_aktivem_abo, mit_ticket_im_monat, mit_ticket_folgemonat, konten_gesamt)
    SELECT current_date, b.segment, b.bestandsmonat, b.berechtigte, b.mit_app_konto,
           b.mit_aktivem_abo, b.mit_ticket_im_monat, b.mit_ticket_folgemonat,
           (SELECT count(*) FROM src_mpswl.customers)
    FROM rpt.monatsbilanz b
    ON CONFLICT (stichtag, segment) DO UPDATE SET
      bestandsmonat = EXCLUDED.bestandsmonat, berechtigte = EXCLUDED.berechtigte,
      mit_app_konto = EXCLUDED.mit_app_konto, mit_aktivem_abo = EXCLUDED.mit_aktivem_abo,
      mit_ticket_im_monat = EXCLUDED.mit_ticket_im_monat,
      mit_ticket_folgemonat = EXCLUDED.mit_ticket_folgemonat,
      konten_gesamt = EXCLUDED.konten_gesamt, erfasst_am = now()
    RETURNING 1)
  SELECT count(*)::int FROM neu;
$$;

-- =====================================================================
-- rpt.abo_verlauf — Monat für Monat: verlängert, neu, nicht verlängert
-- =====================================================================
-- Aus den Tickets selbst, deshalb auch rückwirkend vollständig.
CREATE OR REPLACE VIEW rpt.abo_verlauf AS
-- Je Person die Monate in Reihenfolge: lag/lead zeigen, ob der Vor- bzw.
-- Folgemonat auch ein Ticket hat. Ein Durchlauf, kein Selbst-Join.
WITH t AS (SELECT DISTINCT kunde_email, gueltigkeitsmonat AS m FROM rpt.abo_ticket),
f AS (
  SELECT m,
         coalesce(lag(m)  OVER w = (m - interval '1 month')::date, false) AS hatte_vormonat,
         coalesce(lead(m) OVER w = (m + interval '1 month')::date, false) AS hat_folgemonat
  FROM t WINDOW w AS (PARTITION BY kunde_email ORDER BY m)
),
dieser AS (
  SELECT m, count(*) AS personen, count(*) FILTER (WHERE hatte_vormonat) AS verlaengert
  FROM f GROUP BY m
),
weg AS (  -- im Vormonat dabei, in diesem Monat nicht
  SELECT (m + interval '1 month')::date AS m, count(*) FILTER (WHERE NOT hat_folgemonat) AS anzahl
  FROM f GROUP BY 1
)
SELECT d.m                         AS monat,
       d.personen                  AS personen_mit_ticket,
       d.verlaengert,
       d.personen - d.verlaengert  AS neu,
       coalesce(w.anzahl, 0)       AS nicht_verlaengert
FROM dieser d LEFT JOIN weg w ON w.m = d.m;

-- =====================================================================
-- rpt.abo_verlaengerung — was am nächsten Abrechnungstag ansteht
-- =====================================================================
CREATE OR REPLACE VIEW rpt.abo_verlaengerung AS
-- Am Abrechnungstag (27.) wird das Ticket für den Folgemonat ausgestellt.
-- MATERIALIZED: sonst wertet der Planer die Ticket-Sicht je Abo neu aus.
WITH abo AS MATERIALIZED (SELECT * FROM rpt.abo),
     tk  AS MATERIALIZED (SELECT DISTINCT kunde_email, gueltigkeitsmonat FROM rpt.abo_ticket)
SELECT
  a.naechste_abrechnung,
  a.produkt,
  count(*) FILTER (WHERE a.aktiv)                              AS aktive_abos,
  count(*) FILTER (WHERE a.stoerung)                           AS gestoert,
  count(*) FILTER (WHERE a.aktiv AND t.kunde_email IS NOT NULL) AS ticket_schon_da
FROM abo a
LEFT JOIN tk t
  ON t.kunde_email = a.kunde_email
 AND t.gueltigkeitsmonat = date_trunc('month', a.naechste_abrechnung + interval '1 month')::date
GROUP BY 1, 2;

-- =====================================================================
-- rpt.abo_fahrgast — wer auf einem Abo-Ticket steht
-- =====================================================================
-- Ein App-Konto kann Abos für mehrere Personen führen (Eltern für ihre
-- Kinder). Wer gemeint ist, steht nur im Ticket: orders_products.custom1
-- -> persons[]. person_schluessel = Vorname|Nachname|Geburtsdatum, klein.
CREATE OR REPLACE VIEW rpt.abo_fahrgast AS
WITH pos AS MATERIALIZED (
  SELECT position_id, bestellung_id, kunde_id, erfolgreich, gueltigkeitsmonat
  FROM rpt.bestellposition WHERE vertriebskanal = 'Abo'
)
SELECT
  pos.position_id, pos.bestellung_id, pos.kunde_id, pos.erfolgreich, pos.gueltigkeitsmonat,
  btrim(coalesce(pe ->> 'firstName', '') || ' ' || coalesce(pe ->> 'lastName', '')) AS fahrgast,
  nullif(left(pe ->> 'dateOfBirth', 10), '')                                        AS geburtsdatum,
  lower(btrim(coalesce(pe ->> 'firstName', ''))) || '|' || lower(btrim(coalesce(pe ->> 'lastName', '')))
    || '|' || coalesce(left(pe ->> 'dateOfBirth', 10), '')                          AS person_schluessel
FROM pos
JOIN src_swl.orders_products op ON op.orders_products_id = pos.position_id
CROSS JOIN LATERAL jsonb_array_elements(
  CASE WHEN op.custom1 LIKE '{%' THEN coalesce(op.custom1::jsonb -> 'persons', '[]') ELSE '[]' END) pe;

-- =====================================================================
-- rpt.abo_stoerung — jedes "gestörte" Abo mit Klärung
-- =====================================================================
-- Dreizehnte Falle — gestört heißt stillgelegt. Die Quelle setzt problem = 1,
-- wenn sie ein Abo stilllegt, und benennt den Code um: R-<Datum>-<Nr>-LUB#…,
-- damit der ursprüngliche Code für ein neues Abo frei wird. Einen
-- Störungstext liefert sie nicht. Ob etwas zu tun ist, zeigt erst der
-- Fahrgast: Hat er im Bestandsmonat ein Ticket (auch in einem anderen Konto)?
-- Ist er überhaupt noch berechtigt (Kundennummer aus custom3 oder Person)?
CREATE OR REPLACE VIEW rpt.abo_stoerung AS
WITH monat AS (
  SELECT date_trunc('month', max(gueltig_ab))::date AS m FROM rpt.abo_berechtigung
), fg AS MATERIALIZED (
  SELECT * FROM rpt.abo_fahrgast
), bestand AS MATERIALIZED (
  SELECT DISTINCT customer_number AS kdnr,
         lower(btrim(coalesce(first_name, ''))) || '|' || lower(btrim(coalesce(last_name, '')))
           || '|' || coalesce(left(btrim(birthday), 10), '') AS person_schluessel
  FROM src_mpswl.abo_berechtigungen_luebeck
), aktiv AS MATERIALIZED (   -- Personen mit einem laufenden Abo
  SELECT DISTINCT fg.person_schluessel
  FROM src_mpswl.kk_subscription x JOIN fg ON fg.bestellung_id = x.orders_id
  WHERE x.active = 1
), g AS MATERIALIZED (
  SELECT s.kk_subscription_id AS abo_id, s.subscription_code AS abo_code,
         s.customers_id AS kunde_id, s.orders_id AS bestellung_id, s.products_sku AS sku,
         nullif(btrim(s.custom3), '') AS kdnr,
         s.start_date::date AS laeuft_seit, s.last_billing_date::date AS letzte_abrechnung,
         s.next_billing_date::date AS naechste_abrechnung,
         nullif(btrim(s.problem_description), '') AS stoerungstext,
         CASE WHEN s.subscription_code ~ '^R-[0-9]{8}-'
              THEN to_date(substring(s.subscription_code FROM '^R-([0-9]{8})-'), 'YYYYMMDD') END AS stillgelegt_am
  FROM src_mpswl.kk_subscription s WHERE s.problem = 1
), gp AS (
  SELECT g.*,
         (SELECT min(f.person_schluessel) FROM fg f WHERE f.bestellung_id = g.bestellung_id) AS person_schluessel,
         (SELECT min(f.fahrgast)          FROM fg f WHERE f.bestellung_id = g.bestellung_id) AS fahrgast,
         (SELECT min(f.geburtsdatum)      FROM fg f WHERE f.bestellung_id = g.bestellung_id) AS geburtsdatum
  FROM g
), k AS (
  SELECT gp.*,
    EXISTS (SELECT 1 FROM fg f WHERE f.person_schluessel = gp.person_schluessel AND f.erfolgreich
              AND f.gueltigkeitsmonat = (SELECT m FROM monat) AND f.kunde_id = gp.kunde_id)  AS ticket_selbes_konto,
    EXISTS (SELECT 1 FROM fg f WHERE f.person_schluessel = gp.person_schluessel AND f.erfolgreich
              AND f.gueltigkeitsmonat = (SELECT m FROM monat))                                AS ticket_im_monat,
    EXISTS (SELECT 1 FROM fg f WHERE f.person_schluessel = gp.person_schluessel AND f.erfolgreich
              AND f.gueltigkeitsmonat = ((SELECT m FROM monat) - interval '1 month')::date)   AS ticket_vormonat,
    EXISTS (SELECT 1 FROM bestand b WHERE b.kdnr = gp.kdnr
              OR b.person_schluessel = gp.person_schluessel)                                  AS berechtigt_im_monat,
    EXISTS (SELECT 1 FROM aktiv a WHERE a.person_schluessel = gp.person_schluessel)          AS aktives_abo_fahrgast
  FROM gp
)
SELECT
  k.abo_id, k.abo_code,
  CASE k.sku WHEN '541' THEN 'Deutschlandticket 2. Kl'
             WHEN '548' THEN 'Deutschlandticket Schule' ELSE k.sku END AS produkt,
  k.kunde_id,
  coalesce(c.kunde_email, b.kunde_email)        AS kunde_email,
  c.name                                        AS kontoinhaber,
  (c.kunde_id IS NOT NULL)                      AS konto_vorhanden,
  k.fahrgast, k.geburtsdatum,
  k.laeuft_seit, k.letzte_abrechnung, k.naechste_abrechnung, k.stillgelegt_am, k.stoerungstext,
  (SELECT m FROM monat)                         AS bestandsmonat,
  k.ticket_im_monat, k.ticket_selbes_konto, k.ticket_vormonat, k.berechtigt_im_monat, k.aktives_abo_fahrgast,
  CASE WHEN k.ticket_selbes_konto    THEN 1
       WHEN k.ticket_im_monat        THEN 2
       WHEN k.aktives_abo_fahrgast   THEN 3
       WHEN k.berechtigt_im_monat    THEN 4
       ELSE 5 END                               AS klaerung_nr,
  CASE WHEN k.ticket_selbes_konto    THEN 'erledigt: Ticket im selben Konto'
       WHEN k.ticket_im_monat        THEN 'erledigt: Ticket in anderem Konto'
       WHEN k.aktives_abo_fahrgast   THEN 'prüfen: aktives Abo, aber kein Ticket'
       WHEN k.berechtigt_im_monat    THEN 'offen: berechtigt, ohne Abo und Ticket'
       ELSE 'beendet: nicht mehr berechtigt' END AS klaerung
FROM k
LEFT JOIN rpt.kunde_360 c  ON c.kunde_id = k.kunde_id
LEFT JOIN rpt.bestellung b ON b.bestellung_id = k.bestellung_id;

-- =====================================================================
-- rpt.konto_ohne_ticket — Berechtigte mit App-Konto, aber ohne Ticket im Monat
-- =====================================================================
-- Fast alle haben ihr Konto mit dem Abo-Kundenkonto verknüpft (OVS), das
-- Ticket in der App aber nie angefordert: keine Bestellung, kein Warenkorb.
-- Die Plattform steht nur an Bestellungen — wer nie bestellt hat, hat keine.
CREATE OR REPLACE VIEW rpt.konto_ohne_ticket AS
WITH stichtag AS (
  SELECT max(kauftag) AS tag FROM rpt.bestellung
), ovs AS MATERIALIZED (
  SELECT DISTINCT customers_id FROM src_mpswl.kk_customers_to_tag WHERE name = 'OVS_CUSTOMER_ID'
), geraet AS MATERIALIZED (
  SELECT kunde_id, string_agg(DISTINCT plattform, ', ') AS plattform
  FROM rpt.bestellung WHERE plattform <> 'unbekannt' GROUP BY kunde_id
)
SELECT
  p.kunde_email, k.kunde_id, k.name AS kontoinhaber,
  p.segment, p.plz, p.ort, p.altersgruppe, p.bestandsmonat,
  k.registriert_am,
  (SELECT tag FROM stichtag) - k.registriert_am       AS tage_seit_anlage,
  k.bestellungen, k.bestellungen_erfolgreich, k.letzter_kauf,
  (o.customers_id IS NOT NULL)                       AS ovs_verknuepft,
  p.aktives_abo, p.abo_gestoert AS abo_stillgelegt, p.ticket_vormonat,
  g.plattform,
  CASE WHEN k.bestellungen = 0             THEN 1
       WHEN k.bestellungen_erfolgreich = 0 THEN 2
       WHEN p.aktives_abo                  THEN 3
       ELSE 4 END                                    AS fall_nr,
  CASE WHEN k.bestellungen = 0             THEN 'Ticket nie angefordert'
       WHEN k.bestellungen_erfolgreich = 0 THEN 'Bestellung gescheitert'
       WHEN p.aktives_abo                  THEN 'aktives Abo, Ticket fehlt'
       ELSE 'früher Ticket, jetzt ohne Abo' END      AS fall
FROM rpt.berechtigte_person p
JOIN rpt.kunde_360 k ON k.kunde_email = p.kunde_email
LEFT JOIN ovs o      ON o.customers_id = k.kunde_id
LEFT JOIN geraet g   ON g.kunde_id = k.kunde_id
WHERE p.app_konto AND NOT p.ticket_im_monat;

-- =====================================================================
-- rpt.bestellergebnis — wie jede Bestellung ausging (vor allem PayOne)
-- =====================================================================
CREATE OR REPLACE VIEW rpt.bestellergebnis AS
WITH lauf AS (
  SELECT bestellung_id,
         bool_or(status_id = 8 AND bemerkung ILIKE '%Abbruch durch Kunde%') AS kunde_brach_ab,
         bool_or(status_id = 8 AND bemerkung ILIKE '%cleaner%')             AS aufraeumjob,
         bool_or(status_id = 5)                                             AS zahlung_eingegangen
  FROM rpt.statuslauf GROUP BY 1
), pos AS (
  SELECT bestellung_id,
         string_agg(DISTINCT vertriebskanal, ', ') AS vertriebskanal,
         string_agg(produkt, ', ')                 AS produkte
  FROM rpt.bestellposition GROUP BY 1
)
SELECT
  b.bestellung_id, b.bestellnummer, b.gekauft_am, b.kauftag, b.kaufstunde,
  b.kunde_id, b.kunde_email, b.zahlungsmodul, b.plattform,
  b.status_id, b.status, b.umsatz_brutto, b.sekunden_bis_ticket,
  CASE
    WHEN b.status_id = 3            THEN 'erfolgreich'
    WHEN b.status_id = 6            THEN 'Zahlung abgelehnt'
    WHEN b.status_id = 9            THEN 'erstattet'
    WHEN b.status_id IN (51, 52)    THEN 'abgebrochen, erstattet'
    WHEN b.status_id IN (53, 54)    THEN 'Fehlkauf, erstattet'
    WHEN b.status_id = 8 AND l.kunde_brach_ab THEN 'vom Kunden abgebrochen'
    WHEN b.status_id = 8 AND l.aufraeumjob    THEN 'nicht abgeschlossen (Aufräumjob)'
    WHEN b.status_id = 8            THEN 'abgebrochen'
    ELSE coalesce(b.status, 'unbekannt')
  END                                   AS ergebnis,
  p.vertriebskanal,
  p.produkte,
  coalesce(l.zahlung_eingegangen, false) AS zahlung_eingegangen
FROM rpt.bestellung b
LEFT JOIN lauf l ON l.bestellung_id = b.bestellung_id
LEFT JOIN pos p  ON p.bestellung_id = b.bestellung_id;

-- =====================================================================
-- rpt.erstattung — jede Erstattung mit Ergebnis
-- =====================================================================
CREATE OR REPLACE VIEW rpt.erstattung AS
SELECT
  r.order_refunds_id                       AS erstattung_id,
  r.orders_id                              AS bestellung_id,
  r.orders_number                          AS bestellnummer,
  round(r.refund_amount, 2)                AS betrag,
  CASE r.refund_status WHEN 1 THEN 'erfolgreich'
                       WHEN 0 THEN 'offen'
                       WHEN -1 THEN 'fehlgeschlagen'
                       ELSE r.refund_status::text END AS ergebnis,
  coalesce(nullif(btrim(r.refund_note), ''), 'ohne Angabe') AS anlass,
  r.date_added                             AS angelegt_am,
  r.date_added::date                       AS tag,
  b.kunde_email, b.zahlungsmodul, b.status AS bestellstatus, b.gekauft_am
FROM src_mpswl.kk_order_refunds r
LEFT JOIN rpt.bestellung b ON b.bestellung_id = r.orders_id;

-- =====================================================================
-- rpt.app_nutzung — Konten, Logins, Einwilligungen, Stand heute
-- =====================================================================
CREATE OR REPLACE VIEW rpt.app_nutzung AS
SELECT
  count(*)                                                              AS konten,
  count(*) FILTER (WHERE registriert_am >= current_date - 7)            AS neu_7_tage,
  count(*) FILTER (WHERE registriert_am >= current_date - 30)           AS neu_30_tage,
  count(*) FILTER (WHERE letzter_login >= current_date - 7)             AS login_7_tage,
  count(*) FILTER (WHERE letzter_login >= current_date - 30)            AS login_30_tage,
  count(*) FILTER (WHERE email_bestaetigt)                              AS email_bestaetigt,
  count(*) FILTER (WHERE marketing_einwilligung IS NOT NULL
                     AND marketing_einwilligung NOT IN ('', '[]', '{}', 'false')) AS marketing_einwilligung,
  count(*) FILTER (WHERE loeschung_beantragt)                           AS loeschung_beantragt,
  count(*) FILTER (WHERE hat_gekauft)                                   AS mit_kauf,
  count(*) FILTER (WHERE letzter_kauf >= current_date - 30)             AS kauf_30_tage
FROM rpt.kunde_360;

-- =====================================================================
-- rpt.tagesreihe — um Einzeltickets, PayOne und Erstattungen ergänzt
-- =====================================================================
CREATE OR REPLACE VIEW rpt.tagesreihe AS
-- Mengenbasiert: je Quelle ein GROUP BY, dann an die Tage gejoint.
WITH tage AS (
  SELECT generate_series((SELECT min(kauftag) FROM rpt.bestellung),
                         (SELECT max(kauftag) FROM rpt.bestellung),
                         interval '1 day')::date AS tag
), konten AS (
  SELECT registriert_am AS tag, count(*) AS n FROM rpt.kunde_360 GROUP BY 1
), best AS (
  SELECT kauftag AS tag,
         count(*)                                              AS bestellungen,
         count(*) FILTER (WHERE erfolgreich)                   AS verkaeufe,
         count(*) FILTER (WHERE abgebrochen)                   AS abbrueche,
         coalesce(sum(umsatz_brutto) FILTER (WHERE erfolgreich), 0) AS umsatz_brutto,
         count(*) FILTER (WHERE zahlungsmodul = 'payone')      AS payone_versuche,
         count(*) FILTER (WHERE zahlungsmodul = 'payone' AND erfolgreich) AS payone_erfolgreich
  FROM rpt.bestellung GROUP BY 1
), pos AS (
  SELECT kauftag AS tag,
         count(*) FILTER (WHERE vertriebskanal = 'Abo')          AS abo_tickets,
         count(*) FILTER (WHERE vertriebskanal = 'Einzelticket') AS einzeltickets_oepnv,
         count(*) FILTER (WHERE vertriebskanal = 'Fähre')        AS faehrtickets
  FROM rpt.bestellposition WHERE erfolgreich GROUP BY 1
), erst AS (
  SELECT tag, count(*) AS n FROM rpt.erstattung GROUP BY 1
)
SELECT t.tag,
  coalesce(k.n, 0)                   AS neue_konten,
  coalesce(b.bestellungen, 0)        AS bestellungen,
  coalesce(b.verkaeufe, 0)           AS verkaeufe,
  coalesce(b.abbrueche, 0)           AS abbrueche,
  coalesce(b.umsatz_brutto, 0)       AS umsatz_brutto,
  -- neu
  coalesce(p.abo_tickets, 0)         AS abo_tickets,
  coalesce(p.einzeltickets_oepnv, 0) AS einzeltickets_oepnv,
  coalesce(p.faehrtickets, 0)        AS faehrtickets,
  coalesce(b.payone_versuche, 0)     AS payone_versuche,
  coalesce(b.payone_erfolgreich, 0)  AS payone_erfolgreich,
  coalesce(e.n, 0)                   AS erstattungen
FROM tage t
LEFT JOIN konten k ON k.tag = t.tag
LEFT JOIN best b   ON b.tag = t.tag
LEFT JOIN pos p    ON p.tag = t.tag
LEFT JOIN erst e   ON e.tag = t.tag;

-- =====================================================================
-- rpt.datenstand — wie aktuell die Zahlen sind
-- =====================================================================
CREATE OR REPLACE VIEW rpt.datenstand AS
SELECT
  (SELECT max(gekauft_am) FROM rpt.bestellung)              AS letzte_bestellung,
  (SELECT max(importiert_am) FROM rpt.abo_berechtigung)     AS bestand_importiert_am,
  (SELECT min(gueltig_ab) FROM rpt.abo_berechtigung)        AS bestand_gueltig_ab,
  (SELECT max(gueltig_bis) FROM rpt.abo_berechtigung)       AS bestand_gueltig_bis,
  (SELECT max(erfasst_am) FROM rpt.monatsstand)             AS letzter_import;

-- =====================================================================
-- rpt.payone_bereitschaft — aus dem Leerzustand werden echte Zahlen
-- =====================================================================
CREATE OR REPLACE VIEW rpt.payone_bereitschaft AS
SELECT reihenfolge, gegenstand, quellfeld, datensaetze,
       CASE WHEN datensaetze > 0 THEN 'befüllt' ELSE 'leer' END AS stand
FROM (VALUES
  (1,'Zahlungsbeleg','ipn_history: gateway_transaction_id, gateway_result, transaction_amount',
     (SELECT count(*) FROM src_mpswl.ipn_history WHERE gateway_result IS NOT NULL)),
  (2,'Zahlart','orders.payment_module_subcode',
     (SELECT count(*) FROM src_mpswl.orders WHERE payment_module_subcode IS NOT NULL)),
  (3,'Zahlerkennung','kk_customers_to_tag: PAYONE_CUSTOMER_ID',
     (SELECT count(*) FROM src_mpswl.kk_customers_to_tag WHERE name='PAYONE_CUSTOMER_ID')),
  (4,'Erstattung','kk_order_refunds: refund_amount, gateway_credit_id',
     (SELECT count(*) FROM src_mpswl.kk_order_refunds)),
  (5,'Preisstufe je Kauf','orders_products_attributes',
     (SELECT count(*) FROM src_swl.orders_products)),
  (6,'Start- und Zielzone','orders_products.custom1: start.zone / stop.zone',
     (SELECT count(*) FROM rpt.bestellposition WHERE von_zone IS NOT NULL))
) AS t(reihenfolge, gegenstand, quellfeld, datensaetze);

-- =====================================================================
-- rpt.arbeitsliste — um die Fälle aus dem Livebetrieb ergänzt
-- =====================================================================
CREATE OR REPLACE VIEW rpt.arbeitsliste AS
SELECT 'Gestörte Abos, offen' AS liste, 'Service: berechtigt, aber weder Abo noch Ticket' AS zweck,
       (SELECT count(*) FROM rpt.abo_stoerung WHERE klaerung_nr = 4) AS faelle
UNION ALL SELECT 'Gestörte Abos, prüfen', 'Aktives Abo, aber kein Ticket im Monat',
       (SELECT count(*) FROM rpt.abo_stoerung WHERE klaerung_nr = 3)
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
       (SELECT count(*) FROM rpt.bestellung_ohne_konto)
-- neu
UNION ALL SELECT 'Konto, aber kein Ticket im Monat', 'Berechtigte mit App-Konto ohne gültiges Abo-Ticket',
       (SELECT count(*) FROM rpt.berechtigte_person WHERE app_konto AND NOT ticket_im_monat)
UNION ALL SELECT 'Erstattung fehlgeschlagen', 'Buchhaltung: Betrag von Hand erstatten',
       (SELECT count(*) FROM rpt.erstattung WHERE ergebnis = 'fehlgeschlagen')
UNION ALL SELECT 'Erstattung offen', 'Buchhaltung: Stand bei PayOne prüfen',
       (SELECT count(*) FROM rpt.erstattung WHERE ergebnis = 'offen')
UNION ALL SELECT 'Zahlung abgelehnt (7 Tage)', 'Service: Kunde hat kein Ticket bekommen',
       (SELECT count(*) FROM rpt.bestellergebnis WHERE ergebnis = 'Zahlung abgelehnt'
          AND kauftag >= current_date - 7)
UNION ALL SELECT 'Kontolöschung beantragt', 'Datenschutz: Löschung nachhalten',
       (SELECT count(*) FROM rpt.kunde_360 WHERE loeschung_beantragt);

-- =====================================================================
-- Statistik der Fremdtabellen
-- =====================================================================
-- Ohne Statistik kennt der Planer die Zeilenzahlen der Quelltabellen nicht
-- und plant je nach Abfrage Schleifen über postgres_fdw: dieselbe Sicht
-- brauchte dann Minuten statt einer halben Sekunde. ANALYZE liest eine
-- Stichprobe aus der Quelle. Der Import wiederholt das nach jedem Lauf.
SELECT format('ANALYZE %I.%I', foreign_table_schema, foreign_table_name)
FROM information_schema.foreign_tables
WHERE foreign_table_schema IN ('src_mpswl', 'src_swl') \gexec
