#!/usr/bin/env bash
# Package a working profile for a machine with no internet.
#
#   lib/offline-bundle.sh <profile> [out-dir]      e.g.  lib/offline-bundle.sh x86-gpu
#
# Run it on a connected machine with the same CPU architecture as the offline
# one, after ./setup.sh (and ideally ./smoke.sh) passed there. It writes, to
# out-dir (default ~/toolbelt-offline-<profile>):
#
#   images.tar      every image the profile runs (docker save), Ollama included
#   vol-*.tar       the model volumes: Ollama's models, the relex encoder cache
#   MANIFEST.txt    what is inside
#   SHA256SUMS      checksums, verified by lib/offline-load.sh
#
# Copy that folder and this repo to the offline machine, then run
# lib/offline-load.sh there. User data (Kinetica, control-plane DB) is not
# included: the offline box starts as a fresh install.
set -euo pipefail

PROFILE="${1:?usage: lib/offline-bundle.sh <profile> [out-dir]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/$PROFILE/docker-compose.yml" ] || { echo "!! no profile '$PROFILE' in $ROOT"; exit 1; }
cd "$ROOT/$PROFILE"
[ -f .env ] || { echo "!! no $PROFILE/.env: run ./setup.sh in $PROFILE first"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
OUT="${2:-$HOME/toolbelt-offline-$PROFILE}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

PROJECT="$(docker compose config | sed -n 's/^name: //p' | head -1)"
HELPER="$(docker compose config --images | grep -m1 '^postgres:')"   # small image with tar, used to copy volumes
PLATFORM="$(docker version -f '{{.Server.Os}}/{{.Server.Arch}}')"

# Images: the compose file's, the GPU check image setup.sh runs, and Ollama's.
IMAGES=()
while IFS= read -r i; do [ -n "$i" ] && IMAGES+=("$i"); done < <(
  { docker compose config --images
    grep -ohE 'nvidia/cuda:[A-Za-z0-9._-]+' setup.sh 2>/dev/null || true
    docker ps -a --filter name='^ollama$' --format '{{.Image}}'
  } | sort -u)
missing=0
for i in "${IMAGES[@]}"; do
  docker image inspect "$i" >/dev/null 2>&1 || { echo "!! image not on this machine: $i"; missing=1; }
done
[ "$missing" = 0 ] || { echo "   run ./setup.sh in $PROFILE (it pulls them), then re-run this."; exit 1; }

# Model volumes. Only the ones that exist (a profile without Ollama has none).
VOLS=()
for v in ollama "${PROJECT}_relex-models"; do
  docker volume inspect "$v" >/dev/null 2>&1 && VOLS+=("$v")
done
if docker ps --format '{{.Names}}' | grep -qx ollama; then
  for m in "${SLM_CHAT_MODEL:-}" "${SLM_EMBED_MODEL:-}"; do
    [ -z "$m" ] || docker exec ollama ollama show "$m" >/dev/null 2>&1 \
      || { echo "!! Ollama does not have $m (from .env): run ./setup.sh first"; exit 1; }
  done
fi

echo "==> Saving ${#IMAGES[@]} images for $PLATFORM to $OUT/images.tar (this takes a while)"
printf '     %s\n' "${IMAGES[@]}"
SAVE_FLAGS=()
# Docker's containerd image store keeps multi-platform indexes; save only ours.
docker save --help 2>/dev/null | grep -q -- '--platform' && SAVE_FLAGS=(--platform "$PLATFORM")
docker save ${SAVE_FLAGS[@]+"${SAVE_FLAGS[@]}"} -o "$OUT/images.tar" "${IMAGES[@]}"

for v in ${VOLS[@]+"${VOLS[@]}"}; do
  echo "==> Exporting volume $v"
  docker run --rm --entrypoint sh -v "$v":/v:ro -v "$OUT":/out "$HELPER" \
    -c "tar -C /v -cf '/out/vol-$v.tar' . && chown $(id -u):$(id -g) '/out/vol-$v.tar'"
done

{
  echo "Toolbelt offline bundle"
  echo "profile: $PROFILE"
  echo "created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo commit: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "platform: $PLATFORM"
  echo "helper: $HELPER"
  echo
  echo "images:"
  for i in "${IMAGES[@]}"; do echo "  $i"; done
  echo
  echo "volumes:"
  for v in ${VOLS[@]+"${VOLS[@]}"}; do echo "  $v  $(du -h "$OUT/vol-$v.tar" | cut -f1)"; done
  if docker ps --format '{{.Names}}' | grep -qx ollama; then
    echo
    echo "ollama models:"
    docker exec ollama ollama list 2>/dev/null | sed 's/^/  /' || true
  fi
} > "$OUT/MANIFEST.txt"

echo "==> Checksums"
(cd "$OUT" && sha images.tar vol-*.tar > SHA256SUMS)
echo
cat "$OUT/MANIFEST.txt"
echo
echo "==> Done: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "    Copy it and this repo to the offline machine, then run:  lib/offline-load.sh <that folder>"
