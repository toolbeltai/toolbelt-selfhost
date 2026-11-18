"""Watcher agent: finds aircraft that stopped reporting, records each one and queues a task.

    python watcher.py --quiet-minutes 10            # check once
    python watcher.py --quiet-minutes 10 --every 120   # keep checking every 2 minutes
"""
import argparse
import asyncio

from tb import Toolbelt, rows_of, when

QUIET = """
SELECT icao24, MAX(callsign) AS callsign, MAX(ts) AS last_seen
FROM tracks.positions
WHERE on_ground = 0 AND ts > TIMESTAMPADD(MINUTE, -60, NOW())
GROUP BY icao24
HAVING MAX(ts) < TIMESTAMPADD(MINUTE, -{quiet}, NOW())
ORDER BY last_seen DESC
LIMIT {limit}
"""


async def check(tb, quiet, limit):
    rows = rows_of(await tb.call("toolbelt_sql", query=QUIET.format(quiet=quiet, limit=limit),
                                 question="aircraft that stopped reporting", as_written=True))
    for r in rows:
        icao, cs, last = r["icao24"], r.get("callsign") or "?", r["last_seen"]
        await tb.call("toolbelt_record", event_type="observation", entity_name=icao,
                      content=f"{icao} ({cs}) stopped reporting; last position {when(last)}",
                      idempotency_key=f"quiet-rec-{icao}-{last}")
        await tb.call("toolbelt_task", operation="create", queue="investigate",
                      title=f"Investigate {icao} ({cs}) going quiet",
                      payload={"icao24": icao, "last_seen": when(last)},
                      idempotency_key=f"quiet-task-{icao}-{last}")
    print(f"watcher: {len(rows)} aircraft went quiet")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet-minutes", type=int, default=10)
    ap.add_argument("--limit", type=int, default=10)
    ap.add_argument("--every", type=int, default=0, help="seconds between checks; 0 = once")
    a = ap.parse_args()
    async with Toolbelt("watcher") as tb:
        while True:
            await check(tb, a.quiet_minutes, a.limit)
            if not a.every:
                break
            await asyncio.sleep(a.every)


if __name__ == "__main__":
    asyncio.run(main())
