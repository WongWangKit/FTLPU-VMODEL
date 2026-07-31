[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot 'build'
$simPath = Join-Path $buildDir 'lpu_smoke.vvp'

if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
  throw 'iverilog was not found on PATH. Install Icarus Verilog before running the smoke test.'
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $repoRoot
try {
  & iverilog -g2012 -s lpu_smoke_tb -o $simPath -f sim/filelist.f
  if ($LASTEXITCODE -ne 0) {
    throw "Icarus Verilog compilation failed with exit code $LASTEXITCODE."
  }

  & vvp $simPath
  if ($LASTEXITCODE -ne 0) {
    throw "Smoke test failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

