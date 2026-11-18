"""Draw positions on a map with Kinetica's WMS (server-side rendering), saved as PNG.

The same GetMap parameters work as a WMS layer in OpenLayers, Leaflet or any map that speaks
WMS: point it at http://<HOST_IP>:9191/wms. Kinetica asks for HTTP Basic auth, so let your
UI's backend add the Authorization header (or proxy the requests).

    python wms_map.py points  map_points.png
    python wms_map.py tracks  map_tracks.png
    python wms_map.py heatmap map_heat.png
    python wms_map.py tracks  map_london.png -1.5,51,1,52   # zoom in: lon/lat box (min lon,min lat,max lon,max lat)

Tracks join each aircraft's positions in time order, so they need a few minutes of reports and
show best zoomed in; at world scale a short feed draws them as dots.
"""
import base64
import os
import sys
import urllib.parse
import urllib.request

STYLES = {
    "points": {"STYLES": "raster", "DOPOINTS": "true", "POINTCOLORS": "FFB000", "POINTSIZES": "2",
               "POINTSHAPES": "circle"},
    "tracks": {"STYLES": "raster", "DOPOINTS": "false", "DOTRACKS": "true", "TRACK_ID_ATTR": "icao24",
               "TRACK_ORDER_ATTR": "ts", "TRACKLINECOLORS": "00B4FF", "TRACKLINEWIDTHS": "1",
               "TRACKHEADSIZES": "4", "TRACKMARKERSIZES": "0"},
    "heatmap": {"STYLES": "heatmap", "COLORMAP": "viridis", "BLUR_RADIUS": "3"},
}


def main(style, out, bbox="-180,-90,180,90", width=1600, height=800):
    params = {"SERVICE": "WMS", "VERSION": "1.1.1", "REQUEST": "GetMap", "FORMAT": "image/png",
              "TRANSPARENT": "true", "SRS": "EPSG:4326", "BBOX": bbox, "WIDTH": width, "HEIGHT": height,
              "LAYERS": "tracks.positions", "X_ATTR": "lon", "Y_ATTR": "lat", **STYLES[style]}
    url = os.environ.get("KINETICA_URL", "http://localhost:9191") + "/wms?" + urllib.parse.urlencode(params)
    auth = base64.b64encode(f"{os.environ.get('KINETICA_USER', 'admin')}:{os.environ['KINETICA_PASSWORD']}".encode()).decode()
    req = urllib.request.Request(url, headers={"Authorization": "Basic " + auth})
    with urllib.request.urlopen(req, timeout=120) as r:
        body, ctype = r.read(), r.headers.get("Content-Type", "")
    if not ctype.startswith("image/"):
        raise SystemExit(f"WMS error: {body[:400]!r}")
    open(out, "wb").write(body)
    print(f"{style}: wrote {out} ({len(body)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], *sys.argv[3:4])
