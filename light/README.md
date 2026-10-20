# Toolbelt light — CPU box, hosted models

Toolbelt on any CPU box, **no GPU**. The language and embedding models are hosted
(Toolbelt-hosted inference, or any OpenAI-compatible endpoint); everything else runs
on your box. This is the fastest way to stand Toolbelt up next to a Kinetica proof of
concept: one command, no GPU drivers, no model downloads.

## What runs where

**On the box:** atlas (UI + API), mcp (agent endpoint), auth, Postgres, Kinetica
(CPU build), document parsing (docling), chunking (smart-parser), and knowledge-graph
extraction (GLiNER-relex on CPU, ~1–2 s per document).

**Hosted:** the chat model and the embedding model, reached through `inference-proxy`,
a small nginx container that adds your access token to each request. The token lives
only in `.env` and that container; no other service sees it.

**What leaves the box:** model calls only: questions, the context retrieved to answer
them, and document chunks being embedded. Your tables, files, parsed documents and
knowledge graph stay on the box. The hosted inference doesn't store requests.

## Install

```sh
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/light
cp .env.example .env     # optional: setup.sh does this too
# put your access token in .env: INFERENCE_CLIENT_ID and INFERENCE_CLIENT_SECRET
./setup.sh               # writes secrets, checks the model endpoint with your token, brings it up
./smoke.sh               # proves it end to end
```

Then open `http://<HOST_IP>:3080` (admin / Admin123!).

`setup.sh` stops before starting anything if the token is missing or the endpoint
doesn't answer, and checks that `EMBED_DIM` matches what the embedding model returns.

## Models

| | Default | Setting |
|---|---|---|
| Chat | `gemma-4-26b` | `CHAT_MODEL` |
| Embeddings | `qwen3-embedding-4b`, 2560 dimensions | `EMBED_MODEL`, `EMBED_DIM` |
| Endpoint | `inference.toolbelt.ai` | `INFERENCE_HOST` |

To use your own endpoint instead, set `INFERENCE_HOST` and the model names. If your
endpoint uses a bearer API key rather than Cloudflare Access, edit
`inference-proxy.conf.template` to send `Authorization: Bearer <key>` instead.

## Requirements

Docker with Compose v2, `curl`, `openssl`, outbound HTTPS to the model endpoint.
RAM: 32 GB minimum (Kinetica + docling + relex), more for larger data. x86_64; on ARM
everything works except the knowledge-graph encoder (relex has no ARM image yet).

## Status

New profile (2026-10-20). Built from the proven x86-gpu profile with the local model
and GPU removed. Verify with `./smoke.sh` on your box.
