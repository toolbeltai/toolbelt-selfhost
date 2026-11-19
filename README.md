# Self-hosting Toolbelt

Run the whole Toolbelt stack on **your own hardware**, in one command — the UI, the agent (MCP) endpoint, the data plane, document parsing, and a knowledge graph.

Pick the profile that matches your box. The only real difference is **where the language model runs.**

| | **[x86-gpu](x86-gpu/)** | **[arm64-gpu](arm64-gpu/)** | **[light](light/)** | **[cpu](cpu/)** |
|---|---|---|---|---|
| **Hardware** | x86 box + NVIDIA GPU | ARM64 box + NVIDIA GPU | any CPU box, no GPU | any CPU box, no GPU |
| **The model** | on the box, on the GPU | on the box, on the GPU | **hosted** — Toolbelt-hosted inference (API key) | **off the box** — any OpenAI-compatible endpoint |
| **Everything else** | on the box | on the box | on the box | on the box |
| **Install** | Docker Compose | Docker Compose | Docker Compose | Helm (Kubernetes) |
| **Examples** | on-prem NVIDIA server; AWS `g5`/`g6`, GCP/Azure GPU VMs | NVIDIA GB10 / DGX Spark, GH200, AWS Graviton + G5g | proofs of concept; any server or cloud VM | any server; model via your vLLM, Nebius, OpenAI, … |
| **Status** | ✅ proven end to end (A10G, with the earlier qwen2.5 7B default); Windows 11 / WSL2: not yet proven end to end | ✅ proven end to end (GB10) | ✅ proven end to end (CPU VM, hosted models) | reference (Helm) |

All four give the same Toolbelt.

## Start here — x86-gpu (the common case)

An x86 server or cloud instance with an NVIDIA GPU:

```sh
git clone https://github.com/toolbeltai/toolbelt-selfhost
cd toolbelt-selfhost/x86-gpu
./setup.sh          # writes config, checks GPU access, warms the model, brings it up
./smoke.sh          # prove it end to end: services, login, data, docling, encoder, embeddings, agent
```

Then open `http://<HOST_IP>:3080` (admin / Admin123!). Full walkthrough: **[x86-gpu/README.md](x86-gpu/README.md)**.

## Upgrading

```sh
git pull
docker compose pull   # in your profile's folder: fetch the newer images
./setup.sh            # keeps your .env and data, runs migrations, reconciles
```

`TB_TAG` in `.env` picks the release. `x86-gpu` and `light` pin a version (v0.2.96,
in their `.env.example`), so an install is reproducible and works offline; `arm64-gpu`
defaults to `stable` (the latest release), which `docker compose pull` refreshes.
`setup.sh` never rewrites your `.env`, so change `TB_TAG` there to move to a newer
release, then `docker compose pull` and `./setup.sh` ([light/README.md](light/README.md#versions-and-upgrading)).

Kinetica now runs with a memory cap (`KINETICA_MEM_LIMIT`; defaults 10g x86-gpu,
16g light, 32g arm64-gpu) and a pinned build. A `.env` from before keeps
working with those defaults; if your Kinetica holds a lot of data, set
`KINETICA_MEM_LIMIT` in `.env` to about 40% of the machine's RAM before
upgrading ([sizing rule](x86-gpu/README.md#memory-kinetica)). Rebooting with
the stack running is safe: Docker stops Kinetica cleanly and starts everything
again afterwards. Don't `docker compose stop` before a reboot; stopped
containers stay stopped ([details](x86-gpu/README.md#stopping-and-rebooting)).

Always upgrade with `setup.sh`, not a bare `docker compose up`: it also runs
one-time data moves. **Installs from before 2026-10-16:** the control-plane
database was stored in an unnamed Docker volume (a Postgres 18 path mismatch),
so `docker compose down` lost it. `setup.sh` moves it into the `cp-db-data`
volume on the next run; after that, `down` and `up` keep your data.

Upgraded with a bare `docker compose up` and now see an empty app? Your data
is still there, in an unnamed volume. `lib/recover-cp-db.sh` lists the
candidates; `lib/recover-cp-db.sh <volume> <profile>` moves the one you pick
back into place.

Other profiles:

- **ARM64 + GPU** (GB10 / DGX Spark, GH200, Graviton + G5g) → **[arm64-gpu/README.md](arm64-gpu/README.md)**
- **No GPU, hosted models** (fastest for a proof of concept) → **[light/README.md](light/README.md)**
- **No GPU, your own model endpoint, on Kubernetes** → **[cpu/README.md](cpu/README.md)**
