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

-- ---------- Verification ----------
SELECT table_name, table_type
FROM information_schema.tables
WHERE table_schema = 'stg_rs07';

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

-- ---------- Grants ----------
-- Loader role: least privilege, no CREATE/DROP.
-- Re-applied on every rebuild because DROP SCHEMA CASCADE removes grants.
GRANT CONNECT ON DATABASE rs07_ge_item_prices TO osrs_script_user;
GRANT USAGE ON SCHEMA stg_rs07 TO osrs_script_user;
GRANT SELECT, INSERT, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA stg_rs07 TO osrs_script_user;