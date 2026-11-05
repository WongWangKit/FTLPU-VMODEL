#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"
python3 sim/cmodel/generate_mxm_supercell_vectors.py
for top in lpu_mxm_bf16_dot_csa_tb lpu_mxm_fp32_add_pipe_tb lpu_mxm_output_pipe_tb lpu_mxm_supercell_tb lpu_mxm_supercell_chain_tb lpu_mxm_control_tb lpu_mxm_frontend_tb lpu_mxm_backend_tb lpu_mxm_core_tb; do
  target="build/vcs/$top"
  mkdir -p "$target"
  vcs -full64 -sverilog -timescale=1ns/1ps -top "$top" \
    -f sim/filelist_mxm_supercell.f "sim/tb/mxm/$top.sv" \
    -Mdir="$target/csrc" -o "$target/simv" -l "$target/compile.log"
  args=()
  case "$top" in
    lpu_mxm_bf16_dot_csa_tb)
      args=(+vectors=build/mxm_supercell/vectors/dot_k8.hex +count=2048) ;;
    lpu_mxm_fp32_add_pipe_tb)
      args=(+vectors=build/mxm_supercell/vectors/fp32_add.hex +count=4096) ;;
    lpu_mxm_backend_tb)
      args=(+vectors=build/mxm_supercell/vectors/backend.hex +output_vectors=build/mxm_supercell/vectors/backend_output.hex) ;;
    lpu_mxm_output_pipe_tb)
      args=(+vectors=build/mxm_supercell/vectors/output.hex) ;;
  esac
  "$target/simv" -no_save "${args[@]}" -l "$target/run.log"
done
