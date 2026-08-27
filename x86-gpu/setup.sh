#!/usr/bin/env bash
# Toolbelt on x86 + NVIDIA GPU — setup. Generates .env with fresh secrets,
# verifies containers can reach the GPU, warms the local model on the GPU, and
# brings the stack up.
#
# GPU usage: the local LLM (Ollama) and the knowledge-graph encoder (relex, CUDA)
# run on the GPU; Kinetica runs on CPU (free single-box). Needs docker + the
# NVIDIA Container Toolkit — both preinstalled on AWS Deep Learning GPU AMIs.
#
# Idempotent + re-runnable: keeps an existing .env, reuses a running/stopped
# Ollama, skips downloaded models, and `compose up -d` just reconciles.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Toolbelt (x86 + GPU) setup"

# --- sanity: arch + docker + driver ---------------------------------------
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || \
  echo "!! WARNING: arch is $ARCH, not x86_64 — this profile targets x86; use the arm64-gpu profile on ARM."
command -v docker >/dev/null || { echo "!! docker not found"; exit 1; }
command -v openssl >/dev/null || { echo "!! openssl not found"; exit 1; }
if command -v nvidia-smi >/dev/null; then nvidia-smi -L | head -1; else
  echo "!! nvidia-smi not found — install the NVIDIA driver (AWS DL GPU AMIs already have it)."; fi

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

# --- GPU access for containers (NVIDIA Container Toolkit) ------------------
echo "==> Checking containers can see the GPU (--gpus all)"
if docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi -L >/dev/null 2>&1; then
  echo "   OK — containers can access the GPU."
else
  echo "!! Containers can't reach the GPU. Install the NVIDIA Container Toolkit, then:"
  echo "     sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
  echo "   docs: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
  exit 1
fi

# --- Local SLM (Ollama on the GPU) — idempotent ---------------------------
# shellcheck disable=SC1091
set -a; . ./.env; set +a
echo "==> Local SLM (Ollama on the GPU)"
if docker ps -a --format '{{.Names}}' | grep -qx ollama; then
  docker start ollama >/dev/null 2>&1 || true          # exists (running or stopped) → ensure up
else
  echo "   starting Ollama…"
  docker run -d --name ollama --restart unless-stopped --gpus all \
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
echo "    Local LLM + KG encoder run on the GPU; everything else on this box."
