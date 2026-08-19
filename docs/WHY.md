# Why every flag is what it is

This is the part that took weeks to figure out. All numbers were measured on an
RTX 4070 Ti SUPER (16 376 MiB), driver 595.84, llama.cpp `169e4a7f` (2026-08-18),
headless (no desktop on the GPU).

## The VRAM budget

| What | Cost | Notes |
|---|---|---|
| Model weights (3.7 bpw GGUF) | ~12.2 GiB | 27B params; the 48 DeltaNet layers are **never quantized** by llama.cpp's KV machinery |
| KV cache, 145 408 tokens | ~2.2 GiB | K `q8_0` / V `q4_0`, **shared** between slots (`--kv-unified`) |
| DeltaNet recurrent state | ~250 MiB **per slot** | not shareable — this is what caps the slot count |
| Compute buffers + CUDA overhead | ~1 GiB | |
| **Total at `-c 145408 --parallel 2`** | **15 732 MiB** | 215 MiB headroom on 16 376 |

Things that do NOT fit, and what they would cost:
- **MTP (multi-token prediction)**: ~750 MiB. Solo-slot + MTP at 80k context is an
  alternative config worth ~75 t/s if you prefer speed over context.
- **Vision (mmproj)**: several GiB. Text-only keeps the model 100 % in VRAM.
- **4 slots**: +500 MiB of DeltaNet state → context would cap at ~112k.

## The flags

- `--fit off` — llama.cpp's auto-fit re-plans allocations and **undoes manual
  sizing** (it broke this exact layout when we deployed Gemma 4 the same way).
  With a hand-tuned budget, auto anything is the enemy.
- `-fa on -ctk q8_0 -ctv q4_0` — flash-attention with quantized KV. Keys degrade
  noticeably below q8_0; Values tolerate q4_0. This combination needs CUDA kernels
  that upstream's prebuilt binaries don't ship — hence our own build with
  `GGML_CUDA_FA_ALL_QUANTS=ON` (this is the reason this repo publishes binaries).
- `--kv-unified` — one 142k pool shared by both slots instead of 71k each. Two
  concurrent requests share it gracefully; a single request can use all of it.
- `--no-context-shift` — **mandatory**: context shifting is incompatible with the
  model's recurrent DeltaNet layers. Without this flag the server will corrupt
  long conversations instead of refusing them.
- `--parallel 2` — the sweet spot: a second slot costs one DeltaNet state
  (~250 MiB) and enables a second user/agent without halving anyone's context.
- `--chat-template-file` — ships a fixed template (upstream's has issues with
  tool-call parsing); `reasoning_effort` is exposed as an install-time knob.
- Sampling `--temp 1.0 --top-p 0.95 --top-k 20` — the model card's recommended
  values. Resist the urge to "make it deterministic" with temp 0: this family
  degrades badly.

## Desktop vs headless

The 215 MiB headroom assumes **nothing else uses the GPU**. A desktop session
(Xorg/Wayland + compositor) typically takes 300–800 MiB, which does not fit.
The installer detects this (VRAM in use, `graphical.target`) and falls back to
`CTX_DESKTOP=92160` — computed from the measured KV cost (~15 MiB per 1k tokens),
leaving ~800 MiB for the desktop. This profile is an estimate pending validation;
measurements welcome (open an issue with `nvidia-smi` output).

## Measured performance

| Situation | Speed |
|---|---|
| Generation, empty context | ~45 t/s |
| Generation at 21k context | ~40 t/s |
| Alternative: solo slot + MTP at 80k ctx | ~75 t/s |

## Reproducibility

- llama.cpp pinned by commit, built once in CI, checksum-verified at install.
- Model pinned by Hugging Face **snapshot revision** + SHA256 (a repo owner
  force-pushing new weights cannot silently change what you run).
- CUDA runtime statically linked into the binary: host needs the driver, nothing else.
- The only unpinnable variables — driver and kernel — are gated at preflight.
