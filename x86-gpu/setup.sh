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
# Offline-safe: once the images and models are on the box (a first online run,
# or lib/offline-load.sh), nothing here reaches the internet.
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

  # The encoder goes on the CPU unless the card has room beside the models
  # (chat + embedder take ~21 GB of VRAM with the default models).
  VRAM_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')"
  RELEX_DEVICE=cuda
  [ -n "${VRAM_MIB}" ] && [ "${VRAM_MIB}" -lt 30000 ] && RELEX_DEVICE=cpu

  sed -e "s|^HOST_IP=.*|HOST_IP=${HOST_IP}|" \
      -e "s|^RELEX_DEVICE=.*|RELEX_DEVICE=${RELEX_DEVICE}|" \
      -e "s|^TOOLBELT_SERVICE_SECRET=.*|TOOLBELT_SERVICE_SECRET=$(openssl rand -base64 32)|" \
      -e "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=$(openssl rand -base64 32)|" \
      -e "s|^COOKIE_SECRET=.*|COOKIE_SECRET=$(openssl rand -base64 24)|" \
      -e "s|^TB_HANDSHAKE=.*|TB_HANDSHAKE=$(openssl rand -hex 32)|" \
      -e "s|^ACCESS_TOKEN_PRIVATE_KEY=.*|ACCESS_TOKEN_PRIVATE_KEY=${PRIV}|" \
      -e "s|^ACCESS_TOKEN_PUBLIC_KEY=.*|ACCESS_TOKEN_PUBLIC_KEY=${PUB}|" \
      .env.example > .env
  echo "   HOST_IP=${HOST_IP}  (edit .env if the browser reaches this box by another address)"
  echo "   RELEX_DEVICE=${RELEX_DEVICE}  (knowledge-graph encoder; GPU memory: ${VRAM_MIB:-unknown} MiB)"
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

# --- Models: local Ollama (default) or a server you already run ------------
# shellcheck disable=SC1091
set -a; . ./.env; set +a
if [ "${LOCAL_OLLAMA:-true}" = true ]; then
  echo "==> Local models (Ollama on the GPU)"
  # Something else (Ollama installed on Windows, reached through WSL's mirrored
  # networking; a native Linux Ollama) already holding the port would make our
  # container fail to start. Say so instead.
  if [ -z "$(docker ps --filter name='^ollama$' --format '{{.Names}}')" ] &&
     (exec 3<>/dev/tcp/127.0.0.1/11434) 2>/dev/null; then
    echo "!! Port 11434 is already in use by something other than this setup's Ollama"
    echo "   container (an Ollama installed on this PC or on Windows?). Either:"
    echo "     - use it: in .env set LOCAL_OLLAMA=false and LLM_BASE_URL=http://${HOST_IP}:11434/v1"
    echo "       (see 'Already serving models?' in README.md), then re-run ./setup.sh; or"
    echo "     - stop it to free port 11434, then re-run ./setup.sh."
    exit 1
  fi
  # Pinned (gemma4 needs Ollama >= 0.30.9) so an offline box runs exactly the
  # build that was bundled. Models live in the `ollama` volume and survive
  # container recreates, upgrades and reboots.
  OLLAMA_IMAGE=ollama/ollama:0.40.16
  # CONTEXT_LENGTH: the agent sends 30K+ token prompts; Ollama's small default
  #   context would cut them off without an error.
  # FLASH_ATTENTION + KV_CACHE_TYPE=q8_0: halve the memory that long context costs.
  # KEEP_ALIVE=-1: a loaded model stays on the GPU (no cold load per question).
  OLLAMA_ENV=(-e OLLAMA_CONTEXT_LENGTH=65536 -e OLLAMA_FLASH_ATTENTION=1
              -e OLLAMA_KV_CACHE_TYPE=q8_0 -e OLLAMA_KEEP_ALIVE=-1)
  if docker ps -a --format '{{.Names}}' | grep -qx ollama; then
    have="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ollama)"
    vol="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/root/.ollama"}}{{.Name}}{{end}}{{end}}' ollama)"
    for e in "${OLLAMA_ENV[@]}"; do
      [ "$e" = -e ] && continue
      grep -qxF -- "$e" <<<"$have" || { stale=1; break; }
    done
    if [ -n "${stale:-}" ] && [ "$vol" != ollama ]; then
      echo "!! The existing 'ollama' container keeps its models outside the 'ollama' volume,"
      echo "   so it is left as is. Recreate it yourself with the settings above to use long context."
      docker start ollama >/dev/null 2>&1 || true
    elif [ -n "${stale:-}" ]; then
      echo "   recreating Ollama with the long-context settings (models stay in the 'ollama' volume)…"
      docker rm -f ollama >/dev/null
    else
      docker start ollama >/dev/null 2>&1 || true        # exists (running or stopped) → ensure up
    fi
  fi
  if ! docker ps -a --format '{{.Names}}' | grep -qx ollama; then
    echo "   starting Ollama…"
    docker run -d --name ollama --restart unless-stopped --gpus all "${OLLAMA_ENV[@]}" \
      -p 11434:11434 -v ollama:/root/.ollama "${OLLAMA_IMAGE}" >/dev/null
  fi
  printf '   waiting for Ollama'                          # ready before we pull
  for _ in $(seq 1 30); do curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 && break; printf .; sleep 2; done; echo
  # Pull only what is missing, so a re-run on an offline box doesn't fail here.
  for m in "${SLM_CHAT_MODEL}" "${SLM_EMBED_MODEL}"; do
    if docker exec ollama ollama show "$m" >/dev/null 2>&1; then
      echo "   model $m present."
    else
      echo "   pulling $m…"
      docker exec ollama ollama pull "$m"
    fi
  done

  # Warm-load both models onto the GPU now, pinned (keep_alive:-1), so the stack
  # comes up against warm models. The default chat model's first load reads ~18 GB into
  # VRAM and can take a few minutes on a busy first boot — better to pay it here, once,
  # with a progress line, than to have a user's first question hang.
  echo "   warming models on the GPU (first load of the chat model can take a few minutes)…"
  curl -fsS http://localhost:11434/api/chat \
    -d "{\"model\":\"${SLM_CHAT_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false,\"keep_alive\":-1}" >/dev/null \
    && echo "     chat model loaded." || echo "     !! chat warm-up failed — check 'docker logs ollama'."
  curl -fsS http://localhost:11434/api/embeddings \
    -d "{\"model\":\"${SLM_EMBED_MODEL}\",\"prompt\":\"hi\",\"keep_alive\":-1}" >/dev/null \
    && echo "     embedding model loaded." || echo "     !! embed warm-up failed — check 'docker logs ollama'."
else
  # Models served elsewhere: don't start, pull or warm anything; just check
  # the endpoint answers and has the models named in .env.
  LLM="${LLM_BASE_URL:-http://${HOST_IP}:11434/v1}"
  EMB="${EMBED_BASE_URL:-$LLM}"
  echo "==> Models served by your server: ${LLM} (LOCAL_OLLAMA=false)"
  for pair in "${SLM_CHAT_MODEL}|${LLM}|${LLM_API_KEY:-}" "${SLM_EMBED_MODEL}|${EMB}|${EMBED_API_KEY:-${LLM_API_KEY:-}}"; do
    IFS='|' read -r m url key <<<"$pair"
    if ! list="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${key}" "${url}/models")"; then
      echo "!! ${url}/models did not answer. Check the URL and key in .env, and that the server"
      echo "   listens on an address the containers reach (HOST_IP, not 127.0.0.1)."
    elif grep -qF "\"${m}\"" <<<"$list"; then
      echo "   model $m listed at ${url}."
    else
      echo "!! $m is not listed at ${url}/models; set SLM_CHAT_MODEL / SLM_EMBED_MODEL to the names it lists."
    fi
  done
fi

echo
. ../lib/migrate-cp-db.sh
migrate_cp_db_volume

echo "==> Bringing up the full stack (Kinetica first-boot takes 2-3 min)…"
docker compose up -d
echo
echo "==> Up. Watch it settle:  docker compose ps"
echo "    Open  http://${HOST_IP}:3080   (admin / Admin123!)"
echo "    The models run on the GPU (the encoder on ${RELEX_DEVICE:-cuda}); everything else on this box."
