"""Make a table you loaded into Kinetica part of a Toolbelt namespace, then ask about it.

Registering moves no data: Toolbelt records that the table belongs to the namespace, reads its
schema, and from then on its agent and SQL tools can use it. Run once per table.

    python register_and_ask.py tracks.positions "How many aircraft are airborne right now?"
"""
import asyncio
import json
import sys

from tb import Toolbelt


async def main(table, question):
    async with Toolbelt("setup") as tb:
        reg = await tb.call("toolbelt_register_table", kinetica_table=table,
                            description="Live aircraft positions (ADS-B), one row per report")
        print("registered:", json.dumps(reg)[:300])
        ans = await tb.call("toolbelt_ask", question=question)
        print(json.dumps(ans, indent=2)[:3000])


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2]))
