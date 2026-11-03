#!/usr/bin/env bash
# Toolbelt light — setup. Generates .env with fresh secrets, checks the hosted
# model endpoint with your API key (and an existing Kinetica, if you use one),
# and brings the stack up. No GPU needed: the models are hosted; everything else
# runs on this box (CPU).
#
# Idempotent + re-runnable: keeps an existing .env, and `compose up -d` just reconciles.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Toolbelt light setup"

# --- sanity: arch + docker ---------------------------------------------
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || \
  echo "!! NOTE: arch is $ARCH. The knowledge-graph encoder (relex) image is x86-only; on ARM, everything else works."
command -v docker >/dev/null || { echo "!! docker not found"; exit 1; }
command -v openssl >/dev/null || { echo "!! openssl not found"; exit 1; }
command -v curl >/dev/null || { echo "!! curl not found"; exit 1; }

# --- .env -----------------------------------------------------------------
if [ -f .env ]; then
  echo "==> .env already exists — leaving it untouched."
else
  echo "==> Generating .env (fresh secrets)"
  HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "${HOST_IP:-}" ] || HOST_IP="127.0.0.1"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out .mcp_priv.pem 2>/dev/null
  openssl pkey -in .mcp_priv.pem -pubout -out .mcp_pub.pem 2>/dev/null
  PRIV="$(grep -v -- '-----' .mcp_priv.pem | tr -d '\n')"
  PUB="$(grep -v -- '-----' .mcp_pub.pem | tr -d '\n')"
  rm -f .mcp_priv.pem .mcp_pub.pem

  sed -e "s|^HOST_IP=.*|HOST_IP=${HOST_IP}|" \
      -e "s|^TOOLBELT_SERVICE_SECRET=.*|TOOLBELT_SERVICE_SECRET=$(openssl rand -base64 32)|" \
      -e "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=$(openssl rand -base64 32)|" \
      -e "s|^COOKIE_SECRET=.*|COOKIE_SECRET=$(openssl rand -base64 24)|" \
      -e "s|^TB_HANDSHAKE=.*|TB_HANDSHAKE=$(openssl rand -hex 32)|" \
      -e "s|^ACCESS_TOKEN_PRIVATE_KEY=.*|ACCESS_TOKEN_PRIVATE_KEY=${PRIV}|" \
      -e "s|^ACCESS_TOKEN_PUBLIC_KEY=.*|ACCESS_TOKEN_PUBLIC_KEY=${PUB}|" \
      .env.example > .env
  echo "   HOST_IP=${HOST_IP}  (edit .env if the browser reaches this box by another address)"
fi
chmod 600 .env

# --- Hosted model endpoint: key present and working --------------------------
set -a; . ./.env; set +a
if [ -z "${INFERENCE_API_KEY:-}" ]; then
  echo "!! Set INFERENCE_API_KEY in .env (your API key), then re-run ./setup.sh"
  exit 1
fi
# Secrets reach curl on stdin (-K -), never on its command line.
icurl(){ printf 'header = "Authorization: Bearer %s"\n' "$INFERENCE_API_KEY" | curl -K - -H 'Content-Type: application/json' "$@"; }
echo "==> Checking the model endpoint (${INFERENCE_BASE_URL})"
code=$(icurl -s -o /dev/null -w '%{http_code}' "${INFERENCE_BASE_URL}/chat/completions" \
  -d "{\"model\":\"${CHAT_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" || true)
[ "$code" = "200" ] && echo "   chat model OK (${CHAT_MODEL})" || { echo "!! chat model check failed (HTTP $code): check INFERENCE_API_KEY and CHAT_MODEL"; exit 1; }
dim=$(icurl -s "${INFERENCE_BASE_URL}/embeddings" -d "{\"model\":\"${EMBED_MODEL}\",\"input\":\"hi\"}" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null || echo 0)
[ "$dim" = "${EMBED_DIM}" ] && echo "   embedding model OK (${EMBED_MODEL}, ${dim} dims)" \
  || { echo "!! embedding check failed: got ${dim} dims, EMBED_DIM=${EMBED_DIM}"; exit 1; }

# --- Kinetica: bundled, or an existing one at KINETICA_URL ------------------
case ",${COMPOSE_PROFILES:-}," in
  *,bundled-kinetica,*)
    echo "==> Kinetica: bundled (${KINETICA_URL})" ;;
  *)
    echo "==> Kinetica: existing at ${KINETICA_URL}"
    case "$KINETICA_URL" in *//kinetica:*)
      echo "!! KINETICA_URL still names the bundled service; point it at your Kinetica"; exit 1 ;; esac
    KQ=(-s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{}')
    code=$(printf 'user = "%s:%s"\n' "$KINETICA_ADMIN_USER" "$KINETICA_ADMIN_PASSWORD" \
      | curl -K - "${KQ[@]}" "${KINETICA_URL}/show/system/status" || true)
    [ "$code" = "200" ] && echo "   admin login OK (${KINETICA_ADMIN_USER})" \
      || { echo "!! ${KINETICA_URL}: admin login failed (HTTP $code): check KINETICA_URL and KINETICA_ADMIN_*"; exit 1; }
    code=$(printf 'header = "KINETICA_HANDSHAKE_KEY: %s"\n' "$TB_HANDSHAKE" \
      | curl -K - "${KQ[@]}" -H "KINETICA_USER: ${KINETICA_ADMIN_USER}" "${KINETICA_URL}/show/system/status" || true)
    [ "$code" = "200" ] && echo "   handshake OK (external authentication)" \
      || { echo "!! handshake refused (HTTP $code): enable external authentication on Kinetica with TB_HANDSHAKE (README)"; exit 1; } ;;
esac
case ":${COMPOSE_FILE:-}:" in *:host-network.yml:*)
  echo "==> Host networking on"
  case "$KINETICA_URL" in *//kinetica:*)
    echo "!! with host networking, KINETICA_URL must be a host address (bundled: http://127.0.0.1:9191)"; exit 1 ;; esac ;;
esac

echo
. ../lib/migrate-cp-db.sh
migrate_cp_db_volume

echo "==> Bringing up the stack (a bundled Kinetica's first boot takes 2-3 min)…"
docker compose up -d
echo
echo "==> Up. Watch it settle:  docker compose ps"
echo "    Open  http://${HOST_IP}:3080   (${KINETICA_ADMIN_USER}; the bundled Kinetica's password is Admin123!)"
echo "    Models are hosted; everything else runs on this box."
