"""OSRS GE price tracker — staging loaders.

Pulls item catalog and 5-minute price data from the OSRS Wiki
real-time prices API and lands it in the stg_rs07 schema.

Loading strategies (deliberate, per source type):
  - items  : full-state source -> truncate-and-reload every run
  - prices : windowed source (last 5 min only) -> append-only,
             history accumulates in staging
"""

import requests
from datetime import datetime

from connections import get_engine  # see README for connections.py example

API_BASE = "https://prices.runescape.wiki/api/v1/osrs"

# The OSRS Wiki asks API users to identify themselves (see their API rules)
UA = "rs07_ge_price_script/0.1 (personal script; contact: tequila8304)"
HEADERS = {"User-Agent": UA}


def get_items():
    """Fetch the full item catalog from /mapping.

    Returns a list of tuples matching stg_rs07_items column order.
    Some items lack "limit"/"value" keys -> .get() yields None,
    which lands as NULL in the nullable columns.
    """
    response = requests.get(f"{API_BASE}/mapping", headers=HEADERS, timeout=10)
    items = response.json()

    loaded_at = datetime.now()  # one timestamp for the whole batch
    items_list = []
    for item in items:
        row = (
            item.get("id"),
            item.get("name"),
            item.get("members"),
            item.get("limit"),
            item.get("value"),
            loaded_at,
        )
        items_list.append(row)
    return items_list


def get_item_prices():
    """Fetch the latest 5-minute price snapshot from /5m.

    The API returns {"data": {item_id: {...}}, "timestamp": unix_ts}:
    item ids are dict keys (strings), and the window timestamp appears
    once at the top level - so it is converted once and repeated
    into every row.
    """
    response = requests.get(f"{API_BASE}/5m", headers=HEADERS, timeout=10)
    payload = response.json()

    data = payload["data"]
    ts = datetime.fromtimestamp(payload["timestamp"])
    loaded_at = datetime.now()

    price_list = []
    for item_id, price in data.items():
        row = (
            int(item_id),  # dict keys arrive as strings
            price.get("avgHighPrice"),      # None = no instant-buys that window
            price.get("avgLowPrice"),       # None = no instant-sells that window
            price.get("highPriceVolume"),
            price.get("lowPriceVolume"),
            ts,
            loaded_at,
        )
        price_list.append(row)
    return price_list


def insert_items_to_stg(items_list):
    """Truncate-and-reload the item catalog staging table."""
    if not items_list:
        return 0

    sql = """
        INSERT INTO stg_rs07.stg_rs07_items
            (item_id, item_name, is_member, ge_limit, value, loaded_at)
        VALUES (%s, %s, %s, %s, %s, %s)
    """
    conn = get_engine().raw_connection()
    cur = conn.cursor()
    cur.execute("TRUNCATE TABLE stg_rs07.stg_rs07_items;")
    cur.executemany(sql, items_list)
    conn.commit()
    rowcount = cur.rowcount
    conn.close()

    print(f"Loaded {rowcount} items into stg_rs07.stg_rs07_items")
    return rowcount


def insert_item_prices_to_stg(price_list):
    """Append one 5-minute price snapshot to staging.
    """
    if not price_list:
        return 0

    sql = """
        INSERT INTO stg_rs07.stg_5_min_prices
            (item_id, avg_high_price, avg_low_price,
             high_price_volume, low_price_volume, ts, loaded_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
    """
    conn = get_engine().raw_connection()
    cur = conn.cursor()
    cur.execute("TRUNCATE TABLE stg_rs07.stg_5_min_prices;")
    cur.executemany(sql, price_list)
    conn.commit()
    rowcount = cur.rowcount
    conn.close()

    print(f"Loaded {rowcount} price rows into stg_rs07.stg_5_min_prices")
    return rowcount

def dm_layer_load():
    conn = get_engine().raw_connection()
    cur = conn.cursor()
    with open("DM_loading.sql") as f:
        sql = f.read()
    cur.execute(sql)
    conn.commit()
    conn.close()


def main():
    insert_items_to_stg(get_items())
    insert_item_prices_to_stg(get_item_prices())
    dm_layer_load()


if __name__ == "__main__":
    main()