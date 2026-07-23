# OSRS GE Price Tracker

Collects Old School RuneScape Grand Exchange price data to support flipping
decisions: instant-buy vs instant-sell gap, traded volume, GE buy limits.

## Architecture

Warehouse-style, two layers:

- **`stg_rs07`** — raw landing zone, no constraints. Both tables
  truncate-and-reload every run; history lives downstream in the fact
  table, not in staging.
- **`dm_rs07`** — modeled layer:
  - `dim_items_scd` — SCD2 item dimension. Surrogate key `item_surr_id`,
    business key `item_src_id`, `start_dt`/`end_dt` validity (`9999-12-31`
    sentinel on current rows), partial unique index on
    `item_src_id WHERE is_active` so buy-limit changes are versioned, not
    overwritten.
  - `fact_5m_prices` — one row per item per 5-min window. Unique
    constraint + `ON CONFLICT DO NOTHING` makes reloads duplicate-safe.
  - `DM_loading.sql` — hand-written SCD2 merge: close changed dim rows →
    insert new/changed versions → load fact via lookup to the current dim
    row.

## Data source

[OSRS Wiki Real-time Prices API](https://prices.runescape.wiki/):
`/mapping` (catalog), `/5m` (price snapshots). Descriptive User-Agent per
their API rules.

## Status

**Done:** staging schema + loaders, `dm_rs07` schema (SCD2 dim + fact),
SCD2 merge SQL, full pipeline tested end-to-end.

**Next:** mart views (flip margin after GE tax, volume filters, trends),
scheduled loading every 5 min, fact retention policy.

## Stack

Python 3 (`requests`, `SQLAlchemy` + `psycopg2`), PostgreSQL.

## Setup

```sql
CREATE DATABASE rs07_ge_item_prices;
CREATE ROLE osrs_script_user LOGIN PASSWORD '<your-password>';
```

Run `schema.sql` (rerunnable, least-privilege grants). Create
`connections.py` next to the loader (not committed):

```python
import os
from sqlalchemy import create_engine

def get_engine():
    return create_engine(
        f"postgresql+psycopg2://osrs_script_user:"
        f"{os.environ['PG_PASSWORD']}@localhost:5432/rs07_ge_item_prices",
        pool_pre_ping=True,
    )
```

Set `PG_PASSWORD`, then:

pip install requests sqlalchemy psycopg2-binary

python item_and_prices.py

Each run reloads staging and runs the SCD2 merge into the data mart. Run
on a schedule to accumulate price history.

## What I learned

Built to relearn SQL and learn Python APIs hands-on, with AI as teacher and
reviewer — it defined steps and reviewed code, never wrote it. Learned to
read tracebacks properly, why full-state vs windowed sources load
differently, why credentials stay out of committed files, and the sharpest
one: I put `source_system`/`source_entity` into the fact table's unique
key, then relabeled one mid-project — every historical price row got
re-inserted as "new" because the constraint no longer saw them as
duplicates. A constraint only protects the grain you actually encode.