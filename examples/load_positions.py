"""Write aircraft positions into Kinetica with its Python API (pip install gpudb).

This is the pattern for your own feed: create the table once, then insert records in batches.
For a demo without a feed, --opensky N pulls N snapshots of live positions from the public
OpenSky API (needs internet; anonymous access is rate-limited to one snapshot per 10 s).

    export KINETICA_URL=http://<HOST_IP>:9191 KINETICA_USER=admin KINETICA_PASSWORD=...
    python load_positions.py --opensky 6
"""
import argparse
import json
import os
import time
import urllib.request

import gpudb

TABLE = "tracks.positions"
COLUMNS = [
    ["icao24", "string", "char8"],            # aircraft address (also the track id on maps)
    ["callsign", "string", "char16", "nullable"],
    ["ts", "long", "timestamp"],              # epoch milliseconds
    ["lon", "double"],
    ["lat", "double"],
    ["alt_ft", "int", "nullable"],
    ["speed_kt", "float", "nullable"],
    ["heading", "float", "nullable"],
    ["on_ground", "int", "int8"],
    ["origin_country", "string", "char32", "nullable"],
]


def connect():
    # A single-box install: skip discovering other cluster nodes. Kinetica knows itself by its
    # Docker-internal address, which a client on another machine can't reach (that costs a
    # warning and a timeout on every connect).
    opts = gpudb.GPUdb.Options()
    opts.username = os.environ.get("KINETICA_USER", "admin")
    opts.password = os.environ["KINETICA_PASSWORD"]
    opts.disable_auto_discovery = True
    return gpudb.GPUdb(host=os.environ.get("KINETICA_URL", "http://localhost:9191"), options=opts)


def table(db):
    db.create_schema("tracks", options={"no_error_if_exists": "true"})
    return gpudb.GPUdbTable(COLUMNS, name=TABLE, db=db)   # creates it if missing


def opensky_snapshot():
    try:
        with urllib.request.urlopen("https://opensky-network.org/api/states/all", timeout=60) as r:
            data = json.load(r)
    except OSError as e:
        raise SystemExit(f"OpenSky did not answer ({e}). It needs internet, allows anonymous users a few "
                         "hundred calls a day, and refuses connections from cloud providers' networks "
                         "(AWS, GCP, Azure): run this from an office or home connection.")
    rows = []
    for s in data.get("states") or []:
        icao, cs, country, tpos, _, lon, lat, baro, ground, vel, trk = s[:11]
        if lon is None or lat is None or tpos is None:
            continue
        rows.append({
            "icao24": icao, "callsign": (cs or "").strip() or None, "ts": int(tpos) * 1000,
            "lon": lon, "lat": lat, "alt_ft": int(baro * 3.28084) if baro is not None else None,
            "speed_kt": vel * 1.94384 if vel is not None else None, "heading": trk,
            "on_ground": 1 if ground else 0, "origin_country": country,
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--opensky", type=int, default=0, help="number of live snapshots to load")
    args = ap.parse_args()
    t = table(connect())
    for i in range(args.opensky):
        rows = opensky_snapshot()
        for k in range(0, len(rows), 5000):        # batches keep each request small
            t.insert_records(rows[k:k + 5000])
        print(f"snapshot {i + 1}: {len(rows)} positions; table now {t.size()} rows")
        if i + 1 < args.opensky:
            time.sleep(15)


if __name__ == "__main__":
    main()
