-- =========================================================
-- OSRS GE Price Tracker — dm layer load
-- Runs after staging is loaded. Order matters:
--   1) expire changed dim rows
--   2) insert new + re-versioned dim rows
--   3) fact load (needs dim done first for surr lookup)
-- =========================================================
 
-- ---------- 1) Expire changed rows ----------
UPDATE dm_rs07.dim_items_scd dis
SET
	end_dt = now(),
	is_active = FALSE,
	ta_update_dt = now()
FROM stg_rs07.stg_rs07_items sri
WHERE dis.item_src_id = sri.item_id
	AND dis.is_active = TRUE
	AND (dis.item_name  IS DISTINCT FROM sri.item_name
		OR dis.is_member IS DISTINCT FROM sri.is_member
		OR dis.ge_limit IS DISTINCT FROM sri.ge_limit
		OR dis.value IS DISTINCT FROM sri.value );
 
-- ---------- 2) Insert new rows (new items + new versions of expired ones) ----------
INSERT INTO dm_rs07.dim_items_scd (
	item_surr_id,
	start_dt,
	end_dt,
	item_src_id,
	item_name,
	is_member,
	ge_limit,
	value,
	is_active,
	source_system,
	source_entity,
	ta_insert_dt,
	ta_update_dt
)
SELECT
	nextval('dm_rs07.seq_dim_items_scd'),
	now(),
	TIMESTAMP '9999-12-31 23:59:59' AS end_dt,
	sri.item_id,
	sri.item_name,
	sri.is_member,
	sri.ge_limit,
	sri.value,
	TRUE,
	'stg_rs07' AS source_system,
	'stg_rs07_items' AS source_entity,
	now(),
	now()
FROM stg_rs07.stg_rs07_items sri
WHERE NOT EXISTS (
	SELECT 1
	FROM dm_rs07.dim_items_scd dis
	WHERE dis.item_src_id = sri.item_id
	AND dis.is_active = TRUE
);
 
-- ---------- 3) Fact load ----------
-- LEFT JOIN + COALESCE: prices without a mapped item land on default row -1.
INSERT INTO dm_rs07.fact_5m_prices (
	price_5m_id,
	item_surr_id,
	ts,
	item_src_id,
	avg_high_price,
	avg_low_price,
	high_price_volume,
	low_price_volume,
	source_system,
	source_entity,
	ta_insert_dt
)
SELECT
	nextval('dm_rs07.seq_fact_5m_prices'),
	coalesce(dis.item_surr_id, -1) AS item_surr_id,
	smp.ts,
	smp.item_id,
	smp.avg_high_price,
	smp.avg_low_price,
	smp.high_price_volume,
	smp.low_price_volume,
	'stg_rs07' AS source_system,
	'stg_5_min_prices' AS source_entity,
	now()
FROM stg_rs07.stg_5_min_prices smp
LEFT JOIN dm_rs07.dim_items_scd dis ON dis.item_src_id = smp.item_id
	AND dis.is_active = TRUE
WHERE smp.item_id IS NOT NULL AND smp.ts IS NOT NULL
ON CONFLICT ON CONSTRAINT uq_fact_5m_prices_nk DO NOTHING;
