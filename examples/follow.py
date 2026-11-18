"""Follow the namespace timeline the way a UI would: print each new finding as it lands.

    python follow.py

Waits on the timeline (wait_seconds) instead of polling: each call returns as soon as
something new is recorded, or after 30 s with nothing. Task changes show up too, as the
timeline entries Toolbelt writes for them (task.created, task.completed, ...).
"""
import asyncio

from tb import Toolbelt


async def main():
    async with Toolbelt("ui") as tb:
        cursor = None                                  # no cursor = start from now
        while True:
            args = {"wait_seconds": 30, "limit": 50, "kinds": ["timeline"]}
            if cursor:
                args["after"] = cursor
            got = await tb.call("toolbelt_timeline", **args)
            for e in got.get("events") or []:
                d = e.get("data") or {}
                who = d.get("agentId") or d.get("agent_id") or d.get("source")
                print(f"{(e.get('at') or '')[11:19]} [{who}] {d.get('eventType')}: {d.get('content')}",
                      flush=True)
            cursor = got.get("next_cursor") or cursor


if __name__ == "__main__":
    asyncio.run(main())
