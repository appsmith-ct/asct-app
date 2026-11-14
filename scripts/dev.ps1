$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$engine = Start-Process -FilePath "uv" `
    -ArgumentList "run", "appsmith", "serve", "--port", "8000" `
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
