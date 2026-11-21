[CmdletBinding()]
param([string]$Distribution='Ubuntu-22.04',[string]$Verilator='verilator')
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$linuxRoot=(& wsl.exe -d $Distribution -- wslpath -a -u $repoRoot).Trim()
if($LASTEXITCODE -ne 0){throw 'Unable to resolve the repository in WSL.'}
foreach($top in @('program_transport_tb','program_mem_native_tb','program_frontends_tb','program_qctl_tb')){
  & wsl.exe -d $Distribution --cd $linuxRoot -- $Verilator --lint-only --timing --Wall -Wno-fatal -f sim/filelist.f --top-module $top
  if($LASTEXITCODE -ne 0){throw "Verilator lint failed: $top"}
}
