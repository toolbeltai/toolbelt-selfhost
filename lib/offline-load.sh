#!/usr/bin/env bash
# Load a bundle made by lib/offline-bundle.sh onto a machine with no internet.
#
#   lib/offline-load.sh <bundle-dir>
#
# Checks the files, loads the images, and fills the model volumes (Ollama's
# models, the relex encoder cache). A volume that already holds data is left
# alone. Then run the profile's ./setup.sh and ./smoke.sh as usual: with
# everything already on the box they don't need the internet.
set -euo pipefail

B="${1:?usage: lib/offline-load.sh <bundle-dir>}"
B="$(cd "$B" && pwd)"
[ -f "$B/MANIFEST.txt" ] && [ -f "$B/images.tar" ] || { echo "!! $B is not an offline bundle"; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
PROFILE="$(sed -n 's/^profile: //p' "$B/MANIFEST.txt")"
HELPER="$(sed -n 's/^helper: //p' "$B/MANIFEST.txt")"
WANT="$(sed -n 's/^platform: //p' "$B/MANIFEST.txt")"
HAVE="$(docker version -f '{{.Server.Os}}/{{.Server.Arch}}')"
[ "$WANT" = "$HAVE" ] || { echo "!! bundle is for $WANT, this Docker is $HAVE"; exit 1; }

echo "==> Checking files (a few minutes for tens of GB)"
(cd "$B" && sha -c SHA256SUMS)

echo "==> Loading images"
docker load -i "$B/images.tar"

for f in "$B"/vol-*.tar; do
  [ -e "$f" ] || continue
  v="$(basename "$f" .tar)"; v="${v#vol-}"
  if docker volume inspect "$v" >/dev/null 2>&1 &&
     [ -n "$(docker run --rm --entrypoint sh -v "$v":/v "$HELPER" -c 'ls -A /v')" ]; then
    echo "==> Volume $v already has data: left as is"; continue
  fi
  # A compose volume (<project>_<name>) gets compose's labels, so compose
  # adopts it as its own instead of warning about a foreign volume.
  labels=()
  case "$v" in *_*) labels=(--label "com.docker.compose.project=${v%%_*}" --label "com.docker.compose.volume=${v#*_}");; esac
  echo "==> Restoring volume $v"
  docker volume create ${labels[@]+"${labels[@]}"} "$v" >/dev/null
  docker run --rm --entrypoint sh -v "$v":/v -v "$B":/in:ro "$HELPER" -c "tar -C /v -xf '/in/$(basename "$f")'"
done

echo
echo "==> Loaded. Next:"
echo "    cd $(cd "$(dirname "$0")/.." && pwd)/$PROFILE"
echo "    ./setup.sh     # writes .env (set HOST_IP to this box's fixed LAN IP), starts everything"
echo "    ./smoke.sh     # proves it end to end, with the network unplugged"
