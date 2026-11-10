[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('prepare','baseline','compat','reference','smoke','full','units','safety','parameters','mutation','legacy','filelists','audit')]
  [string]$Stage,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RunId,
  [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag='rtl_v1',
  [string]$Python='python'
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if($Stage -eq 'audit'){
  & $Python -B (Join-Path $repo 'sim/mem_p1/audit.py') --run-id $RunId
}elseif($Stage -in @('prepare','baseline','compat')){
  & $Python -B (Join-Path $repo 'sim/mem_p1/run.py') $Stage --run-id $RunId
}else{
  & $Python -B (Join-Path $repo 'sim/mem_p1/verify.py') $Stage --run-id $RunId --tag $Tag
}
if($LASTEXITCODE -ne 0){throw "MEM P1 $Stage failed; preserve logs; exit=$LASTEXITCODE"}
