#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
vcs_build_dir="$repo_dir/build/vcs"
repo_tmp_dir="$repo_dir/build/tmp"
license_spec=${LM_LICENSE_FILE:-27000@andromeda}
export LM_LICENSE_FILE="$license_spec"
mkdir -p "$repo_tmp_dir"
export TMPDIR="$repo_tmp_dir"
export TEMP="$repo_tmp_dir"
export TMP="$repo_tmp_dir"

# The legacy license client can briefly refuse a second checkout immediately
# after a simulation exits. Retry only the compiler checkout; test failures
# from a generated simv still stop the regression immediately.
vcs_compile() {
  local attempt
  for attempt in 1 2 3; do
    if vcs "$@"; then
      return 0
    fi
    if (( attempt < 3 )); then
      sleep 2
    fi
  done
  return 1
}

source_files=()
while IFS= read -r source_file; do
  if [[ -n "$source_file" && "$source_file" != \#* ]]; then
    source_files+=("$repo_dir/$source_file")
  fi
done < "$repo_dir/sim/filelist.f"

vcs_test() {
  local top=$1
  local name=$2
  local test_dir="$vcs_build_dir/$name"
  mkdir -p "$test_dir"
  ln -sfn "$repo_dir/sim" "$test_dir/sim"
  (
    cd "$test_dir"
    vcs_compile -full64 -sverilog -timescale=1ns/1ps \
      -LDFLAGS -Wl,--no-as-needed \
      -top "$top" "${source_files[@]}" \
      -o "$test_dir/simv" -Mdir="$test_dir/csrc"
    "$test_dir/simv"
  )
}

"$repo_dir/scripts/generate_cmodel_vectors.sh"

vcs_test lpu_smoke_tb smoke
vcs_test lpu_arch_tb arch
vcs_test lpu_mem_stream_tb mem_stream
vcs_test lpu_sxm_transpose_tb sxm_transpose
vcs_test lpu_sxm_wavefront_tb sxm_wavefront
vcs_test lpu_vxm_int8_tb vxm_int8
vcs_test lpu_vxm_fp16_tb vxm_fp16
vcs_test lpu_vxm_fp32_arithmetic_tb vxm_fp32_arithmetic
vcs_test lpu_mxm_vector_tb mxm_vector
vcs_test lpu_mxm_fp16_tb mxm_fp16
vcs_test lpu_mxm_fault_tb mxm_fault
vcs_test lpu_mxm_accumulator_tb mxm_accumulator
vcs_test lpu_mxm_column_tb mxm_column
vcs_test lpu_mxm_int8_dequant_tb mxm_int8_dequant
vcs_test lpu_mxm_block8_tb mxm_block8
vcs_test lpu_mxm_weight_stream_tb mxm_weight_stream
vcs_test lpu_smollm2_ffn_tb smollm2_ffn
