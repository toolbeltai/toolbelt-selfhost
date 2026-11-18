# Toolbelt on one x86 + NVIDIA GPU box

Run the whole of Toolbelt — data plane, control plane, agent surface, document
parsing, a knowledge graph, and the language model — on **one x86_64 box with an
NVIDIA GPU**. No Kubernetes, no external model API. Proven end-to-end on an
**NVIDIA A10G** (AWS `g5.xlarge`); the same images run on A100, L40S, H100, and
other x86 NVIDIA hosts (on-prem or cloud).

The local language model (Ollama) and the knowledge-graph encoder (relex, CUDA)
run **on the GPU**; Kinetica runs on CPU (free single-box). Toolbelt images are
multi-arch — the `linux/amd64` layer is selected automatically on x86.

> **GPU sizing.** Default models: chat `gemma4:26b` (Gemma 4 26B-A4B, ~19 GB
> download) and embeddings `qwen3-embedding:4b` (2560 dims, ~2.5 GB). Together
> they need about 21 GB of VRAM plus room for a 65,536-token context. See
> [Sizing](#sizing-the-models) below.

## Quickstart

```sh
# Prereqs: x86_64 Linux, Docker, an NVIDIA GPU (nvidia-smi works), and the
#          NVIDIA Container Toolkit (so `docker run --gpus all` works).
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/x86-gpu

./setup.sh     # writes .env (fresh secrets), verifies container GPU access,
               # pulls + warms the models on the GPU, and brings the stack up
./smoke.sh     # acceptance test — proves the install end to end
```

Open `http://<HOST_IP>:3080` and sign in with **`admin` / `Admin123!`** (change
it afterward). `setup.sh` prints your `HOST_IP`.

**Pick the models before the first `./setup.sh`.** Atlas records the chat and
embedding model (`SLM_CHAT_MODEL`, `SLM_EMBED_MODEL`, `SLM_EMBED_DIM` in `.env`)
on its first start only. After that, change them in **Admin → Settings**.
Existing installs keep the embedder they started with: vectors from different
embedders don't mix, so a new embedder means re-embedding your documents. The
`qwen3-embedding:4b` default is for new installs.

### On a cloud GPU instance (e.g. AWS)

Any NVIDIA x86 cloud box works. On AWS, a **`g5.xlarge`** (A10G) launched from a
**Deep Learning GPU AMI** (NVIDIA driver + Docker + Container Toolkit
preinstalled) runs this out of the box — SSH in and follow the Quickstart. Point
`HOST_IP` at the address your browser/agents reach the box by.

## What runs

- **kinetica** — data plane (SQL, vectors, graph, geo). Self-configures admin + external-auth on first boot.
- **cp-db** — control-plane Postgres.
- **auth** — OIDC provider.
- **atlas** — control plane / UI + API (`:3080`).
- **mcp** — agent surface (`:3100`).
- **docling** + **smart-parser** — document parsing (PDF/OCR/layout) → chunks + entities.
- **relex** — the GLiNER knowledge-graph encoder: on the GPU (CUDA, sub-second/doc) or on the CPU (~1-2 s/doc), see `RELEX_DEVICE`.
- **ollama** — the chat and embedding models **on the GPU**, OpenAI-compatible. Started by `setup.sh` (pinned `ollama/ollama:0.40.16`, 65,536-token context, flash attention, q8_0 KV cache, models kept loaded); models live in the `ollama` volume.

Full data path: SQL, vector search, document ingestion, and an encoder-built
knowledge graph. Entity + relation extraction is the GLiNER encoder (`relex`),
not the language model — more thorough, no token spend. To use the model for
extraction instead, set `GLINER_RELEX_URL: ""` in the compose.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The stack. |
| `setup.sh` | Generates `.env`, verifies GPU access, warms the model, brings it up. |
| `smoke.sh` | Acceptance test — end-to-end checks (services, login, data, encoder, agent), non-zero exit on failure. |
| `kinetica-init.sh` | Kinetica first-boot config (external auth + admin). |
| `../lib/offline-bundle.sh`, `../lib/offline-load.sh` | Package a working install for an offline machine, and load it there. |
| `start_auth.sh` | OIDC provider entry point. |
| `.env.example` | Config template: models, `RELEX_DEVICE`, `HOST_IP`. Pin `TB_TAG` to a released image tag. |

## Connect an agent

```sh
cd toolbelt-selfhost/x86-gpu && set -a; . ./.env; set +a
curl -s -H "X-Service-Secret: $TOOLBELT_SERVICE_SECRET" -H "X-Toolbelt-User: admin" \
  "http://localhost:3080/api/mcp-config?namespace=<NAMESPACE_ID>"
# → { "token": "tb_…", "url": "http://<HOST_IP>:3100/ns/<id>/mcp", "snippets": {...} }
```

Paste the `tb_` token + URL into your agent's MCP config (Claude Code/Desktop,
Cursor, …). The agent then has the full Toolbelt tool surface, every call
answered by the model and data on your box.

## Already serving models?

If this PC already runs a model server (Ollama installed on Windows, vLLM,
LM Studio, ...), point Toolbelt at it instead of starting another Ollama. In
`.env`, before the first `./setup.sh`:

```sh
LOCAL_OLLAMA=false                         # setup.sh won't start, pull or warm Ollama
LLM_BASE_URL=http://${HOST_IP}:11434/v1    # your server's OpenAI-compatible /v1
LLM_API_KEY=ollama                         # whatever key it wants (Ollama ignores it)
EMBED_BASE_URL=${LLM_BASE_URL}             # only if embeddings come from another server
EMBED_API_KEY=${LLM_API_KEY}
SLM_CHAT_MODEL=<chat model name as your server lists it>
SLM_EMBED_MODEL=<embedding model name as your server lists it>
SLM_EMBED_DIM=<that embedding model's vector size>
```

The server needs:

- an OpenAI-compatible API (`/v1/models`, `/v1/chat/completions`, `/v1/embeddings`);
- a chat model with tool calling and a context window of at least 64K tokens
  configured on the server (for Ollama: `OLLAMA_CONTEXT_LENGTH=65536`; its
  default is far smaller and cuts prompts off without an error);
- an embedding model, with its dimension in `SLM_EMBED_DIM`;
- to listen on an address the containers reach: `HOST_IP`, not `127.0.0.1`.
  An Ollama on Windows listens on 127.0.0.1 unless you set `OLLAMA_HOST=0.0.0.0`
  in its environment.

`setup.sh` checks that both models are listed, and `./smoke.sh` tests against
your server. If `setup.sh` stops because port 11434 is taken, that is the
existing server: set `LOCAL_OLLAMA=false` as above, or stop it.

## Sizing the models

Download sizes from the Ollama registry: `gemma4:26b` 17.1 GB weights + 1.2 GB
vision projector + 0.5 GB draft model; `qwen3-embedding:4b` 2.5 GB. Add the
65,536-token context (flash attention and a q8_0 KV cache keep it small) and
Ollama's working memory. The relex encoder needs another ~2-3 GB if it runs on
the GPU.

| GPU memory | What fits |
|---|---|
| 48 GB and up (L40S, A100, H100) | Everything on the GPU, encoder included (`RELEX_DEVICE=cuda`). |
| 24 GB (A10G, L4, RTX 4090) | Chat + embedder on the GPU, just. Encoder on the CPU. |
| 20 GB (RTX 4000 Ada) | Encoder on the CPU. `gemma4:26b` + the embedder are slightly more than the card holds, so Ollama keeps a few GB of the chat model in system RAM: it works, answers are slower. For everything on the GPU, set `SLM_CHAT_MODEL=gemma4:26b-a4b-it-qat` (14.4 GB weights) before the first `./setup.sh`. |

These figures are worked out from the download sizes; `nvidia-smi` and
`docker exec ollama ollama ps` show the real split on your box.

### 20 GB GPUs: encoder on CPU

One line in `.env`:

```sh
RELEX_DEVICE=cpu
```

then `docker compose up -d relex`. `setup.sh` writes `RELEX_DEVICE=cpu` itself
when it creates `.env` on a card with less than 30 GB, and `cuda` otherwise.
On the CPU the encoder takes ~1-2 s per document instead of sub-second, and
all of the GPU's memory goes to the models.

To use another chat model, pull it (`docker exec ollama ollama pull <tag>`) and
change the model in **Admin → Settings** (on a new install, set
`SLM_CHAT_MODEL` in `.env` before the first `./setup.sh`). Agent prompts run
30K+ tokens, so pick a model with a native context of 64K or more.

## Windows 11 (WSL2) and offline

> **Not yet proven end to end.** This path is written from the parts that are
> known to work (Docker Engine and NVIDIA GPUs under WSL2); a full install on a
> Windows 11 PC has not been run yet.

1. **Ubuntu under WSL2.** In an admin PowerShell: `wsl --install -d Ubuntu-24.04`,
   then reboot.
2. **Give the VM memory and a real LAN address.** Create
   `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   memory=24GB
   networkingMode=mirrored
   ```

   then `wsl --shutdown` and open Ubuntu again.
3. **Docker Engine inside Ubuntu** (Docker Desktop is not needed):

   ```sh
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker $USER     # then close and reopen the Ubuntu window
   ```
4. **NVIDIA Container Toolkit.** Install the Windows NVIDIA driver only (WSL
   brings it into Ubuntu; do not install a Linux driver). In Ubuntu, install
   `nvidia-container-toolkit` from NVIDIA's apt repository
   ([guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)),
   then:

   ```sh
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
   ```

   The last command must print your GPU.
5. **Clone into the Linux home, not `/mnt/c`** (Windows drives are slow and
   break file permissions inside containers):

   ```sh
   cd ~ && git clone https://github.com/toolbeltai/toolbelt-selfhost
   cd toolbelt-selfhost/x86-gpu
   ```
6. **Set `HOST_IP` before the first run.** It must be an address that both the
   Windows browser and the containers reach, and that still exists when the
   network cable is unplugged. In practice: give the PC a fixed LAN IP in
   Windows, and with mirrored networking that same address is the WSL address.
   `./setup.sh` guesses `HOST_IP` when it writes `.env`; if it picked another
   address, edit `HOST_IP` in `.env` and run `./setup.sh` again. A DHCP address
   that vanishes when the cable is out breaks sign-in and the model connection
   offline.
7. **Run it online once:** `./setup.sh` then `./smoke.sh`. This downloads every
   image and model.
8. **Offline proof:** disconnect the network and run `./smoke.sh` again. It
   must pass with no internet.

### Installing on a machine that is never online

Do steps 1-7 on a connected machine with the same CPU architecture (x86_64),
then package it:

```sh
lib/offline-bundle.sh x86-gpu        # from the repo root; writes ~/toolbelt-offline-x86-gpu
```

That folder holds every image (Ollama and the GPU-check image included), the
Ollama models volume and the relex encoder cache, a `MANIFEST.txt` and
checksums: roughly 45-50 GB with the default models. It carries no user data;
the offline box starts as a fresh install. Copy the folder and this repo to the
offline machine (prepared with steps 1-6; Docker and the NVIDIA toolkit
packages have to come across too), then:

```sh
lib/offline-load.sh ~/toolbelt-offline-x86-gpu   # checks files, loads images, fills the model volumes
cd x86-gpu && ./setup.sh && ./smoke.sh
```

`setup.sh` skips models that are already there and `docker compose up` uses
the loaded images, so neither reaches the internet. Optionally set
`HF_HUB_OFFLINE=1` in `.env` so relex never even tries huggingface.co.
