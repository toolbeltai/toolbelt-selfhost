"""Investigator agent: waits for tasks, claims one at a time, works it, records a verdict.

Run two of these (different --name) and they split the queue; a task is never held by both.

    python investigator.py --name investigator-1
"""
import argparse
import asyncio

from tb import Toolbelt, rows_of, when

LAST = """
SELECT ts, lat, lon, alt_ft, speed_kt FROM tracks.positions
WHERE icao24 = '{icao}' ORDER BY ts DESC LIMIT 1
"""
NEARBY_QUIET = """
SELECT COUNT(*) AS n FROM (
  SELECT icao24, MAX(ts) AS last_seen, MAX(lat) AS lat, MAX(lon) AS lon FROM tracks.positions
  WHERE on_ground = 0 AND ts > TIMESTAMPADD(MINUTE, -60, NOW()) AND icao24 <> '{icao}'
  GROUP BY icao24
  HAVING MAX(ts) < TIMESTAMPADD(MINUTE, -{quiet}, NOW())
) q
WHERE ABS(q.lat - {lat}) < 1.0 AND ABS(q.lon - {lon}) < 1.0
"""


async def work(tb, task, quiet):
    icao = task["payload"]["icao24"]
    last = rows_of(await tb.call("toolbelt_sql", query=LAST.format(icao=icao), as_written=True))
    if not last:
        return {"verdict": "no positions found"}
    p = last[0]
    n = rows_of(await tb.call("toolbelt_sql", query=NEARBY_QUIET.format(
        icao=icao, quiet=quiet, lat=p["lat"], lon=p["lon"]), as_written=True))[0]["n"]
    verdict = "coverage gap" if n >= 2 else "needs a closer look"
    await tb.call("toolbelt_record", event_type="decision", entity_name=icao,
                  content=f"{icao}: {verdict}. Last seen {when(p['ts'])} at {p['lat']:.2f}, {p['lon']:.2f}, "
                          f"{p.get('alt_ft')} ft; {n} other aircraft went quiet within 1 degree")
    return {"verdict": verdict, "others_quiet_nearby": n}


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="investigator")
    ap.add_argument("--quiet-minutes", type=int, default=10)
    ap.add_argument("--until-empty", action="store_true", help="stop when the queue is empty")
    a = ap.parse_args()
    async with Toolbelt(a.name) as tb:
        while True:
            got = await tb.call("toolbelt_task", operation="claim", queue="investigate", lease_seconds=120)
            task = got.get("task")
            if not task:
                if a.until_empty:
                    break
                await tb.call("toolbelt_timeline", kinds=["task"], wait_seconds=60, limit=1)
                continue
            result = await work(tb, task, a.quiet_minutes)
            await tb.call("toolbelt_task", operation="complete", task_id=got["task_id"],
                          claim_token=got["claim_token"], status="done", result=result)
            print(f"{a.name}: {task['payload']['icao24']} -> {result['verdict']}")


if __name__ == "__main__":
    asyncio.run(main())
