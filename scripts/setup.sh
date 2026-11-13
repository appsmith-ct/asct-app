#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> engine: uv sync"
(cd asct-be-engine && uv sync --all-groups)

echo "==> ui: pnpm install"
(cd asct-fe-desktop && pnpm install)
