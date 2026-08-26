#!/usr/bin/env bash
# Toolbelt on ARM64 + GPU — setup. Generates .env with fresh secrets, enables
# the GPU, warms the model, and brings the stack up.
#
# Idempotent + re-runnable: keeps an existing .env, reuses a running or stopped
# Ollama, skips already-downloaded models, and `compose up -d` just reconciles.
# Safe to re-run after an error or on an already-running box.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Toolbelt (ARM64 + GPU) setup"

# --- sanity: arch + docker ------------------------------------------------
ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || \
  echo "!! WARNING: arch is $ARCH, not arm64 — images are arm64-native; you'll emulate."
command -v docker >/dev/null || { echo "!! docker not found"; exit 1; }
command -v openssl >/dev/null || { echo "!! openssl not found"; exit 1; }

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

# --- GPU / CDI ------------------------------------------------------------
echo "==> Checking GPU access for containers (CDI)"
if [ ! -f /etc/cdi/nvidia.yaml ]; then
  echo "   No CDI spec found. Generating one (needs sudo)…"
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || \
    echo "!! Could not generate CDI. Install the NVIDIA Container Toolkit, then re-run."
else
  echo "   /etc/cdi/nvidia.yaml present."
fi

# --- Local SLM (Ollama on the GPU) — idempotent ---------------------------
# shellcheck disable=SC1091
set -a; . ./.env; set +a
echo "==> Local SLM (Ollama on the GPU)"
if docker ps -a --format '{{.Names}}' | grep -qx ollama; then
  docker start ollama >/dev/null 2>&1 || true          # exists (running or stopped) → ensure up
else
  echo "   starting Ollama…"
  docker run -d --name ollama --device nvidia.com/gpu=all \
    -p 11434:11434 -v ollama:/root/.ollama ollama/ollama:latest >/dev/null
fi
printf '   waiting for Ollama'                          # ready before we pull
for _ in $(seq 1 30); do curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 && break; printf .; sleep 2; done; echo
echo "   ensuring models present (pull is a no-op if already downloaded)…"
docker exec ollama ollama pull "${SLM_CHAT_MODEL}"
docker exec ollama ollama pull "${SLM_EMBED_MODEL}"

echo
echo "==> Bringing up the full stack (Kinetica first-boot takes 2-3 min)…"
docker compose up -d
echo
echo "==> Up. Watch it settle:  docker compose ps"
echo "    Open  http://${HOST_IP}:3080   (admin / Admin123!)"
echo "    Everything runs on this box — nothing external."
