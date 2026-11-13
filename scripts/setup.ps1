$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Write-Host "==> engine: uv sync"
Push-Location (Join-Path $root "asct-be-engine")
try { uv sync --all-groups } finally { Pop-Location }

Write-Host "==> ui: pnpm install"
Push-Location (Join-Path $root "asct-fe-desktop")
try { pnpm install } finally { Pop-Location }
