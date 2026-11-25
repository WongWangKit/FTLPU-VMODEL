# Vivado simulator must be on PATH. Build and retained result directories must be new.
param([Parameter(Mandatory=$true)][string]$Build, [Parameter(Mandatory=$true)][string]$Results,
      [ValidateSet('native','legacy','geometry')][string]$Mode='native')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
if ((Test-Path -LiteralPath $Build) -or (Test-Path -LiteralPath $Results)) {throw 'Choose new Build and Results directories.'}
$buildDir=(New-Item -ItemType Directory -Path $Build -Force).FullName
$resultDir=(New-Item -ItemType Directory -Path $Results -Force).FullName
$tb=if($Mode -eq 'native'){'native_chain_tb'}elseif($Mode -eq 'geometry'){'top_profile_tb'}else{'program_system_tb'}
$files=@(Get-Content -LiteralPath "$repo/sim/filelist_program_integrated.f" | Where-Object {$_} )
$files+="sim/program_load/$tb.sv"
Push-Location $buildDir
try {
  $files | ForEach-Object {'"'+$repo+'/'+$_+'"'} | Set-Content -LiteralPath sources.f -Encoding ascii
  $files | ForEach-Object { "$( (Get-FileHash -LiteralPath "$repo/$_" -Algorithm SHA256).Hash )  $_" } |
      Set-Content -LiteralPath "$resultDir/sources.sha256" -Encoding ascii
  & xvlog --sv -f sources.f *> "$resultDir/compile.log"
  if ($LASTEXITCODE) {throw "xvlog failed; see $resultDir/compile.log"}
  & xelab --timescale 1ns/1ps $tb -s system_test -O0 -mt 4 *> "$resultDir/elab.log"
  if ($LASTEXITCODE) {throw "xelab failed; see $resultDir/elab.log"}
  $cases=if($Mode -eq 'legacy'){@(0,1,2)}else{@(0)}
  foreach($case in $cases){
    $log="$resultDir/run_$case.log"
    # Quote the '=' through the Vivado Windows batch launcher.
    & xsim system_test -runall -testplusarg ('"CASE='+$case+'"') *> $log
    if($LASTEXITCODE -or !(Select-String -LiteralPath $log -Pattern '^PASS ') -or
       (Select-String -LiteralPath $log -Pattern '^(Fatal:|ERROR:)')){throw "Simulation failed; see $log"}
    (Select-String -LiteralPath $log -Pattern '^PASS ').Line
  }
} finally {Pop-Location}
