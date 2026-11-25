$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
Push-Location $appRoot
try {
  & node 'server\cli.mjs' scan
} finally {
  Pop-Location
}
