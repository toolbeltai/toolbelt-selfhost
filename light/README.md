# Toolbelt light — CPU box, hosted models

Toolbelt on any CPU box, **no GPU**. The chat and embedding models are hosted
(Toolbelt-hosted inference, or any OpenAI-compatible endpoint); everything else runs
on your box. This is the fastest way to stand Toolbelt up next to a Kinetica proof of
concept: one command, no GPU drivers, no model downloads. It can bring its own
Kinetica or use one you already run.

## What runs where

**On the box:** atlas (UI + API), mcp (agent endpoint), auth, Postgres, Kinetica
(CPU build, unless you use your own), document parsing (docling), chunking
(smart-parser), and knowledge-graph extraction (GLiNER-relex on CPU, ~1–2 s per
document).

**Hosted:** the chat model and the embedding model, called directly over HTTPS with
your API key (`Authorization: Bearer`). The key lives only in `.env` (mode 600) and
in the containers that call the models.

**What leaves the box:** model calls only: questions, the context retrieved to answer
them, and document chunks being embedded. Your tables, files, parsed documents and
knowledge graph stay on the box. The hosted inference doesn't store requests.

## Install

```sh
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/light
./setup.sh               # first run writes .env and stops: put your key in it
#   INFERENCE_API_KEY=<your key>
./setup.sh               # checks the models with your key, brings it up
./smoke.sh               # proves it end to end
```

Then open `http://<HOST_IP>:3080` (admin / Admin123! with the bundled Kinetica).

`setup.sh` stops before starting anything if the key is missing or the endpoint
doesn't answer, and checks that `EMBED_DIM` matches what the embedding model returns.

## Models

| | Default | Setting |
|---|---|---|
| Endpoint | `https://inference.toolbelt.ai/v1` | `INFERENCE_BASE_URL` |
| API key | — | `INFERENCE_API_KEY` |
| Chat | `chat` (Gemma 4 26B) | `CHAT_MODEL` |
| Embeddings | `embeddings` (Qwen3-Embedding-4B), 2560 dimensions | `EMBED_MODEL`, `EMBED_DIM` |

Any OpenAI-compatible endpoint that takes a bearer key works: set the URL, key and
model names. The models are written into atlas on first start; to change them later,
use the Models page in the UI (or start from a fresh `cp-db` volume).

## Use an existing Kinetica

Toolbelt talks to Kinetica as a trusted front end: Kinetica must have external
authentication on, with a handshake key Toolbelt also knows. In your Kinetica's
`gpudb.conf` (`[gaia]` section), then restart Kinetica:

```ini
enable_external_authentication = true
external_authentication_handshake_key = <encrypted handshake>   # gpudb_encrypt.sh "<handshake>"
unified_security_namespace = true
auto_create_external_users = true
```

Then in `.env`:

```sh
COMPOSE_PROFILES=                      # empty: don't start the bundled Kinetica
KINETICA_URL=http://<host>:9191        # as the containers reach it
TB_HANDSHAKE=<handshake>               # the plaintext you encrypted above
KINETICA_ADMIN_USER=admin              # the UI login: a Kinetica user and its password
KINETICA_ADMIN_PASSWORD='<password>'
```

`setup.sh` checks the admin login and the handshake against `KINETICA_URL` before
starting anything. If Kinetica runs on this box with host networking, the containers
reach it at the box's LAN IP (`http://<HOST_IP>:9191`); a host firewall must allow
that, or use host networking below.

## Host networking

Some boxes only work with host networking. On AWS, an instance-metadata hop limit of
1 means containers on a Docker bridge can't get the instance role's credentials (S3
loads fail). In `.env`:

```sh
COMPOSE_FILE=docker-compose.yml:host-network.yml
KINETICA_URL=http://127.0.0.1:9191     # bundled, or your existing Kinetica
```

Every service then uses the host's network; they reach each other on 127.0.0.1. Host
ports: atlas 3080, mcp 3100, auth 8380, smart-parser 3200, docling 5001, relex 8090,
Postgres 5433 (127.0.0.1 only), plus Kinetica's own when bundled. These must be free.

## Requirements

Docker with Compose v2.24 or later, `curl`, `openssl`, `python3`, outbound HTTPS to
the model endpoint. Disk: ~25 GB for images and data to start. RAM: 32 GB minimum
(Kinetica + docling + relex), more for larger data; less with an existing Kinetica.
x86_64; on ARM everything works except the knowledge-graph encoder (relex has no ARM
image yet).

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The stack. |
| `host-network.yml` | Host-networking override (see above). |
| `setup.sh` | Generates `.env`, checks the models (and an existing Kinetica), brings it up. |
| `smoke.sh` | Acceptance test, non-zero exit on failure. |
| `kinetica-init.sh` | Bundled Kinetica first-boot config (external auth + admin). |
| `start_auth.sh` | OIDC provider entry point. |
| `.env.example` | Config template. `TB_TAG` pins the release. |

## Status

Updated 2026-11-02 for the bearer-key endpoint (the header proxy is gone). Not yet
proven end to end on a box: run `./smoke.sh`. Host networking is untested on AWS.
