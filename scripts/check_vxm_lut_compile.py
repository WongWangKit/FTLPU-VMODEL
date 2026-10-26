"""Compile selected VXM tops with an optional local pyslang installation."""
from pathlib import Path
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build" / "tools"))
from pyslang.driver import Driver

os.chdir(ROOT)
# Compile the RTL and the selected bench; unrelated legacy benches can use
# simulator extensions or reserved identifiers that slang rejects at parse time.
rtl = [line.strip() for line in (ROOT / "sim/filelist.f").read_text().splitlines()
       if line.strip().startswith("rtl/")]
tops = sys.argv[1:] or [
    "lpu_vxm_tile_lut_tb",
    "lpu_vxm_log_tb",
    "lpu_vxm_slice_fp32_special_tb",
    "lpu_vxm_slice_bf16_special_tb",
    "lpu_vxm_tile_execution_tb",
]
failed = False
for top in tops:
    driver = Driver()
    driver.addStandardArgs()
    driver.setTerminalColorsEnabled(False)
    sources = rtl + [
        "sim/tb/vxm/lpu_vxm_log_reference_pkg.sv",
        f"sim/tb/vxm/{top}.sv",
    ]
    if not driver.parseCommandLine(
        f"slang {' '.join(sources)} --top {top} --timescale 1ns/1ps "
        "-Wno-unknown-sys-name"
    ):
        raise SystemExit("invalid compiler arguments")
    if not driver.processOptions() or not driver.parseAllSources():
        raise SystemExit("could not parse RTL sources")
    compilation = driver.createCompilation()
    driver.reportCompilation(compilation, True)
    success = driver.reportDiagnostics(False)
    print(f"{top}: {'PASS' if success else 'FAIL'}", flush=True)
    failed |= not success
raise SystemExit(int(failed))
