-- =========================================================
-- OSRS GE Price Tracker — database schema
-- Rebuilds the staging and mart schemas from scratch.
-- Rerunnable: drops and recreates everything it owns.
--
-- One-time setup (run manually once, NOT part of this script):
--   CREATE DATABASE rs07_ge_item_prices;
--   CREATE ROLE osrs_script_user LOGIN PASSWORD '<set-your-own>';
-- =========================================================

-- ---------- Rebuild schemas ----------
DROP SCHEMA IF EXISTS stg_rs07 CASCADE;
CREATE SCHEMA stg_rs07;

DROP SCHEMA IF EXISTS dm_rs07 CASCADE;
CREATE SCHEMA dm_rs07;

-- ---------- Staging tables ----------
-- Raw landing zone for OSRS Wiki API data. No constraints on purpose:
-- staging accepts whatever the source sends; rules apply downstream.

-- Item catalog from /mapping (full-state source: truncate-and-reload)
CREATE TABLE stg_rs07.stg_rs07_items (
    item_id    bigint,
    item_name  text,
    is_member  boolean,
    ge_limit   int,        -- GE buy limit per 4h; NULL when API omits it
    value      bigint,
    loaded_at  timestamp
);


-- 5-minute price snapshots from /5m (windowed source: append-only)
CREATE TABLE stg_rs07.stg_5_min_prices (
    item_id            bigint,
    avg_high_price     bigint,     -- NULL when no instant-buys that window
    avg_low_price      bigint,     -- NULL when no instant-sells that window
    high_price_volume  bigint,
    low_price_volume   bigint,
    ts                 timestamp,  -- 5-min window timestamp from the API
    loaded_at          timestamp
);

-- ---------- DM tables ----------
CREATE SEQUENCE IF NOT EXISTS dm_rs07.seq_dim_items_scd;
CREATE SEQUENCE IF NOT EXISTS dm_rs07.seq_fact_5m_prices;

CREATE TABLE dm_rs07.dim_items_scd(
	item_surr_id	bigint DEFAULT nextval('dm_rs07.seq_dim_items_scd'),
	start_dt 		timestamp NOT NULL,
	end_dt			timestamp NOT NULL,
	item_src_id		bigint NOT NULL,
	item_name		text,
	is_member		boolean,
	ge_limit		int,
	value			bigint,
	is_active		boolean NOT NULL,
	source_system	text NOT NULL,
	source_entity	text NOT NULL,
	ta_insert_dt	timestamp NOT NULL,
	ta_update_dt	timestamp NOT NULL,
	
	CONSTRAINT pk_dim_items_scd PRIMARY KEY (item_surr_id)
	
);



CREATE UNIQUE INDEX IF NOT EXISTS ux_dim_items_scd_nk 
ON dm_rs07.dim_items_scd (item_src_id) WHERE is_active IS TRUE;

CREATE TABLE dm_rs07.fact_5m_prices(
	price_5m_id 	bigint DEFAULT nextval('dm_rs07.seq_fact_5m_prices'),
	item_surr_id	bigint NOT NULL,
	ts				timestamp NOT NULL,
	item_src_id		bigint NOT NULL,
	avg_high_price	bigint,
	avg_low_price	bigint,
	high_price_volume	int,
	low_price_volume	int,
	source_system	text NOT NULL,
	source_entity	text NOT NULL,
	ta_insert_dt	timestamp NOT NULL,
	
	CONSTRAINT pk_fact_5m_prices PRIMARY KEY (price_5m_id),
	CONSTRAINT uq_fact_5m_prices_nk UNIQUE (item_src_id, ts, source_system, source_entity),
	
	CONSTRAINT fk_items FOREIGN KEY (item_surr_id) REFERENCES dm_rs07.dim_items_scd (item_surr_id)
);

-- Default row

INSERT INTO dm_rs07.dim_items_scd (
  item_surr_id, start_dt, end_dt, item_src_id, item_name, is_member, ge_limit, value, is_active, source_system, source_entity, ta_insert_dt, ta_update_dt
)
SELECT
  -1, TIMESTAMP '2000-01-01 23:00:00', TIMESTAMP '9999-12-31 23:59:59', -1, 'Default item', TRUE, 9999, 9999, TRUE, 'MANUAL', 'MANUAL', now(), now()
WHERE NOT EXISTS (
  SELECT 1 FROM dm_rs07.dim_items_scd WHERE item_surr_id = -1
);

-- ---------- Verification ----------
SELECT table_name, table_type
FROM information_schema.tables
WHERE table_schema = 'stg_rs07';

SELECT table_name, table_type
FROM information_schema.tables
WHERE table_schema = 'dm_rs07';

-- Smoke test: prove tables accept rows in the intended shape,
-- without leaving test data behind.
BEGIN;
    INSERT INTO stg_rs07.stg_rs07_items
    VALUES (0, 'Test', TRUE, 1, 2, '2000-01-01 23:00:00');

    SELECT * FROM stg_rs07.stg_rs07_items;

    INSERT INTO stg_rs07.stg_5_min_prices
    VALUES (1, 100, 150, 5, 10, '2000-01-01 23:00:00', '2000-01-01 23:00:55');

    SELECT * FROM stg_rs07.stg_5_min_prices;
ROLLBACK;

BEGIN;
    INSERT INTO dm_rs07.fact_5m_prices
    VALUES (DEFAULT, -1, '1900-01-01 00:00:00', 00000, 0, 0, 0, 0, 'MANUAL', 'MANUAL', now());

    SELECT * FROM dm_rs07.fact_5m_prices;
ROLLBACK;




-- ---------- Grants ----------
-- Loader role: least privilege, no CREATE/DROP.
-- Re-applied on every rebuild because DROP SCHEMA CASCADE removes grants.
GRANT CONNECT ON DATABASE rs07_ge_item_prices TO osrs_script_user;
GRANT USAGE ON SCHEMA stg_rs07 TO osrs_script_user;
GRANT USAGE ON SCHEMA dm_rs07 TO osrs_script_user;
GRANT SELECT, INSERT, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA stg_rs07 TO osrs_script_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA dm_rs07 TO osrs_script_user;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA dm_rs07 TO osrs_script_user;