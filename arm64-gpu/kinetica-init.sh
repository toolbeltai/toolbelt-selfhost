#!/usr/bin/env bash
# Kinetica first-boot init: turn on external authentication with a known
# handshake key, set the admin password, then hand off to the normal start.
# Runs inside the kinetica-cpu container (mounted by docker-compose). Kept as a
# real script — not an inline compose heredoc — so it's readable and testable.
#
# Reads TB_HANDSHAKE (the shared handshake plaintext) from the environment.
set -euo pipefail

mkdir -p /opt/gpudb/dev

# Persisted secret-key so the handshake encrypts to a stable value across restarts.
if [ ! -f /opt/gpudb/persist/.secret-key ]; then
  /opt/gpudb/core/bin/gpudb_generate_key.sh
  mv -f /opt/gpudb/.secret-key /opt/gpudb/persist/.secret-key
fi
ln -sf /opt/gpudb/persist/.secret-key /opt/gpudb/.secret-key

# Encrypt the (fixed) handshake plaintext with the secret-key for gpudb.conf.
ENC="$(/opt/gpudb/core/bin/gpudb_encrypt.sh --key-file /opt/gpudb/persist/.secret-key -- "${TB_HANDSHAKE}")"

# RAM tier per rank. Ranks also need working memory beyond the tier (joins,
# sorts, UDFs: under load a worker used 11-17 GB past its tier on a big box and
# was OOM-killed), so by default the tier is a third of the container's memory
# limit, split over the ranks. KINETICA_RAM_TIER_LIMIT (bytes) overrides it.
TIER="${KINETICA_RAM_TIER_LIMIT:-}"
if [ -z "$TIER" ]; then
  LIM="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo max)"
  RANKS="$(grep -cE '^rank[0-9]+\.host' /opt/gpudb/core/etc/gpudb.conf.template 2>/dev/null || true)"
  [ "${RANKS:-0}" -gt 0 ] 2>/dev/null || RANKS=1
  # No limit (or an absurd one): leave Kinetica's own default.
  if [ "$LIM" != max ] && [ "$LIM" -lt 1099511627776 ] 2>/dev/null; then TIER=$(( LIM / 3 / RANKS )); fi
fi

# Everything Toolbelt sets lives in this file: rewritten on every start and
# merged over the packaged conf by the image's start script, so a container
# re-create keeps it. Change settings here (or via .env), not in the running
# container's gpudb.conf.
{
  echo "[gaia]"
  echo "enable_external_authentication = true"
  echo "unified_security_namespace = true"
  echo "auto_create_external_users = true"
  echo "external_authentication_handshake_key = ${ENC}"
  if [ -n "${KINETICA_LICENSE_KEY:-}" ]; then echo "license_key = ${KINETICA_LICENSE_KEY}"; fi
  if [ -n "${TIER}" ]; then echo "tier.ram.default.limit = ${TIER}"; fi
} > /opt/gpudb/dev/gpudb.conf
echo "kinetica-init: RAM tier per rank = ${TIER:-image default}; license key $([ -n "${KINETICA_LICENSE_KEY:-}" ] && echo set || echo blank, developer edition)"

# One-time admin password (change it after first login).
if [ ! -f /opt/gpudb/persist/.password_set ]; then
  su -s /bin/bash gpudb -c \
    "GPUDB_ALTER_PASSWORD_PASSWORD='Admin123!' \
     /opt/gpudb/core/bin/gpudb_env.sh \
     /opt/gpudb/core/bin/gpudb_alter_password.py \
     admin /opt/gpudb/core/etc/gpudb.conf"
  touch /opt/gpudb/persist/.password_set
fi

# The image's start script ignores SIGTERM (it loops on `sleep 30`), so `docker
# compose stop` would wait out stop_grace_period and then SIGKILL the ranks
# mid-write. Run it in the background and stop Kinetica properly on TERM/INT
# (the ranks flush and shut down in about 30 s).
stop_kinetica() {
  echo "kinetica-init: stopping Kinetica cleanly…"
  /etc/init.d/gpudb stop || true
  kill "${START_PID}" 2>/dev/null || true
  exit 0
}
trap stop_kinetica TERM INT
/opt/gpudb-docker-start.sh &
START_PID=$!
wait "${START_PID}"
