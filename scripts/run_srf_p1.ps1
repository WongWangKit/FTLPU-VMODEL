[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('prepare','baseline','compat')][string]$Stage,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RunId,
  [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& $Python (Join-Path $repoRoot 'sim/srf_p1/run.py') $Stage --run-id $RunId
if ($LASTEXITCODE -ne 0) { throw "SRF preparation $Stage failed, exit=$LASTEXITCODE" }
