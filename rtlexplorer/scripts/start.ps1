$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$frontend = Join-Path $appRoot 'dist\index.html'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw 'Node.js was not found on PATH. Install Node.js 20+ or run from the Codex desktop environment.'
}

if (-not (Test-Path -LiteralPath $frontend)) {
  throw 'The frontend build is missing. Run npm install and npm run build in the application directory.'
}

$config = Get-Content -LiteralPath (Join-Path $appRoot 'config.json') -Raw | ConvertFrom-Json
$url = "http://127.0.0.1:$($config.port)"
Write-Host "LPU RTL Architecture Explorer: $url"
Write-Host "RTL source remains local and read-only: $($config.projectRoot)"
Start-Process $url
& node (Join-Path $appRoot 'server\index.mjs')
