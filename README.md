# Self-hosting Toolbelt

Run the whole Toolbelt stack on **your own hardware**, in one command — the UI, the agent (MCP) endpoint, the data plane, document parsing, and a knowledge graph.

Pick the profile that matches your box. The only real difference is **where the language model runs.**

| | **[x86-gpu](x86-gpu/)** | **[arm64-gpu](arm64-gpu/)** | **[cpu](cpu/)** |
|---|---|---|---|
| **Hardware** | x86 box + NVIDIA GPU | ARM64 box + NVIDIA GPU | any CPU box, no GPU |
| **The model** | on the box, on the GPU | on the box, on the GPU | **off the box** — any OpenAI-compatible endpoint |
| **Everything else** | on the box | on the box | on the box |
| **Examples** | on-prem NVIDIA server; AWS `g5`/`g6`, GCP/Azure GPU VMs | NVIDIA GB10 / DGX Spark, GH200, AWS Graviton + G5g | any server; model via your vLLM, Nebius, OpenAI, … |
| **Status** | ✅ proven end to end (A10G) | ✅ proven end to end (GB10) | reference (Helm) |

All three give the same Toolbelt.

## Start here — x86-gpu (the common case)

An x86 server or cloud instance with an NVIDIA GPU:

```sh
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/x86-gpu
./setup.sh          # writes config, checks GPU access, warms the model, brings it up
./smoke.sh          # prove it end to end: services, login, data, docling, encoder, embeddings, agent
```

Then open `http://<HOST_IP>:3080` (admin / Admin123!). Full walkthrough: **[x86-gpu/README.md](x86-gpu/README.md)**.

Other profiles:

- **ARM64 + GPU** (GB10 / DGX Spark, GH200, Graviton + G5g) → **[arm64-gpu/README.md](arm64-gpu/README.md)**
- **No GPU** (the model runs on an external endpoint) → **[cpu/README.md](cpu/README.md)**
