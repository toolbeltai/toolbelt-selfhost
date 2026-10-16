#!/usr/bin/env bash
# Recover a control-plane database left in an unnamed Docker volume.
#
# Only needed if an install from before 2026-10-16 was upgraded with a bare
# `docker compose up` instead of ./setup.sh: the app then starts on an empty
# database while the old one sits in an unnamed volume. Nothing was deleted.
#
#   lib/recover-cp-db.sh                     list candidate volumes
#   lib/recover-cp-db.sh <volume> <profile>  move that volume's database into
#                                            the profile's cp-db-data volume
#                                            (replaces what's there now)
set -euo pipefail
IMG=postgres:18.1-alpine

if [ $# -eq 0 ]; then
  echo "Unnamed volumes holding a Postgres 18 database (size, volume, last write):"
  for v in $(docker volume ls -q --filter label=com.docker.volume.anonymous); do
    docker run --rm -v "$v":/v:ro "$IMG" sh -c '
      [ -f /v/18/docker/PG_VERSION ] || exit 1
      printf "%s  %s  last write %s\n" "$(du -sh /v | cut -f1)" "$0" "$(date -r /v/18/docker/global/pg_control "+%F %R" 2>/dev/null)"' "$v" 2>/dev/null || true
  done
  echo
  echo "Pick the newest one, then: lib/recover-cp-db.sh <volume> <x86-gpu|arm64-gpu>"
  exit 0
fi

vol="$1"; profile="${2:?profile folder, e.g. x86-gpu}"
cd "$(dirname "$0")/../$profile"
target="$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"]["cp-db-data"]["name"])')"
echo "Moving the database from $vol into $target (the current contents of $target are replaced)."
read -r -p "Type yes to continue: " ok; [ "$ok" = yes ] || exit 1
docker compose stop cp-db
docker run --rm -v "$vol":/from:ro -v "$target":/to "$IMG" \
  sh -c 'rm -rf /to/18 && cp -a /from/. /to/ && test -f /to/18/docker/PG_VERSION'
docker compose start cp-db
echo "Done. Check the app, then remove $vol with: docker volume rm $vol"
