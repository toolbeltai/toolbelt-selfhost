#!/usr/bin/env bash
# Toolbelt light — setup. Generates .env with fresh secrets, checks the hosted
# model endpoint with your access token, and brings the stack up. No GPU needed:
# the models are hosted; everything else runs on this box (CPU).
#
# Idempotent + re-runnable: keeps an existing .env, and `compose up -d` just reconciles.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Toolbelt light setup"

# --- sanity: arch + docker + driver ---------------------------------------
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

# --- Hosted model endpoint: token present and working ------------------------
set -a; . ./.env; set +a
if [ -z "${INFERENCE_CLIENT_ID:-}" ] || [ -z "${INFERENCE_CLIENT_SECRET:-}" ]; then
  echo "!! Set INFERENCE_CLIENT_ID and INFERENCE_CLIENT_SECRET in .env (your access token), then re-run ./setup.sh"
  exit 1
fi
echo "==> Checking the model endpoint (${INFERENCE_HOST})"
AUTH=(-H "CF-Access-Client-Id: ${INFERENCE_CLIENT_ID}" -H "CF-Access-Client-Secret: ${INFERENCE_CLIENT_SECRET}" -H 'Content-Type: application/json')
code=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "https://${INFERENCE_HOST}/v1/chat/completions" \
  -d "{\"model\":\"${CHAT_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}")
[ "$code" = "200" ] && echo "   chat model OK (${CHAT_MODEL})" || { echo "!! chat model check failed (HTTP $code): check the token and CHAT_MODEL"; exit 1; }
dim=$(curl -s "${AUTH[@]}" "https://${INFERENCE_HOST}/v1/embeddings" -d "{\"model\":\"${EMBED_MODEL}\",\"input\":\"hi\"}" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null || echo 0)
[ "$dim" = "${EMBED_DIM}" ] && echo "   embedding model OK (${EMBED_MODEL}, ${dim} dims)" \
  || { echo "!! embedding check failed: got ${dim} dims, EMBED_DIM=${EMBED_DIM}"; exit 1; }

echo
. ../lib/migrate-cp-db.sh
migrate_cp_db_volume

echo "==> Bringing up the full stack (Kinetica first-boot takes 2-3 min)…"
docker compose up -d
echo
echo "==> Up. Watch it settle:  docker compose ps"
echo "    Open  http://${HOST_IP}:3080   (admin / Admin123!)"
echo "    Models are hosted (via inference-proxy); everything else runs on this box."
