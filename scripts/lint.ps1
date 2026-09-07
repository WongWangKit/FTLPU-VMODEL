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
  foreach ($top in @('lpu_smoke_tb', 'lpu_arch_tb', 'lpu_mem_stream_tb',
                     'lpu_vxm_alu_tb', 'lpu_vxm_input_converter_tb',
                     'lpu_vxm_fp16_stream_groups_tb',
                     'lpu_vxm_datapath_mux_tb',
                      'lpu_vxm_execution_stage_tb',
                      'lpu_vxm_significand_multiplier_tb',
                      'lpu_vxm_shared_float_compare_tb',
                      'lpu_vxm_tile_pair_lut_tb',
                      'lpu_vxm_16_alu_tb',
                      'lpu_vxm_instruction_controller_tb',
                      'lpu_vxm_tile_execution_tb',
                      'lpu_vxm_tile_fp32_phase_tb',
                      'lpu_vxm_tile_special_paths_tb',
                      'lpu_vxm_slice_tb',
                      'lpu_vxm_slice_fp32_special_tb',
                      'lpu_vxm_slice_bf16_special_tb')) {
    & verilator --lint-only --Wall -Wno-DECLFILENAME -Wno-fatal -f sim/filelist.f --top-module $top
    if ($LASTEXITCODE -ne 0) {
      throw "Verilator lint for $top failed with exit code $LASTEXITCODE."
    }
  }
}
finally {
  Pop-Location
}
