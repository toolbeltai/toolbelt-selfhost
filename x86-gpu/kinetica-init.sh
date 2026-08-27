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

cat > /opt/gpudb/dev/gpudb.conf <<EOF
[gaia]
enable_external_authentication = true
unified_security_namespace = true
auto_create_external_users = true
external_authentication_handshake_key = ${ENC}
EOF

# One-time admin password (change it after first login).
if [ ! -f /opt/gpudb/persist/.password_set ]; then
  su -s /bin/bash gpudb -c \
    "GPUDB_ALTER_PASSWORD_PASSWORD='Admin123!' \
     /opt/gpudb/core/bin/gpudb_env.sh \
     /opt/gpudb/core/bin/gpudb_alter_password.py \
     admin /opt/gpudb/core/etc/gpudb.conf"
  touch /opt/gpudb/persist/.password_set
fi

exec /opt/gpudb-docker-start.sh
