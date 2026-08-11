#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_tmp_dir="$repo_dir/build/tmp"
mkdir -p "$repo_tmp_dir"
export TMPDIR="$repo_tmp_dir"
export TEMP="$repo_tmp_dir"
export TMP="$repo_tmp_dir"
cd "$repo_dir"

verilator --lint-only --Wall -Wno-DECLFILENAME -Wno-fatal \
  -f sim/filelist.f --top-module lpu_smoke_tb
verilator --lint-only --Wall -Wno-DECLFILENAME -Wno-fatal \
  -f sim/filelist.f --top-module lpu_arch_tb
verilator --lint-only --Wall -Wno-DECLFILENAME -Wno-fatal \
  -f sim/filelist.f --top-module lpu_mem_stream_tb
