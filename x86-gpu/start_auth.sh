#!/usr/bin/env bash
# Custom startup script for kinetica-auth in Toolbelt dev stack
# This script is mounted into the toolbelt-auth container

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_DIR="/app" # Internal container path
DJ_ADMIN="python3 $PROJECT_DIR/src/manage.py"

# Default environment variables if not provided
KINETICA_URL="${KINETICA_URL:-http://kinetica:9191}"
KINETICA_OAUTH_PORT="${KINETICA_OAUTH_PORT:-8380}"
KINETICA_EXTERNAL_HOST="${KINETICA_EXTERNAL_HOST:-localhost}"
KINETICA_MCP_URI="${KINETICA_MCP_URI:-http://localhost:8390}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-${KINETICA_HANDSHAKE_KEY:-dev-handshake-key}}"

# OIDC client settings
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-atlas-ui}"
OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI:-http://localhost:3000/auth/callback}"

fn_init_db() {
    echo "Initializing kinetica-auth database..."
    
    # 1. Run migrations
    $DJ_ADMIN migrate --no-input

    # 2. Create superuser
    $DJ_ADMIN createsuperuser \
        --username admin \
        --email admin@example.com \
        --noinput || echo "Superuser already exists."

    # 3. Create Atlas UI Application (Primary OIDC Client)
    echo "Registering Atlas UI Application..."
    $DJ_ADMIN createapplication \
        --client-id "$OIDC_CLIENT_ID" \
        --client-secret "$OIDC_CLIENT_SECRET" \
        --redirect-uris "$OIDC_REDIRECT_URI" \
        --no-hash-client-secret \
        --name "Atlas UI" \
        --algorithm HS256 \
        confidential authorization-code || echo "Atlas UI App already exists."
}

# Run DB initialization if sqlite db doesn't exist
if [ ! -f "$PROJECT_DIR/src/db.sqlite3" ]; then
    fn_init_db
fi

# Collect static files
$DJ_ADMIN collectstatic --no-input

echo "Starting kinetica-auth on port $KINETICA_OAUTH_PORT..."
exec gunicorn \
    --bind "0.0.0.0:$KINETICA_OAUTH_PORT" \
    --chdir "$PROJECT_DIR/src" \
    --pid "/app/logs/kinetica_auth.pid" \
    kinetica_auth.wsgi
