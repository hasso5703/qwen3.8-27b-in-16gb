#!/usr/bin/env bash
# qwen3.8-27b-in-16gb — one-command installer
#
#   curl -fsSL https://raw.githubusercontent.com/hasso5703/qwen3.8-27b-in-16gb/main/install.sh | bash
#
# Qwen3.8-27B with up to 145k context on a single 16 GB NVIDIA GPU: pinned
# llama.cpp build (checksum-verified), pinned GGUF (checksum-verified),
# systemd service, Claude Code wrapper. Idempotent: safe to re-run at any
# time — completed steps are skipped, config converges.
#
# Flags:  --no-service   no systemd, no sudo: prepare everything + write run.sh
#         --no-start     install + enable at boot, but don't start now
#         -h | --help    this text, plus env overrides
set -euo pipefail
export LC_ALL=C   # never parse localized command output (dgx-spark-qwen38 issue #3)
trap 'printf "\n\033[1;31mInstall failed at line %s (command: %s).\033[0m\nRe-running install.sh is safe — completed steps are skipped.\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ── Repo + fixed paths ────────────────────────────────────────────────────────
GH_REPO="${QWEN16_REPO:-hasso5703/qwen3.8-27b-in-16gb}"
RAW_BASE="https://raw.githubusercontent.com/${GH_REPO}/main"
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/qwen3.8-27b-in-16gb}"
SERVICE_NAME="qwen3.8-27b"

# ── Flags ─────────────────────────────────────────────────────────────────────
NO_SERVICE_FLAG=0; NO_START=0
for arg in "$@"; do
  case "$arg" in
    --no-service) NO_SERVICE_FLAG=1 ;;
    --no-start)   NO_START=1 ;;
    -h|--help)
      cat <<'HLP'
Usage: ./install.sh [--no-service] [--no-start]

  --no-service   no systemd, no sudo: download + verify everything, then run
                 in the foreground anytime with ~/.local/share/qwen3.8-27b-in-16gb/run.sh
  --no-start     install and enable at boot, but don't start the service now

Env overrides (defaults are the validated, pinned configuration):
  PORT=8001            listen port
  HOST=127.0.0.1       bind address; 0.0.0.0 exposes to your network AND
                       auto-enables an API key (generated, printed at the end)
  CTX=<tokens>         context size (default: auto — 145408 headless / 92160 desktop)
  PARALLEL=2           request slots (context is SHARED between slots)
  REASONING=medium     low | medium | high
  DATA_DIR=<path>      where binary+model live (needs ~14 GiB)
HLP
      exit 0 ;;
    *) printf 'Unknown flag: %s (see --help)\n' "$arg" >&2; exit 1 ;;
  esac
done
[[ "$NO_SERVICE_FLAG" -eq 1 && "$NO_START" -eq 1 ]] && { echo "--no-start controls the systemd service; with --no-service there is none (drop one flag)" >&2; exit 1; }

step() { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Install it (usually: sudo apt install $2) and re-run."; }

# ── Converging config: explicit env wins > saved config > defaults ───────────
U_PORT="${PORT:-}"; U_HOST="${HOST:-}"; U_CTX="${CTX:-}"; U_PAR="${PARALLEL:-}"; U_REAS="${REASONING:-}"
[[ -f "$DATA_DIR/config.env" ]] && source "$DATA_DIR/config.env"
PORT="${U_PORT:-${PORT:-8001}}"
HOST="${U_HOST:-${HOST:-127.0.0.1}}"
CTX="${U_CTX:-${CTX:-}}"
PARALLEL="${U_PAR:-${PARALLEL:-2}}"
REASONING="${U_REAS:-${REASONING:-medium}}"
case "$REASONING" in low|medium|high) ;; minimal) REASONING=low ;; *) die "REASONING must be low, medium or high (got '$REASONING')." ;; esac

# ── Pinned versions: local checkout wins, else fetch from the repo ───────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/versions.env" ]]; then
  source "$SCRIPT_DIR/versions.env"; LOCAL_CHECKOUT="$SCRIPT_DIR"
else
  command -v curl >/dev/null 2>&1 || die "'curl' is required. Install it and re-run."
  LOCAL_CHECKOUT=""
  eval "$(curl -fsSL "$RAW_BASE/versions.env")" || die "cannot fetch versions.env from github.com/$GH_REPO — no internet, or the repo moved."
fi
: "${MODEL_SHA256:?versions.env did not load correctly}"

step "1/7 Preflight checks"
[[ "$(id -u)" -eq 0 ]] && die "run as a normal user, not root (sudo is used only for the systemd unit)."
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || die "Linux x86_64 only (got: $(uname -s)/$(uname -m)). For other platforms, build llama.cpp yourself — see docs/WHY.md."
grep -qi microsoft /proc/version 2>/dev/null && warn "WSL2 detected: CUDA works there, but this setup is only validated on bare Linux (and WSL needs systemd=true in /etc/wsl.conf for the service)."
need curl curl; need tar tar; need sha256sum coreutils; need awk gawk
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found — install the NVIDIA proprietary driver (>= ${MIN_DRIVER_MAJOR}) first. On Ubuntu: sudo ubuntu-drivers install"

DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)" \
  || die "nvidia-smi exists but fails — usually a driver/library mismatch after an update. Fix: reboot. If it persists: reinstall the driver."
DRIVER_MAJOR="${DRIVER%%.*}"
(( DRIVER_MAJOR >= MIN_DRIVER_MAJOR )) || die "NVIDIA driver $DRIVER is too old (need >= ${MIN_DRIVER_MAJOR}). On Ubuntu: sudo ubuntu-drivers install --gpgpu"
(( DRIVER_MAJOR >= RECOMMENDED_DRIVER_MAJOR )) || warn "driver $DRIVER works but this config is validated on >= ${RECOMMENDED_DRIVER_MAJOR}.x"

# Pick the first 16 GB-class GPU (multi-GPU boxes: we pin the service to it).
# CSV fields are comma-separated; GPU names contain spaces — split on commas ONLY.
GPU_INDEX=""; GPU_NAME=""; VRAM_MB=0; COMPUTE_CAP=""
while IFS=',' read -r idx name mem cap; do
  idx="${idx//[[:space:]]/}"; mem="${mem//[[:space:]]/}"; cap="${cap//[[:space:]]/}"
  name="$(echo "$name" | sed 's/^ *//; s/ *$//')"
  if (( mem >= 15000 && mem <= 17408 )); then GPU_INDEX="$idx"; GPU_NAME="$name"; VRAM_MB="$mem"; COMPUTE_CAP="$cap"; break; fi
  FIRST_NAME="${FIRST_NAME:-$name}"; FIRST_MEM="${FIRST_MEM:-$mem}"
done < <(nvidia-smi --query-gpu=index,name,memory.total,compute_cap --format=csv,noheader,nounits)
if [[ -z "$GPU_INDEX" ]]; then
  die "no 16 GB-class GPU found (first GPU: ${FIRST_NAME:-?}, ${FIRST_MEM:-?} MiB). This repo is sized to the MiB for 16 GB. More VRAM? You want a bigger quant — see the README. Less? It will not fit, no flag can change that."
fi
echo "GPU $GPU_INDEX: $GPU_NAME (${VRAM_MB} MiB, compute capability $COMPUTE_CAP, driver $DRIVER)"

# The prebuilt binary only contains kernels for these architectures.
case "$COMPUTE_CAP" in
  7.5|8.6|8.9|12.0) ;;
  *) die "compute capability $COMPUTE_CAP is not in the prebuilt binary (built for 7.5/8.6/8.9/12.0 = RTX 20xx/30xx/40xx/50xx). Build llama.cpp locally with GGML_CUDA_FA_ALL_QUANTS=ON instead — see docs/WHY.md — then re-run with the binary in $DATA_DIR/bin/." ;;
esac

# Desktop vs headless: a compositor on this GPU eats VRAM budgeted for KV cache.
VRAM_USED_MB="$(nvidia-smi -i "$GPU_INDEX" --query-gpu=memory.used --format=csv,noheader,nounits)"
if [[ -z "$CTX" ]]; then
  if (( VRAM_USED_MB > 300 )) || [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]]; then
    CTX="$CTX_DESKTOP"
    warn "a desktop session uses this GPU (${VRAM_USED_MB} MiB in use) → desktop profile: ${CTX} tokens of context."
    warn "headless machines get ${CTX_HEADLESS}. Override with CTX=... if you know your VRAM budget (docs/WHY.md)."
  else
    CTX="$CTX_HEADLESS"
    echo "headless GPU → full context profile: ${CTX} tokens"
  fi
fi

if [[ ! -f "$DATA_DIR/$MODEL_FILE.verified" ]]; then
  mkdir -p "$DATA_DIR"
  FREE_KB="$(df -Pk "$DATA_DIR" | awk 'NR==2{print $4}')"
  NEED_KB=$(( (MODEL_SIZE_BYTES / 1024) + 1048576 ))
  (( FREE_KB > NEED_KB )) || die "not enough disk space in $DATA_DIR: need ~$(( NEED_KB / 1048576 )) GiB, have $(( FREE_KB / 1048576 )) GiB. Free space or set DATA_DIR=/other/disk."
fi

if [[ "$NO_SERVICE_FLAG" -eq 0 ]]; then
  command -v systemctl >/dev/null 2>&1 || die "systemd not found — re-run with --no-service for a foreground setup."
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}\$"; then
    if systemctl is-active -q "$SERVICE_NAME" 2>/dev/null; then
      echo "note: ${SERVICE_NAME} already runs on :${PORT} — re-installing over it (config converges, service restarts at the end)."
    else
      die "port ${PORT} is used by another program (see: ss -tlnp | grep :${PORT}). Free it, or re-run with PORT=<other>."
    fi
  fi
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    warn "SELinux is enforcing: systemd may refuse to exec from \$HOME. If the service fails with 'Permission denied': sudo chcon -t bin_t '$DATA_DIR/bin/llama-server'"
  fi
fi
echo "preflight OK"

step "2/7 Pinned llama-server build (${LLAMACPP_SHORT}, CUDA runtime statically linked)"
mkdir -p "$DATA_DIR/bin" "$DATA_DIR/templates"
BIN_TGZ="llama-server-linux-x64-cuda-${LLAMACPP_SHORT}.tar.gz"
BIN_URL="https://github.com/${GH_REPO}/releases/download/${BINARY_RELEASE_TAG}/${BIN_TGZ}"
if [[ -x "$DATA_DIR/bin/llama-server" && -f "$DATA_DIR/bin/.commit-${LLAMACPP_SHORT}" ]]; then
  echo "already installed — skipping"
else
  curl -fL --retry 5 -o "$DATA_DIR/$BIN_TGZ" "$BIN_URL" \
    || die "binary download failed. Causes: no internet; GitHub outage; or release ${BINARY_RELEASE_TAG} missing on ${GH_REPO} (open an issue). Building locally always works — see docs/WHY.md."
  curl -fL --retry 5 -o "$DATA_DIR/$BIN_TGZ.sha256" "$BIN_URL.sha256"
  ( cd "$DATA_DIR" && sha256sum -c "$BIN_TGZ.sha256" >/dev/null ) || { rm -f "$DATA_DIR/$BIN_TGZ"; die "binary checksum MISMATCH — corrupted download or tampering. Deleted it; re-run to retry."; }
  tar -xzf "$DATA_DIR/$BIN_TGZ" -C "$DATA_DIR/bin"
  rm -f "$DATA_DIR/$BIN_TGZ" "$DATA_DIR/$BIN_TGZ.sha256"
  touch "$DATA_DIR/bin/.commit-${LLAMACPP_SHORT}"
  echo "verified and installed"
fi

step "3/7 Model (~12 GiB, one-time — resumes if interrupted)"
MODEL_PATH="$DATA_DIR/$MODEL_FILE"
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}/${MODEL_FILE}"
if [[ -f "$MODEL_PATH.verified" && -f "$MODEL_PATH" ]]; then
  echo "already downloaded and verified — skipping"
else
  [[ -n "${HF_HUB_OFFLINE:-}" ]] && warn "HF_HUB_OFFLINE is set — irrelevant here (we download directly), but known to break other tools' installs."
  curl -fL --retry 10 --retry-all-errors -C - -o "$MODEL_PATH.part" "$MODEL_URL" \
    || die "model download failed. Causes: no internet; Hugging Face outage or rate-limit (re-run: it resumes); disk full. URL: $MODEL_URL"
  echo "verifying SHA256 (takes a minute — this is the point of the repo)"
  if ! echo "$MODEL_SHA256  $MODEL_PATH.part" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$MODEL_PATH.part"
    die "model checksum MISMATCH — the partial file was corrupted. Deleted it; re-run to download again."
  fi
  mv "$MODEL_PATH.part" "$MODEL_PATH"
  touch "$MODEL_PATH.verified"
  echo "verified: $MODEL_SHA256"
fi

step "4/7 Chat template + saved config"
TEMPLATE_PATH="$DATA_DIR/templates/qwen3.8-ridge.jinja"
if [[ -n "$LOCAL_CHECKOUT" ]]; then
  cp "$LOCAL_CHECKOUT/templates/qwen3.8-ridge.jinja" "$TEMPLATE_PATH"
else
  curl -fsSL -o "$TEMPLATE_PATH" "$RAW_BASE/templates/qwen3.8-ridge.jinja" || die "template download failed (no internet?)"
fi

# API key: mandatory when exposed beyond localhost, off for pure-local installs.
API_KEY_ARGS=(); API_KEY=""
if [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" ]]; then
  if [[ ! -s "$DATA_DIR/api.key" ]]; then
    head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$DATA_DIR/api.key"; chmod 600 "$DATA_DIR/api.key"
  fi
  API_KEY="$(cat "$DATA_DIR/api.key")"
  API_KEY_ARGS=(--api-key "$API_KEY")
  warn "HOST=$HOST exposes the server beyond this machine → API key enforced (kept in $DATA_DIR/api.key, mode 600)."
fi

cat > "$DATA_DIR/config.env" <<EOF
# Saved by install.sh — re-running converges to this unless overridden by env.
PORT=$PORT
HOST=$HOST
CTX=$CTX
PARALLEL=$PARALLEL
REASONING=$REASONING
EOF

# Flag rationale: docs/WHY.md. The short version:
#   --fit off            manual VRAM layout — auto-fit undoes the sizing
#   -ctk q8_0 -ctv q4_0  KV quant (Keys need q8, Values tolerate q4) — needs our FA_ALL_QUANTS build
#   --kv-unified         one context pool SHARED by all slots
#   --no-context-shift   mandatory with this model's recurrent DeltaNet layers
SERVER_CMD=("$DATA_DIR/bin/llama-server"
  -m "$MODEL_PATH" --alias "$MODEL_REPO"
  -ngl 99 --fit off -fa on
  -c "$CTX" -ctk q8_0 -ctv q4_0
  --parallel "$PARALLEL" --kv-unified --no-context-shift
  --jinja --chat-template-file "$TEMPLATE_PATH"
  --chat-template-kwargs "{\"reasoning_effort\":\"$REASONING\"}"
  --temp 1.0 --top-p 0.95 --top-k 20
  --host "$HOST" --port "$PORT" --metrics "${API_KEY_ARGS[@]}")

{ printf '#!/usr/bin/env bash\n# Foreground runner (Ctrl+C stops). Generated by install.sh — re-running regenerates.\nexport CUDA_VISIBLE_DEVICES=%s\nexec ' "$GPU_INDEX"; printf '%q ' "${SERVER_CMD[@]}"; echo; } > "$DATA_DIR/run.sh"
chmod +x "$DATA_DIR/run.sh"

step "5/7 Claude Code wrapper (~/.local/bin/claude-qwen)"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude-qwen" <<EOF
#!/bin/bash
# Claude Code on your local Qwen3.8-27B (${GH_REPO}) — generated by install.sh
export ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT}"
export ANTHROPIC_AUTH_TOKEN="${API_KEY:-local}"
export ANTHROPIC_API_KEY=""
export ANTHROPIC_MODEL="${MODEL_REPO}"
export ANTHROPIC_SMALL_FAST_MODEL="${MODEL_REPO}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${MODEL_REPO}"
export CLAUDE_CODE_SUBAGENT_MODEL="${MODEL_REPO}"
# Tell Claude Code the REAL context size so it compacts before overflowing (400s otherwise)
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=$(( CTX - 4096 ))
# A 16 GB GPU thinks before it speaks — don't let client watchdogs kill long turns
export API_TIMEOUT_MS=3600000
export CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=1800000
export CLAUDE_STREAM_IDLE_TIMEOUT_MS=1800000
exec claude "\$@"
EOF
chmod +x "$HOME/.local/bin/claude-qwen"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "\$HOME/.local/bin is not in your PATH — add it to use 'claude-qwen'." ;; esac

if [[ "$NO_SERVICE_FLAG" -eq 1 ]]; then
  printf '\n\033[1;32m✅ Prepared (no systemd, nothing needed sudo).\033[0m\n'
  echo "  Run in the foreground : $DATA_DIR/run.sh   (Ctrl+C stops; model loads in ~1-3 min)"
  echo "  Then                  : curl http://127.0.0.1:$PORT/v1/models   |   claude-qwen"
  exit 0
fi

step "6/7 systemd service '${SERVICE_NAME}' (the only step needing sudo)"
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=Qwen3.8-27B on a 16 GB GPU (llama.cpp ${LLAMACPP_SHORT}) — ${GH_REPO}
After=network-online.target nvidia-persistenced.service
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
Environment=CUDA_VISIBLE_DEVICES=${GPU_INDEX}
ExecStart=$(printf '%q ' "${SERVER_CMD[@]}")
Restart=on-failure
RestartSec=5
TimeoutStartSec=300
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
if [[ "$NO_START" -eq 1 ]]; then
  printf '\n\033[1;32m✅ Installed and enabled at boot (not started: --no-start).\033[0m\n'
  echo "  Start it with: sudo systemctl start $SERVICE_NAME"
  exit 0
fi
sudo systemctl restart "$SERVICE_NAME"

step "7/7 Starting (model load ≈ 1-3 min depending on disk)"
HEALTH_URL="http://127.0.0.1:${PORT}/health"
for i in $(seq 1 120); do
  curl -fsS -m 2 "$HEALTH_URL" >/dev/null 2>&1 && break
  if [[ "$(systemctl is-active "$SERVICE_NAME" || true)" == "failed" ]]; then
    journalctl -u "$SERVICE_NAME" --no-pager | tail -25
    die "service failed during startup — logs above. Most common on 16 GB: something else grabbed VRAM (close desktop apps / other AI servers, or lower CTX — see docs/WHY.md)."
  fi
  (( i % 20 == 0 )) && echo "  still loading... ($(( i * 3 ))s)"
  sleep 3
  (( i == 120 )) && die "server not healthy after 6 min. Watch: journalctl -u $SERVICE_NAME -f"
done
echo "health OK — running a real generation as smoke test"
AUTH_HDR=(); [[ -n "$API_KEY" ]] && AUTH_HDR=(-H "Authorization: Bearer $API_KEY")
SMOKE="$(curl -fsS -m 300 "http://127.0.0.1:${PORT}/v1/chat/completions" "${AUTH_HDR[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with exactly: READY"}],"max_tokens":600}' \
  | { command -v python3 >/dev/null && python3 -c 'import json,sys
try:
  m=json.load(sys.stdin)["choices"][0]["message"]
  print("OK" if (m.get("content") or m.get("reasoning_content") or "").strip() else "EMPTY")
except Exception as e: print(f"FAIL:{e}")' || grep -q '"content"' && echo OK || echo FAIL; })"
[[ "$SMOKE" == "OK" ]] || die "server is up but the smoke generation failed ($SMOKE). Check: journalctl -u $SERVICE_NAME -n 50"

VRAM_AFTER="$(nvidia-smi -i "$GPU_INDEX" --query-gpu=memory.used --format=csv,noheader,nounits)"
HEADROOM=$(( VRAM_MB - VRAM_AFTER ))
(( HEADROOM < 100 )) && warn "only ${HEADROOM} MiB of VRAM headroom — anything else touching the GPU can OOM the server. Consider a lower CTX."

printf '\n\033[1;32m✅ Installed, verified, running, and enabled at boot.\033[0m\n'
echo "  OpenAI API   : http://${HOST}:${PORT}/v1/chat/completions"
echo "  Anthropic API: http://${HOST}:${PORT}/v1/messages"
echo "  Web UI       : http://127.0.0.1:${PORT}"
[[ -n "$API_KEY" ]] && echo "  API key      : $DATA_DIR/api.key (Bearer auth is ENFORCED)"
echo "  Context      : ${CTX} tokens shared across ${PARALLEL} slots — VRAM used: ${VRAM_AFTER}/${VRAM_MB} MiB"
echo "  Claude Code  : claude-qwen"
echo "  Service      : systemctl status ${SERVICE_NAME}   |   journalctl -u ${SERVICE_NAME} -f"
echo "  Uninstall    : curl -fsSL ${RAW_BASE}/uninstall.sh | bash"
