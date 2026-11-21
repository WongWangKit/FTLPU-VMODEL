#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"
stamp=$(date +%Y%m%d_%H%M%S)
out="$repo_dir/build/program_load/results/$stamp"
obj="$repo_dir/build/program_load/tmp/$stamp"
stages=(axi_read epoch prime_window transport mem_native frontends qctl)
if [[ ${1:-} == --system ]]; then stages+=(system); fi
for stage in "${stages[@]}"; do
  python3 sim/program_load/run.py --stage "$stage" --out "$out/$stage" --build-root "$obj/$stage" --verilator "${VERILATOR:-verilator}"
done
printf 'Program Load results: %s\n' "$out"
