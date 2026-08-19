#!/usr/bin/env bash
# Quick benchmark: generation speed at empty context and at depth (~20k tokens).
# Usage: ./bench.sh [PORT]   (default 8001; reads the API key if one was generated)
set -euo pipefail
export LC_ALL=C
PORT="${1:-${PORT:-8001}}"
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/qwen3.8-27b-in-16gb}"
URL="http://127.0.0.1:${PORT}/v1/chat/completions"
AUTH=(); [[ -s "$DATA_DIR/api.key" ]] && AUTH=(-H "Authorization: Bearer $(cat "$DATA_DIR/api.key")")

curl -fsS -m 5 "http://127.0.0.1:${PORT}/health" >/dev/null || { echo "server not reachable on :${PORT}" >&2; exit 1; }

run() { # $1=label  $2=user content
  # llama-server returns a "timings" object: prefill (prompt) and generation
  # (predicted) rates measured server-side — wall-clock would count the prefill
  # against generation speed and massively understate it at depth.
  local out
  out=$(curl -fsS -m 900 "$URL" "${AUTH[@]}" -H 'Content-Type: application/json' \
    --data-binary @<(printf '{"messages":[{"role":"user","content":%s}],"max_tokens":256,"temperature":1.0}' "$2"))
  printf '%s' "$out" | python3 -c '
import json, sys
label = sys.argv[1]
r = json.load(sys.stdin)
t = r.get("timings") or {}
if t:
    print(f"  {label:<24} prefill {t.get("prompt_n",0):>6} tok @ {t.get("prompt_per_second",0):7.1f} tok/s | generation {t.get("predicted_n",0):>4} tok @ {t.get("predicted_per_second",0):5.1f} tok/s")
else:
    u = r.get("usage") or {}
    print(f"  {label:<24} {u.get("completion_tokens","?")} tokens generated (server did not return timings)")
' "$1"
}

echo "── Generation speed (256 new tokens each) ──"
run "empty context" '"Write a bash one-liner that counts lines of code in a git repo, then explain it briefly."'

# ~20k tokens of context: send a large synthetic document and ask about it.
DOC=$(python3 -c 'print(("The quick brown fox jumps over the lazy dog. " * 40 + "\n") * 55)')
run "~20k-token context" "$(python3 -c 'import json,sys; print(json.dumps("Here is a document:\n" + sys.argv[1] + "\nIn one sentence, what is this document?"))' "$DOC")"

echo
echo "Reference generation speed on RTX 4070 Ti SUPER: ~45 tok/s empty, ~40 tok/s at 21k (docs/WHY.md)."
