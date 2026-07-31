[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command verilator -ErrorAction SilentlyContinue)) {
  throw 'verilator was not found on PATH. Install Verilator before running lint.'
}

Push-Location $repoRoot
try {
  & verilator --lint-only --Wall -Wno-DECLFILENAME -f sim/filelist.f --top-module lpu_smoke_tb
  if ($LASTEXITCODE -ne 0) {
    throw "Verilator lint failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

