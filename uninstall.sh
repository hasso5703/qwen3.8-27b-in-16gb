#!/usr/bin/env bash
# qwen3.8-27b-in-16gb — uninstaller
# Removes the service, binaries and wrapper. PURGE=1 also deletes the model (~12 GiB).
set -euo pipefail
SERVICE_NAME="qwen3.8-27b"
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/qwen3.8-27b-in-16gb}"

if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    echo "==> Removing systemd service (sudo)"
    sudo systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
fi

rm -f "$HOME/.local/bin/claude-qwen"
rm -rf "$DATA_DIR/bin" "$DATA_DIR/templates"

if [[ -n "${PURGE:-}" ]]; then
    echo "==> PURGE=1 — deleting the model"
    rm -rf "$DATA_DIR"
else
    echo "==> Kept the model in $DATA_DIR (12 GiB). Re-run with PURGE=1 to delete it."
fi
echo "==> Done."
