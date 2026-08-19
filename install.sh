#!/usr/bin/env bash
# qwen3.8-27b-in-16gb — one-command installer
#
#   curl -fsSL https://raw.githubusercontent.com/__GH_OWNER__/qwen3.8-27b-in-16gb/main/install.sh | bash
#
# Installs a pinned llama.cpp build + pinned Qwen3.8-27B-Ridge GGUF, sized to the
# millimeter for a single 16 GB NVIDIA GPU, and (optionally) a systemd service
# that starts it at boot. Everything downloaded is checksum-verified.
# Safe to re-run: every step is idempotent.
#
# Env overrides (all optional):
#   PORT=8001            listen port
#   HOST=127.0.0.1       bind address (0.0.0.0 exposes it to your network — your call)
#   CTX=<tokens>         context size (default: auto — headless vs desktop profile)
#   PARALLEL=2           concurrent request slots (context is SHARED between slots)
#   DATA_DIR=~/.local/share/qwen3.8-27b-in-16gb
#   NO_SERVICE=1         download + verify only, print the manual run command
#   REASONING=medium     reasoning_effort passed to the chat template (low|medium|high)
set -euo pipefail

# ------------------------------------------------------------------ config ---
GH_REPO="${QWEN16_REPO:-__GH_OWNER__/qwen3.8-27b-in-16gb}"
RAW_BASE="https://raw.githubusercontent.com/${GH_REPO}/main"
PORT="${PORT:-8001}"
HOST="${HOST:-127.0.0.1}"
PARALLEL="${PARALLEL:-2}"
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/qwen3.8-27b-in-16gb}"
SERVICE_NAME="qwen3.8-27b"
REASONING="${REASONING:-medium}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required. Install it and re-run."; }

# ------------------------------------------------- locate pinned versions ---
# Local checkout wins (git clone usage); otherwise fetch from the repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/versions.env" ]]; then
    # shellcheck source=versions.env
    source "$SCRIPT_DIR/versions.env"
    LOCAL_CHECKOUT="$SCRIPT_DIR"
else
    need curl
    LOCAL_CHECKOUT=""
    eval "$(curl -fsSL "$RAW_BASE/versions.env")" || die "cannot fetch versions.env from $GH_REPO"
fi
: "${MODEL_SHA256:?versions.env did not load}"

# -------------------------------------------------------------- preflight ---
log "Preflight checks"
[[ "$(id -u)" -eq 0 ]] && die "run as a normal user, not root (sudo is used only for the systemd unit)."
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || die "Linux x86_64 only (got $(uname -s)/$(uname -m))."
need curl; need tar
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found. Install the NVIDIA driver (>= ${MIN_DRIVER_MAJOR}) first."

DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
DRIVER_MAJOR="${DRIVER%%.*}"
(( DRIVER_MAJOR >= MIN_DRIVER_MAJOR )) || die "NVIDIA driver $DRIVER is too old (need >= ${MIN_DRIVER_MAJOR})."
(( DRIVER_MAJOR >= RECOMMENDED_DRIVER_MAJOR )) || warn "driver $DRIVER works but we validate on >= ${RECOMMENDED_DRIVER_MAJOR}.x"

VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
if   (( VRAM_MB < 15000 )); then die "this setup is sized for 16 GB GPUs; yours has ${VRAM_MB} MiB. It will not fit."
elif (( VRAM_MB > 17408 )); then warn "GPU has ${VRAM_MB} MiB (>16 GB): it will fit with room to spare — consider raising CTX."
fi

# Desktop vs headless: a compositor on the same GPU eats VRAM we budgeted for KV cache.
VRAM_USED_MB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
DEFAULT_TARGET="$(systemctl get-default 2>/dev/null || echo unknown)"
if [[ -z "${CTX:-}" ]]; then
    if (( VRAM_USED_MB > 300 )) || [[ "$DEFAULT_TARGET" == "graphical.target" ]]; then
        CTX="$CTX_DESKTOP"
        warn "desktop detected on the GPU (${VRAM_USED_MB} MiB in use, default target: ${DEFAULT_TARGET})"
        warn "using the desktop context profile: ${CTX} tokens. Headless would allow ${CTX_HEADLESS}. Override with CTX=..."
    else
        CTX="$CTX_HEADLESS"
        log "headless GPU detected — using the full context profile: ${CTX} tokens"
    fi
fi

FREE_KB="$(df -Pk "$(dirname "$DATA_DIR")" | awk 'NR==2{print $4}')"
NEED_KB=$(( (MODEL_SIZE_BYTES / 1024) + 1048576 ))
if [[ ! -f "$DATA_DIR/$MODEL_FILE.verified" ]]; then
    (( FREE_KB > NEED_KB )) || die "not enough disk space in $(dirname "$DATA_DIR") (need ~$(( NEED_KB / 1048576 )) GiB)."
fi

if [[ -z "${NO_SERVICE:-}" ]]; then
    command -v systemctl >/dev/null 2>&1 || die "systemd not found — re-run with NO_SERVICE=1 for a manual setup."
    if ! systemctl is-active -q "$SERVICE_NAME" 2>/dev/null; then
        ss -tln 2>/dev/null | grep -q ":${PORT} " && die "port ${PORT} is already in use. Set PORT=... and re-run."
    fi
fi

mkdir -p "$DATA_DIR/bin" "$DATA_DIR/templates"

# ------------------------------------------------------- llama.cpp binary ---
BIN_TGZ="llama-server-linux-x64-cuda-${LLAMACPP_SHORT}.tar.gz"
BIN_URL="https://github.com/${GH_REPO}/releases/download/${BINARY_RELEASE_TAG}/${BIN_TGZ}"
if [[ -x "$DATA_DIR/bin/llama-server" && -f "$DATA_DIR/bin/.commit-${LLAMACPP_SHORT}" ]]; then
    log "llama-server ${LLAMACPP_SHORT} already installed — skipping"
else
    log "Downloading pinned llama-server build (${LLAMACPP_SHORT}, CUDA runtime statically linked)"
    curl -fL --retry 5 -o "$DATA_DIR/$BIN_TGZ" "$BIN_URL"
    curl -fL --retry 5 -o "$DATA_DIR/$BIN_TGZ.sha256" "$BIN_URL.sha256"
    ( cd "$DATA_DIR" && sha256sum -c "$BIN_TGZ.sha256" >/dev/null ) || die "binary checksum mismatch — aborting."
    tar -xzf "$DATA_DIR/$BIN_TGZ" -C "$DATA_DIR/bin"
    rm -f "$DATA_DIR/$BIN_TGZ" "$DATA_DIR/$BIN_TGZ.sha256"
    touch "$DATA_DIR/bin/.commit-${LLAMACPP_SHORT}"
fi

# ------------------------------------------------------------------ model ---
MODEL_PATH="$DATA_DIR/$MODEL_FILE"
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}/${MODEL_FILE}"
if [[ -f "$MODEL_PATH.verified" && -f "$MODEL_PATH" ]]; then
    log "model already downloaded and verified — skipping ($(du -h "$MODEL_PATH" | cut -f1))"
else
    log "Downloading the model (~12 GiB, resumes if interrupted)"
    curl -fL --retry 10 --retry-all-errors -C - -o "$MODEL_PATH.part" "$MODEL_URL"
    log "Verifying SHA256 (takes a minute)"
    echo "$MODEL_SHA256  $MODEL_PATH.part" | sha256sum -c - >/dev/null || die "model checksum mismatch — delete $MODEL_PATH.part and re-run."
    mv "$MODEL_PATH.part" "$MODEL_PATH"
    touch "$MODEL_PATH.verified"
fi

# ------------------------------------------------------------ chat template ---
TEMPLATE_PATH="$DATA_DIR/templates/qwen3.8-ridge.jinja"
if [[ -n "$LOCAL_CHECKOUT" ]]; then
    cp "$LOCAL_CHECKOUT/templates/qwen3.8-ridge.jinja" "$TEMPLATE_PATH"
else
    curl -fsSL -o "$TEMPLATE_PATH" "$RAW_BASE/templates/qwen3.8-ridge.jinja"
fi

# ------------------------------------------------------------- run command ---
# Flag rationale lives in docs/WHY.md. Short version:
#   --fit off            manual VRAM layout — llama.cpp's auto-fit undoes our sizing
#   -fa on + q8_0/q4_0   flash-attn KV quant (Keys tolerate q8, Values q4; needs FA_ALL_QUANTS build)
#   --kv-unified         one context pool SHARED by all slots instead of ctx/slots each
#   --no-context-shift   mandatory: the model has recurrent (DeltaNet) layers
SERVER_CMD=("$DATA_DIR/bin/llama-server"
    -m "$MODEL_PATH"
    --alias "$MODEL_REPO"
    -ngl 99 --fit off -fa on
    -c "$CTX" -ctk q8_0 -ctv q4_0
    --parallel "$PARALLEL" --kv-unified --no-context-shift
    --jinja --chat-template-file "$TEMPLATE_PATH"
    --chat-template-kwargs "{\"reasoning_effort\":\"$REASONING\"}"
    --temp 1.0 --top-p 0.95 --top-k 20
    --host "$HOST" --port "$PORT" --metrics)

if [[ -n "${NO_SERVICE:-}" ]]; then
    log "NO_SERVICE=1 — files are ready. Run the server with:"
    printf '  %q ' "${SERVER_CMD[@]}"; echo
    exit 0
fi

# ---------------------------------------------------------- systemd service ---
log "Installing systemd service '${SERVICE_NAME}' (sudo needed for this step only)"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
sudo tee "$UNIT_FILE" > /dev/null << EOF
[Unit]
Description=Qwen3.8-27B on a 16 GB GPU (llama.cpp ${LLAMACPP_SHORT}) — ${GH_REPO}
After=network-online.target nvidia-persistenced.service
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
ExecStart=$(printf '%q ' "${SERVER_CMD[@]}")
Restart=on-failure
RestartSec=5
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"

# ------------------------------------------------------------- smoke test ---
log "Waiting for the model to load (up to 3 min on a SATA SSD)"
for i in $(seq 1 180); do
    curl -fsS -m 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && break
    systemctl is-failed -q "$SERVICE_NAME" && die "service failed to start — check: journalctl -u $SERVICE_NAME -n 50"
    sleep 1
    (( i == 180 )) && die "server did not become healthy — check: journalctl -u $SERVICE_NAME -n 50"
done
log "Health OK — running a real completion as smoke test"
REPLY="$(curl -fsS -m 120 "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with exactly: READY"}],"max_tokens":200}' \
    | grep -o 'READY' | head -1 || true)"
[[ "$REPLY" == "READY" ]] || warn "smoke completion did not return READY (model may still be warming up) — check manually."

# ------------------------------------------------------- claude-code wrapper ---
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude-qwen" << EOF
#!/bin/bash
# Run Claude Code against your local Qwen3.8-27B (${GH_REPO})
export ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT}"
export ANTHROPIC_AUTH_TOKEN="local"
export ANTHROPIC_MODEL="${MODEL_REPO}"
export ANTHROPIC_SMALL_FAST_MODEL="${MODEL_REPO}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${MODEL_REPO}"
exec claude "\$@"
EOF
chmod +x "$HOME/.local/bin/claude-qwen"

# ------------------------------------------------------------------- recap ---
echo
log "Done. Qwen3.8-27B is running on your 16 GB GPU."
echo "  Endpoint     : http://${HOST}:${PORT}/v1  (OpenAI-compatible; /v1/messages Anthropic-compatible)"
echo "  Web UI       : http://127.0.0.1:${PORT}   (local only unless HOST=0.0.0.0)"
echo "  Context      : ${CTX} tokens, shared across ${PARALLEL} slots"
echo "  Service      : systemctl status ${SERVICE_NAME}   (starts at boot)"
echo "  Logs         : journalctl -u ${SERVICE_NAME} -f"
echo "  Claude Code  : claude-qwen   (needs ~/.local/bin in PATH)"
echo "  Uninstall    : curl -fsSL ${RAW_BASE}/uninstall.sh | bash"
