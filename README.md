# OSRS GE Price Tracker

A data pipeline that collects Old School RuneScape Grand Exchange price data
to support flipping decisions: see the gap between instant-buy and
instant-sell prices, track traded volumes to judge how fast items actually
move, and account for GE buy limits — so you can decide which items are
worth flipping.

## Architecture

The database is built in layers, warehouse-style:

- **`stg_rs07` (staging)** — raw landing zone for API data, no constraints
  on purpose: staging accepts whatever the source sends, rules are applied
  downstream. Two loading strategies, chosen per source type:
  - `stg_rs07_items` — the item catalog. The API always returns the full
    current state, so the table is **truncated and reloaded** every run.
  - `stg_5_min_prices` — 5-minute price snapshots. The API only serves the
    latest window, so the table is **append-only**: staging is the only
    place price history can accumulate.
- **`dm_rs07` (data mart)** — the modeled layer. The schema exists as a
  placeholder; it will hold an SCD2 item dimension (tracking buy-limit
  changes over time), a price fact table with a composite `(item_id, ts)`
  primary key to make duplicate loads impossible, and views with the
  business logic — flip margin after the 2% GE tax, volume filters, trends.

## Data source

[OSRS Wiki Real-time Prices API](https://prices.runescape.wiki/):
`/mapping` for the item catalog, `/5m` for price snapshots. Requests carry
a descriptive User-Agent, as the Wiki's API rules ask.

## Status

**Done:**

- ✅ `stg_rs07` staging schema — rerunnable `schema.sql` with
  least-privilege grants and a rollback smoke test
- ✅ Item catalog loader — truncate-and-reload from `/mapping`
- ✅ Price snapshot loader — append-only from `/5m`, history accumulating
- ✅ `dm_rs07` schema created (placeholder, no tables yet)

**Future:**

- 📋 SCD2 item dimension in `dm_rs07`
- 📋 Price fact table with `(item_id, ts)` primary key and
  duplicate-safe loads
- 📋 Views: flip margin after GE tax, volume filters, trends
- 📋 Scheduled loading (every 5 minutes) and a data retention policy

## Stack

Python 3 (`requests`, `SQLAlchemy` + `psycopg2`), PostgreSQL.

## Setup

1. Create the database and the loader role (one time, as a superuser —
   pick your own password):

   ```sql
   CREATE DATABASE rs07_ge_item_prices;
   CREATE ROLE osrs_script_user LOGIN PASSWORD '<your-password>';
   ```

2. Run `schema.sql` against the new database. It rebuilds the schemas from
   scratch (rerunnable) and applies least-privilege grants for the loader
   role — no CREATE or DROP rights.

3. Create `connections.py` next to the loader (not committed — it is
   connection config):

   ```python
   import os
   from sqlalchemy import create_engine

   def get_engine():
       user = "osrs_script_user"
       password = os.environ["PG_PASSWORD"]  # never hardcoded
       host = "localhost"
       port = 5432
       database = "rs07_ge_item_prices"

       return create_engine(
           f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{database}",
           pool_pre_ping=True,
       )
   ```

4. Set the `PG_PASSWORD` environment variable to the role's password.

5. Install dependencies and run:

   ```
   pip install requests sqlalchemy psycopg2-binary
   python item_and_prices.py
   ```

   Each run reloads the item catalog and appends one 5-minute price
   snapshot. Run it on a schedule (every 5 minutes) to accumulate history.

## What I learned building this

I built this to relearn SQL and learn Python APIs hands-on, with AI as a
teacher and code reviewer — it defined the steps and reviewed my work, but
did not write the code for me. Along the way I learned to read Python
tracebacks properly, why staging tables load differently depending on the
source (full-state vs windowed), why credentials never belong in committed
files, and that a copy-pasted line you did not think about is still your
bug.
