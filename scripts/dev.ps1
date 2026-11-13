$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$engine = Start-Process -FilePath "uv" `
    -ArgumentList "run", "uvicorn", "appsmith.api.main:app", "--reload", "--port", "8000" `
    -WorkingDirectory (Join-Path $root "asct-be-engine") `
    -PassThru -NoNewWindow

try {
    Push-Location (Join-Path $root "asct-fe-desktop")
    pnpm dev
} finally {
    Pop-Location
    if (-not $engine.HasExited) {
        Stop-Process -Id $engine.Id -Force
    }
}
