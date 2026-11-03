[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('prepare','lane','diagnostics','callers','legacy','audit','extras','report','finalize','all')][string]$Stage,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RunId,
  [string]$Python='python'
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if($Stage -in @('prepare','all')){
  $icarus=(Get-Command iverilog -ErrorAction SilentlyContinue) -and (Get-Command vvp -ErrorAction SilentlyContinue)
  foreach($path in @('C:/iverilog/bin/iverilog.exe','C:/Program Files/iverilog/bin/iverilog.exe','F:/iverilog/bin/iverilog.exe')){
    if((Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $path) 'vvp.exe'))){$icarus=$true}
  }
  if($icarus){throw 'Icarus is now available: implement/run D03-C cross-simulator validation before using this XSim-only full entry; do not silently claim single-tool completion.'}
}
$stages=if($Stage -eq 'all'){@('prepare','lane','diagnostics','callers','legacy','audit','extras','report','finalize')}else{@($Stage)}
foreach($item in $stages){
  if($item -in @('extras','finalize')){
    $script=if($item -eq 'extras'){'retry_checks.py'}else{'finalize.py'}
    & $Python -B (Join-Path $repo "sim/srf_p1/$script") --run-id $RunId
  }else{
    & $Python -B (Join-Path $repo 'sim/srf_p1/accept.py') $item --run-id $RunId
  }
  if($LASTEXITCODE -ne 0){throw "SRF acceptance $item failed, exit=$LASTEXITCODE; preserve logs and do not mark PASS"}
}
