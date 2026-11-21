[CmdletBinding()]
param(
  [string]$Distribution = 'Ubuntu-22.04',
  [string]$Verilator = 'verilator',
  [switch]$FullSystem
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$linuxRoot = (& wsl.exe -d $Distribution -- wslpath -a -u $repoRoot).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the repository in WSL.' }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stages = @('axi_read', 'epoch', 'prime_window', 'transport', 'mem_native', 'frontends', 'qctl')
if ($FullSystem) { $stages += 'system' }
foreach ($stage in $stages) {
  & wsl.exe -d $Distribution --cd $linuxRoot -- python3 sim/program_load/run.py `
    --stage $stage --out "$linuxRoot/build/program_load/results/$stamp/$stage" `
    --build-root "$linuxRoot/build/program_load/tmp/$stamp/$stage" --verilator $Verilator
  if ($LASTEXITCODE -ne 0) { throw "Program Load $stage failed; inspect build/program_load/results/$stamp." }
}
Write-Host "Program Load results: $repoRoot/build/program_load/results/$stamp"
