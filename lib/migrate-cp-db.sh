# Sourced by setup.sh before `docker compose up`.
#
# Postgres 18 keeps its data in /var/lib/postgresql/18/docker. Compose files
# before 2026-10-16 mounted the cp-db-data volume at /var/lib/postgresql/data,
# so the control-plane database actually lived in an unnamed volume and
# `docker compose down` + `up` lost it. The compose file now mounts cp-db-data
# at /var/lib/postgresql; this moves an existing database there, once.
migrate_cp_db_volume() {
  local c=tb-cp-db anon named fmt
  docker inspect "$c" >/dev/null 2>&1 || return 0   # fresh install: nothing to move
  fmt='{{range .Mounts}}{{if eq .Destination "%s"}}{{.Name}}{{end}}{{end}}'
  anon=$(docker inspect "$c" --format "$(printf "$fmt" /var/lib/postgresql)")
  named=$(docker inspect "$c" --format "$(printf "$fmt" /var/lib/postgresql/data)")
  [ -n "$anon" ] && [ -n "$named" ] || return 0     # already on the new layout
  echo "==> Moving the control-plane database into volume $named (one time)…"
  docker stop "$c" >/dev/null
  docker run --rm -v "$anon":/from:ro -v "$named":/to postgres:18.1-alpine \
    sh -c 'cp -a /from/. /to/ && test -f /to/18/docker/PG_VERSION'
  docker rm "$c" >/dev/null
  echo "     moved. The old unnamed volume $anon is left in place; remove it once you've checked."
}
