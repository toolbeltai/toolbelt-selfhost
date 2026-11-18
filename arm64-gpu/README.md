# Toolbelt on one ARM64 + GPU box

Run the whole of Toolbelt — data plane, control plane, agent surface, document
parsing, a knowledge graph, and the language model — on **one ARM64 box with an
NVIDIA GPU**. No Kubernetes, no external model API. Proven end-to-end on an
**NVIDIA GB10** (Grace-Blackwell, `aarch64`, CUDA 13); the same images run on
**AWS Graviton + G5g**, GH200, and other ARM64 GPU hosts.

Every Toolbelt image here is a native `linux/arm64` build. The control plane
(atlas + mcp + auth + Postgres) runs in ~450 MiB of RAM; with the earlier 7B
default model on the GPU the whole box sat at ~14 GiB used of 121.

Default models: chat `gemma4:26b` (Gemma 4 26B-A4B) and embeddings
`qwen3-embedding:4b` (2560 dims), served by Ollama with a 65,536-token context.
Set them in `.env` before the first `./setup.sh`: atlas records them on its
first start only (change later in Admin → Settings; a new embedder means
re-embedding, so existing installs keep theirs).

## Quickstart

```sh
# Prereqs: ARM64 Linux, Docker, an NVIDIA GPU (nvidia-smi works),
#          the NVIDIA Container Toolkit.
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/arm64-gpu

./setup.sh     # writes .env (fresh secrets), enables GPU access (CDI),
               # pulls + warms the model, and brings the stack up
./smoke.sh     # acceptance test — proves the install end to end
```

Open `http://<HOST_IP>:3080` and sign in with **`admin` / `Admin123!`** (change
it afterward). `setup.sh` prints your `HOST_IP`.

## What runs

- **kinetica** — data plane (SQL, vectors, graph, geo). Self-configures admin + external-auth on first boot.
- **cp-db** — control-plane Postgres.
- **auth** — OIDC provider.
- **atlas** — control plane / UI + API (`:3080`).
- **mcp** — agent surface (`:3100`).
- **docling** + **smart-parser** — document parsing (PDF/OCR/layout) → chunks + entities.
- **relex** — the GLiNER knowledge-graph encoder (runs on CPU here, ~1–2s/doc).
- **ollama** — the language model on the GPU, OpenAI-compatible.

Full data path: SQL, vector search, document ingestion, and an encoder-built
knowledge graph. Entity + relation extraction is the GLiNER encoder (`relex`),
not the language model — more thorough, no token spend. To use the model for
extraction instead, set `GLINER_RELEX_URL: ""` in the compose.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The stack. |
| `setup.sh` | Generates `.env`, enables the GPU, warms the model, brings it up. |
| `smoke.sh` | Acceptance test — end-to-end checks (services, login, data, encoder, agent), non-zero exit on failure. |
| `kinetica-init.sh` | Kinetica first-boot config (external auth + admin). |
| `start_auth.sh` | OIDC provider entry point. |
| `.env.example` | Config template. Pin `TB_TAG` to a released image tag. |

## Connect an agent

```sh
cd toolbelt-selfhost/arm64-gpu && set -a; . ./.env; set +a
curl -s -H "X-Service-Secret: $TOOLBELT_SERVICE_SECRET" -H "X-Toolbelt-User: admin" \
  "http://localhost:3080/api/mcp-config?namespace=<NAMESPACE_ID>"
# → { "token": "tb_…", "url": "http://<HOST_IP>:3100/ns/<id>/mcp", "snippets": {...} }
```

Paste the `tb_` token + URL into your agent's MCP config (Claude Code/Desktop,
Cursor, …). The agent then has the full Toolbelt tool surface, every call
answered by the model and data on your box.

## Sizing the model

To use another chat model, pull it (`docker exec ollama ollama pull <tag>`) and
change it in Admin → Settings. A GB10's unified memory holds far more than the
default (~21 GB for chat + embedder); bandwidth, not capacity, is the practical
limit, so a mid-size MoE like Gemma 4 26B-A4B is the interactive sweet spot.
Agent prompts run 30K+ tokens: pick a model with a native context of 64K or more.

## Other ARM64 GPU hosts

The same images run on AWS Graviton + G5g, GH200/GB200, and other ARM64 hosts
with an NVIDIA GPU. Set `HOST_IP` in `.env` and go.
