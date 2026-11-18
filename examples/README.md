# Examples: data in, questions, agents working together, maps

Small Python scripts that run against a self-hosted Toolbelt. They use aircraft positions
(ADS-B) because that is a common first feed; swap in your own table and queries.

| Script | What it shows |
|---|---|
| `load_positions.py` | Writing records into Kinetica with its Python API (`gpudb`); `--opensky N` loads live public positions for a demo |
| `register_and_ask.py` | Making that table part of a Toolbelt namespace, then asking Toolbelt's agent about it |
| `watcher.py` | An agent that finds aircraft that stopped reporting, records each one and queues a task |
| `investigator.py` | An agent that claims those tasks one at a time, checks them and records a verdict; run two and they split the work |
| `follow.py` | Following the timeline the way a UI would: each finding as it lands, with the agent that wrote it |
| `wms_map.py` | Kinetica's map server (WMS) drawing the positions as points, tracks or a heatmap |

## Setup

```sh
sudo apt-get install -y python3-venv          # Ubuntu doesn't always ship it
python3 -m venv ~/tb-venv && . ~/tb-venv/bin/activate
pip install gpudb mcp                         # tb.py works with mcp 1.x and 2.x

# Kinetica (data in, maps)
export KINETICA_URL=http://<HOST_IP>:9191 KINETICA_USER=admin KINETICA_PASSWORD='Admin123!'

# Toolbelt (agents): a namespace, then its MCP address and a token
cd ~/toolbelt-selfhost/x86-gpu && set -a; . ./.env; set +a
H=(-H "X-Service-Secret: $TOOLBELT_SERVICE_SECRET" -H "X-Toolbelt-User: admin")
# Create the namespace in the web app (New namespace), or from here:
curl -s "${H[@]}" -H "Content-Type: application/json" -d '{"name":"ADS-B tracks"}' \
  http://localhost:3080/api/namespace                    # -> {"id": "<namespace id>", ...}
curl -s "${H[@]}" "http://localhost:3080/api/mcp-config?namespace=<namespace id>"
export TOOLBELT_MCP_URL=<url from the reply> TOOLBELT_TOKEN=<token from the reply> TOOLBELT_NAMESPACE=<namespace id>
cd ~/toolbelt-selfhost/examples
```

`--opensky` needs internet and a normal office or home connection: OpenSky refuses connections
from cloud providers' networks (AWS, GCP, Azure). Offline, or with your own feed, insert records
the same way `load_positions.py` does (`table(connect()).insert_records(rows)`).

## Run them

```sh
python load_positions.py --opensky 6                       # or your own feed
python register_and_ask.py tracks.positions "Which origin country has the most distinct aircraft?"

python follow.py &                                         # what a UI would show
python watcher.py --quiet-minutes 10                       # 1 right after a short --opensky load
python investigator.py --name investigator-1 --until-empty &
python investigator.py --name investigator-2 --until-empty

python wms_map.py points map_points.png
python wms_map.py heatmap map_heat.png
python wms_map.py tracks map_tracks.png -1.5,51,1,52       # tracks show best zoomed in (lon/lat box)
```

The PNGs are transparent overlays (no base map): the same request is a WMS layer over any map.

Each agent names itself with the `X-Toolbelt-Agent` header (`tb.py`), so every finding and task
on the timeline shows which agent did it. Tasks are claimed under a lease: a task is held by one
agent at a time, and returns to the queue if that agent stops. `idempotency_key` on writes means a
retried call never creates the same finding or task twice.
