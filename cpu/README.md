# Toolbelt on a CPU box — model runs elsewhere

Everything Toolbelt runs on your box **except the language model**, which you
point at any OpenAI-compatible endpoint. No GPU required. Use this when you'd
rather not put a GPU in the box — reuse a GPU server you already run, or a hosted
API (your own vLLM cluster, Nebius, OpenAI, …).

The **only** thing that leaves the box is the LLM + embedding calls. Documents,
parsing, the knowledge graph, and all your data stay put.

## What runs where

**On the box** (CPU): atlas (UI + API), mcp (agent), auth, Postgres, the data
plane (Kinetica CPU build), document parsing (docling, CPU), and knowledge-graph
extraction (gliner, CPU — `device: cpu`, ~2s/doc).

**Off the box:** the LLM and the embedding model — any OpenAI-compatible URL. The
two can even live at different URLs.

## Install (Kubernetes / Helm)

This profile targets a Kubernetes cluster (a single-box k3s, or your existing
k8s). Kinetica is its own Helm release; Toolbelt is a second.

```sh
# 1. Edit every <PLACEHOLDER> in values.yaml (hostname, Kinetica service, storage).
# 2. Point at your model endpoint — either fill llm.default / llm.embedding now,
#    or leave them blank and set them in the Atlas Models page after first login.
helm install toolbelt oci://ghcr.io/toolbeltai/toolbelt/toolbelt \
  -n toolbelt --create-namespace -f values.yaml
```

The model config is the one part that matters — in [`values.yaml`](values.yaml):

```yaml
llm:
  default:   { name: "<chat-model>",  apiUrl: "<https://your-endpoint/v1>", apiKey: "<key>", provider: "OpenAI", source: "external" }
  embedding: { name: "<embed-model>", apiUrl: "<https://your-endpoint/v1>", apiKey: "<key>", provider: "OpenAI", source: "external", dimension: 1024 }
```

The embedding **`dimension` must match your model** (e.g. bge-m3 = 1024,
text-embedding-3-small = 1536) or ingestion fails.

## Status

Reference — the values file comes from a real on-site install. Verify against
your own cluster before production. For a single box where you'd rather run the
model locally (no external endpoint), use **[../arm64-gpu](../arm64-gpu/)** instead.
