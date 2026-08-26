# Self-hosting Toolbelt

Run the whole Toolbelt stack on **your own hardware**, in one command — the UI, the agent (MCP) endpoint, the data plane, document parsing, and a knowledge graph.

There are two setups. The difference is one thing: **where the AI model runs.**

| | **[arm64-gpu](arm64-gpu/)** | **[cpu](cpu/)** |
|---|---|---|
| **The model** | runs **on the box**, on the GPU | runs **elsewhere** — you point it at any OpenAI-compatible endpoint |
| **Everything else** | on the box | on the box |
| **Needs** | an ARM64 box with an NVIDIA GPU | any CPU box (no GPU) + a model endpoint |
| **Good for** | fully local & private — nothing leaves the box, works offline | lighter hardware; reuse a GPU server or a hosted API you already have |
| **Examples** | NVIDIA GB10 / DGX Spark, AWS Graviton + G5g, GH200 | any x86/ARM server; model via your vLLM cluster, Nebius, OpenAI, … |
| **Status** | ✅ Ready — proven end to end | Reference (Helm) |

Both give the same Toolbelt. The only question is whether the language model lives **on the box** (`arm64-gpu`) or **off the box** (`cpu`).

## Start here — arm64-gpu

```sh
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/arm64-gpu
./setup.sh          # writes config, enables the GPU, warms the model, brings it up
./smoke.sh          # prove it works — 15 end-to-end checks
```

Then open `http://<HOST_IP>:3080` (admin / Admin123!). Full walkthrough: **[arm64-gpu/README.md](arm64-gpu/README.md)**.

For the CPU / external-model path, see **[cpu/README.md](cpu/README.md)**.
