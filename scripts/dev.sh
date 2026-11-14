#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

cleanup() {
  echo "Stopping..."
  [[ -n "${ENGINE_PID:-}" ]] && kill "$ENGINE_PID" 2>/dev/null || true
  [[ -n "${UI_PID:-}" ]] && kill "$UI_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

(cd asct-be-engine && uv run appsmith serve --port 8000) &
ENGINE_PID=$!

(cd asct-fe-desktop && pnpm dev) &
UI_PID=$!

wait
