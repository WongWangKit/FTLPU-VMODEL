# Vivado simulator must be on PATH. Build and retained result directories must be new.
param([Parameter(Mandatory=$true)][string]$Build, [Parameter(Mandatory=$true)][string]$Results,
      [ValidateSet('native','macro','tap','legacy','geometry')][string]$Mode='native')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
if ((Test-Path -LiteralPath $Build) -or (Test-Path -LiteralPath $Results)) {throw 'Choose new Build and Results directories.'}
$buildDir=(New-Item -ItemType Directory -Path $Build -Force).FullName
$resultDir=(New-Item -ItemType Directory -Path $Results -Force).FullName
$tb=if($Mode -in @('native','macro','tap')){'native_chain_tb'}elseif($Mode -eq 'geometry'){'top_profile_tb'}else{'program_system_tb'}
$files=@(Get-Content -LiteralPath "$repo/sim/filelist_program_integrated.f" | Where-Object {$_} )
$files+="sim/program_load/$tb.sv"
Push-Location $buildDir
try {
  $files | ForEach-Object {'"'+$repo+'/'+$_+'"'} | Set-Content -LiteralPath sources.f -Encoding ascii
  $files | ForEach-Object { "$( (Get-FileHash -LiteralPath "$repo/$_" -Algorithm SHA256).Hash )  $_" } |
      Set-Content -LiteralPath "$resultDir/sources.sha256" -Encoding ascii
  Write-Host "[$Mode] Compiling RTL: $resultDir/compile.log"
  & xvlog --sv -f sources.f *> "$resultDir/compile.log"
  if ($LASTEXITCODE) {throw "xvlog failed; see $resultDir/compile.log"}
  $params=if($Mode -eq 'tap'){@('--generic_top','"TAP_TEST=1"')}else{@()}
  Write-Host "[$Mode] Elaborating $tb : $resultDir/elab.log"
  & xelab @params --timescale 1ns/1ps $tb -s system_test -O0 -mt 4 *> "$resultDir/elab.log"
  if ($LASTEXITCODE) {throw "xelab failed; see $resultDir/elab.log"}
  $cases=if($Mode -in @('legacy','tap')){@(0,1,2)}elseif($Mode -eq 'macro'){@(0,1)}else{@(0)}
  foreach($case in $cases){
    $log="$resultDir/run_$case.log"
    # Quote the '=' through the Vivado Windows batch launcher.
    $args2=if($Mode -eq 'macro' -and $case -eq 1){@('-testplusarg','MACRO_MXM','-testplusarg','STREAM_MXM')}elseif($Mode -eq 'macro'){@('-testplusarg','MACRO_MXM')}elseif($Mode -eq 'tap' -and $case -eq 1){@('-testplusarg','FP32')}elseif($Mode -eq 'tap' -and $case -eq 2){@('-testplusarg','DROP_PLANE')}else{@()}
    Write-Host "[$Mode] Simulating case $case : $log"
    & xsim system_test @args2 -runall -testplusarg ('"CASE='+$case+'"') *> $log
    if($LASTEXITCODE -or !(Select-String -LiteralPath $log -Pattern '^PASS ') -or
       (Select-String -LiteralPath $log -Pattern '^(Fatal:|ERROR:)')){throw "Simulation failed; see $log"}
    (Select-String -LiteralPath $log -Pattern '^PASS ').Line
  }
} finally {Pop-Location}
