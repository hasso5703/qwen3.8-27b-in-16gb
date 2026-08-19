# qwen3.8-27b-in-16gb

**Qwen3.8-27B · 142k context · one 16 GB GPU · one command.**
*(Le setup IA local du pauvre.)*

A 27B coding model with 142 000 tokens of context, running entirely in the VRAM
of a single consumer GPU (RTX 4070 Ti SUPER class), served OpenAI- and
Anthropic-compatible, started at boot by systemd. Every byte pinned and
checksum-verified: the same llama.cpp commit, the same GGUF, the same flags
that were measured to fit with 215 MiB to spare.

```bash
curl -fsSL https://raw.githubusercontent.com/__GH_OWNER__/qwen3.8-27b-in-16gb/main/install.sh | bash
```

That's it. ~12 GiB of downloads later you have:

| | |
|---|---|
| Endpoint | `http://127.0.0.1:8001/v1` (OpenAI) + `/v1/messages` (Anthropic) + web UI |
| Service | `qwen3.8-27b.service` — starts at boot, restarts on failure |
| Claude Code | `claude-qwen` wrapper — your agent, your GPU, zero API bill |
| Context | 145 408 tokens headless, 92 160 with a desktop (auto-detected), shared across 2 slots |
| Speed | ~45 t/s (empty) / ~40 t/s at 21k context |

## Requirements

- Linux x86_64 with systemd
- NVIDIA GPU with 16 GB VRAM (RTX 4070 Ti SUPER, 4080, 5070 Ti, 5080…)
- NVIDIA driver ≥ 550 (validated on 595.x) — **no CUDA toolkit needed**, the
  runtime is statically linked into the binary
- ~14 GiB of disk

RTX 20xx/30xx/40xx/50xx are covered by the prebuilt binary (sm 75/86/89/120).

## Read the interesting part

Everything hard-won lives in **[docs/WHY.md](docs/WHY.md)**: the MiB-level VRAM
budget, why Keys are q8_0 but Values q4_0, why `--fit off` and
`--no-context-shift` are non-negotiable, what MTP/vision/4-slots would cost,
and why this repo has to ship its own llama.cpp build
(`GGML_CUDA_FA_ALL_QUANTS` is not in upstream's prebuilts).

## Configuration

Environment variables, set before running the installer (re-running reconfigures):

| Var | Default | |
|---|---|---|
| `PORT` | `8001` | listen port |
| `HOST` | `127.0.0.1` | set `0.0.0.0` to expose on your network — **your** decision, off by default |
| `CTX` | auto | context size; auto picks headless (145408) or desktop (92160) profile |
| `PARALLEL` | `2` | request slots (context is shared, each slot costs ~250 MiB) |
| `REASONING` | `medium` | `low` / `medium` / `high` reasoning effort |
| `NO_SERVICE` | – | set `1` to skip systemd and print the manual run command |

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/__GH_OWNER__/qwen3.8-27b-in-16gb/main/uninstall.sh | bash
```

Removes the service and binaries; add `PURGE=1` to also delete the 12 GiB model.

## Security defaults

The server binds to `127.0.0.1` and the API is unauthenticated (llama.cpp
serves whoever can reach the port). If you set `HOST=0.0.0.0`, put an API key
(`--api-key`), a reverse proxy, or a VPN (Tailscale works great) in front —
your GPU will otherwise happily serve your whole network.

## Credits

- [llama.cpp](https://github.com/ggml-org/llama.cpp) does all the actual work
- [empero-ai/Qwen3.8-27B-Ridge](https://huggingface.co/empero-ai/Qwen3.8-27B-Ridge-GGUF) for the model and quant
- Measured, broken, and re-measured on one very dedicated 4070 Ti SUPER in Moselle, France
