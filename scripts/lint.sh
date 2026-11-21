#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"
for top in program_transport_tb program_mem_native_tb program_frontends_tb program_qctl_tb; do
  "${VERILATOR:-verilator}" --lint-only --timing --Wall -Wno-fatal -f sim/filelist.f --top-module "$top"
done
# Other FU/native regressions retain their dedicated sim/filelist_*.f and scripts.
