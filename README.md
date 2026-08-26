# Self-hosting Toolbelt

Reference deployments for running the **whole Toolbelt stack on your own hardware** — one command, nothing external required. The UI, the agent (MCP) endpoint, the data plane, document parsing, a knowledge graph, and a language model, all on your box.

## Profiles

| Profile | Hardware | Model | Status |
|---|---|---|---|
| **[arm64-gpu](arm64-gpu/)** | One ARM64 box with an NVIDIA GPU — e.g. **NVIDIA GB10 / DGX Spark**, **AWS Graviton + G5g**, GH200 | runs **locally on the GPU** | ✅ Ready |
| cpu | One x86/ARM CPU box | remote OpenAI-compatible endpoint | soon |

Every profile ships a **`smoke.sh`** acceptance test that proves the install end to end (services healthy → data round-trip → the model answering → the agent surface), so you can verify any box in one command.

## Start here

```sh
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/arm64-gpu
./setup.sh          # writes config, enables the GPU, warms the model, brings it up
./smoke.sh          # prove it works
```

See **[arm64-gpu/README.md](arm64-gpu/README.md)** for the full walkthrough.
