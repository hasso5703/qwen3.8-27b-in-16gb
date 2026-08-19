# qwen3.8-27b-in-16gb

**Qwen3.8-27B · 142k context · one 16 GB GPU · one command.**
*(Le setup IA local du pauvre.)*

A 27B coding model with up to 145 408 tokens of context, running entirely in
the VRAM of a single consumer GPU (RTX 4070 Ti SUPER class), served OpenAI-
and Anthropic-compatible, started at boot by systemd. Every byte pinned and
checksum-verified: the same llama.cpp commit, the same GGUF, the same flags
that were measured to fit with 215 MiB to spare.

Sibling project: [dgx-spark-qwen38](https://github.com/hasso5703/dgx-spark-qwen38)
(same model on DGX Spark, SGLang + NVFP4).

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/hasso5703/qwen3.8-27b-in-16gb/main/install.sh | bash
```

That's it. ~12 GiB of downloads later you have:

| | |
|---|---|
| Endpoint | `http://127.0.0.1:8001/v1` (OpenAI) + `/v1/messages` (Anthropic) + web UI |
| Service | `qwen3.8-27b.service` — starts at boot, restarts on failure |
| Claude Code | `claude-qwen` — your agent on your GPU, correct context limit and timeouts pre-set |
| Context | 145 408 tokens headless / 92 160 with a desktop (auto-detected), shared across 2 slots |
| Speed | ~45 tok/s (empty) / ~40 tok/s at 21k context |

Prefer no systemd and no sudo? `./install.sh --no-service` prepares everything
and gives you a foreground `run.sh`. Re-running the installer is always safe:
completed steps are skipped, config converges.

## Requirements

- Linux x86_64 with systemd (WSL2: works, not validated)
- NVIDIA GPU with **16 GB** VRAM — RTX 4070 Ti SUPER, 4080 (Super), 5070 Ti, 5080…
  (prebuilt kernels for compute capability 7.5 / 8.6 / 8.9 / 12.0)
- NVIDIA driver ≥ 525.60.13 — any CUDA 12-capable driver (Ubuntu 22.04's default
  535 works; validated on 595.x) — **no CUDA toolkit needed**:
  the CUDA runtime is statically linked into the binary
- ~14 GiB of free disk

More than 16 GB? You want a bigger quant, not this repo. Less? It will not
fit — the sizing has 215 MiB of slack, see below.

## Read the interesting part

Everything hard-won lives in **[docs/WHY.md](docs/WHY.md)**: the MiB-level
VRAM budget, why Keys are q8_0 but Values q4_0, why `--fit off` and
`--no-context-shift` are non-negotiable, what MTP/vision/4-slots would cost,
and why this repo ships its own llama.cpp build
(`GGML_CUDA_FA_ALL_QUANTS` is not in upstream's prebuilts).

## Configuration

Env vars, set before running the installer. Choices are saved and re-used on
re-runs (`~/.local/share/qwen3.8-27b-in-16gb/config.env`); explicit env wins.

| Var | Default | |
|---|---|---|
| `PORT` | `8001` | listen port |
| `HOST` | `127.0.0.1` | `0.0.0.0` exposes to your network **and auto-enables a generated API key** |
| `CTX` | auto | context size; auto picks headless (145408) or desktop (92160) |
| `PARALLEL` | `2` | request slots — context is shared, each slot costs ~250 MiB |
| `REASONING` | `medium` | `low` / `medium` / `high` |
| `DATA_DIR` | `~/.local/share/qwen3.8-27b-in-16gb` | binary + model location |

Flags: `--no-service` (no systemd/sudo, foreground `run.sh`), `--no-start`
(install + enable, start later), `--help`.

## Operations

```bash
systemctl status qwen3.8-27b        # is it up?
journalctl -u qwen3.8-27b -f        # live logs
sudo systemctl restart qwen3.8-27b  # after changing config.env, re-run install.sh instead
./bench.sh                          # measure your tok/s
nvidia-smi                          # VRAM reality check
```

## Troubleshooting

**Client says "no response" / truncated output on long tasks.** A 16 GB GPU
thinks before it speaks; some clients' watchdogs give up first. `claude-qwen`
already sets `API_TIMEOUT_MS`, `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS` and
`CLAUDE_STREAM_IDLE_TIMEOUT_MS`. For other clients, raise their request/idle
timeouts (VS Code Copilot currently has no such knob — known limitation).

**Answers cut mid-sentence (`finish_reason: "length"`).** The server has NO
output cap (`--n-predict` defaults to unlimited) — the limit is the
`max_tokens` YOUR CLIENT sends with each request, and reasoning tokens count
against it. `claude-qwen` sets `CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000`
(undocumented but verified by request capture on Claude Code 2.1.235 — the
default it sends otherwise is 32000). For your own clients, send a generous
`max_tokens` (the Anthropic `/v1/messages` API makes the field mandatory — a
small hardcoded value there is the usual culprit).

**HTTP 400 mid-session in Claude Code.** The context is 145k/92k, not the 200k
Claude Code assumes for unknown models. `claude-qwen` sets
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` so auto-compact fires in time; if you bypass
the wrapper, set it yourself, and `/compact` early on giant codebases.

**Service fails at startup with CUDA OOM.** Something else is using VRAM
(desktop session, another model server, a browser with WebGPU). Close it, or
re-run the installer with a lower `CTX=` — the math for choosing one is in
[docs/WHY.md](docs/WHY.md). The installer prints the measured headroom at the
end of every install.

**`nvidia-smi` errors after a driver update.** Reboot — kernel module and
userspace library are out of sync.

**Fedora/SELinux: service dies with "Permission denied".**
`sudo chcon -t bin_t ~/.local/share/qwen3.8-27b-in-16gb/bin/llama-server`
(the installer warns about this when SELinux is enforcing).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/hasso5703/qwen3.8-27b-in-16gb/main/uninstall.sh | bash
```

Removes service, binaries and wrapper; add `PURGE=1` to also delete the 12 GiB model.

## Security defaults

Binds to `127.0.0.1` with no auth (whoever can reach the port can use the
GPU). Setting `HOST=0.0.0.0` automatically generates and enforces an API key
(`Bearer`), because an open LLM on a LAN is a gift you didn't mean to give.
For remote access prefer a VPN — Tailscale works great.

## Credits

- [llama.cpp](https://github.com/ggml-org/llama.cpp) does all the actual work
- [empero-ai/Qwen3.8-27B-Ridge](https://huggingface.co/empero-ai/Qwen3.8-27B-Ridge-GGUF) for the model and quant
- Field lessons from the [dgx-spark-qwen38](https://github.com/hasso5703/dgx-spark-qwen38) users and the
  [NVIDIA forum thread](https://forums.developer.nvidia.com/t/380257)
- Measured, broken, and re-measured on one very dedicated 4070 Ti SUPER in Moselle, France
