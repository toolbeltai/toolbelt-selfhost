# Toolbelt on one x86 + NVIDIA GPU box

Run the whole of Toolbelt — data plane, control plane, agent surface, document
parsing, a knowledge graph, and the language model — on **one x86_64 box with an
NVIDIA GPU**. No Kubernetes, no external model API. Proven end-to-end on an
**NVIDIA A10G** (AWS `g5.xlarge`); the same images run on A100, L40S, H100, and
other x86 NVIDIA hosts (on-prem or cloud).

The local language model (Ollama) and the knowledge-graph encoder (relex, CUDA)
run **on the GPU**; Kinetica runs on CPU (free single-box). Toolbelt images are
multi-arch — the `linux/amd64` layer is selected automatically on x86.

> **GPU sizing.** The agentic `ask` flow runs several 7B inferences per question,
> so an **A10G-class GPU or better** is the practical floor for interactive use.
> A T4 runs the stack fine but is too slow for the agentic path. Anything from an
> A10G up (A100 / L40S / H100) is comfortable.

## Quickstart

```sh
# Prereqs: x86_64 Linux, Docker, an NVIDIA GPU (nvidia-smi works), and the
#          NVIDIA Container Toolkit (so `docker run --gpus all` works).
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/x86-gpu

./setup.sh     # writes .env (fresh secrets), verifies container GPU access,
               # pulls + warms the model on the GPU, and brings the stack up
./smoke.sh     # acceptance test — proves the install end to end
```

Open `http://<HOST_IP>:3080` and sign in with **`admin` / `Admin123!`** (change
it afterward). `setup.sh` prints your `HOST_IP`.

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
- **relex** — the GLiNER knowledge-graph encoder, **on the GPU** (CUDA), sub-second/doc.
- **ollama** — the language model **on the GPU**, OpenAI-compatible.

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
| `start_auth.sh` | OIDC provider entry point. |
| `.env.example` | Config template. Pin `TB_TAG` to a released image tag. |

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

## Sizing the model

Swap the chat model by pulling a new tag and setting `SLM_CHAT_MODEL` in `.env`
(`ollama pull qwen2.5:14b-instruct`, etc.). Fit is bounded by GPU VRAM: a 7B
model needs ~5–6 GB, so a 24 GB A10G comfortably holds 7B–14B (plus the encoder);
step up to an A100/L40S/H100 for larger models.
