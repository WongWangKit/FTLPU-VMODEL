[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$repoTmpDir = Join-Path (Join-Path $repoRoot 'build') 'tmp'
New-Item -ItemType Directory -Force -Path $repoTmpDir | Out-Null
$env:TEMP = $repoTmpDir
$env:TMP = $repoTmpDir

if (-not (Get-Command verilator -ErrorAction SilentlyContinue)) {
  throw 'verilator was not found on PATH. Install Verilator before running lint.'
}

Push-Location $repoRoot
try {
  foreach ($top in @('lpu_smoke_tb', 'lpu_arch_tb', 'lpu_mem_stream_tb')) {
    & verilator --lint-only --Wall -Wno-DECLFILENAME -Wno-fatal -f sim/filelist.f --top-module $top
    if ($LASTEXITCODE -ne 0) {
      throw "Verilator lint for $top failed with exit code $LASTEXITCODE."
    }
  }
}
finally {
  Pop-Location
}
