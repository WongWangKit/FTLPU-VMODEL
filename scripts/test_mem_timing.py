"""Verify native MEM one/three-cycle command hops and short-path compatibility.

Uses Icarus Verilog from PATH, --iverilog/--vvp, or build/iverilog/bin.
The timing oracle observes public ports only. Build artifacts stay in build/.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CORE = [f"rtl/mem_native/{name}.sv" for name in (
    "mem_bank_superlane_leaf", "mem_bank_control_column", "mem_logical_bank_column",
    "mem_slice", "mem_group", "mem_hemisphere")]
ADAPTERS = ["rtl/mem_native/mem_c7_primitive_adapter.sv",
            "rtl/integration/lpu_mem_command_adapter.sv"]
TIMING_TB = "sim/mem_timing/mem_timing_tb.sv"


def tool(name: str, explicit: str | None) -> str:
    candidate = explicit or shutil.which(name)
    if candidate:
        return candidate
    for suffix in (".exe", ""):
        local = ROOT / "build/iverilog/bin" / (name + suffix)
        if local.is_file():
            return str(local)
    raise RuntimeError(f"Cannot find {name}; pass --{name} or put it on PATH")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog")
    parser.add_argument("--vvp")
    parser.add_argument("--output", type=Path, default=ROOT / "build/mem_timing")
    parser.add_argument("--regressions-only", action="store_true",
                        help="Run existing short-mode regressions and MEM/SRF timing only")
    parser.add_argument("--timeout", type=int, default=600,
                        help="Timeout in seconds for each compiler/simulator process")
    parser.add_argument("--baseline-ref", default="8bcf3807dd4987aac3e25853b92c7e7d6757062f",
                        help="Git revision containing the original one-cycle MEM implementation")
    args = parser.parse_args()
    compiler, simulator = tool("iverilog", args.iverilog), tool("vvp", args.vvp)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    results: list[dict] = []
    identities: dict[str, str] = {}

    def command(argv: list[str], log: Path) -> subprocess.CompletedProcess:
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=args.timeout)
        log.write_text(subprocess.list2cmdline(argv) + "\n" + result.stdout + result.stderr,
                       encoding="utf-8")
        return result

    def case(name: str, top: str, sources: list[str | Path], params: dict | None = None,
             plus: list[str] | None = None, failure: str | None = None,
             marker: str = "TEST_PASS") -> None:
        resolved = [str(ROOT / source) if not Path(source).is_absolute() else str(source)
                    for source in sources]
        for source in resolved:
            identities[source] = hashlib.sha256(Path(source).read_bytes()).hexdigest()
        executable = out / f"{name}.vvp"
        compile_args = [compiler, "-g2012", "-s", top, "-o", str(executable)]
        compile_args += [f"-P{top}.{key}={value}" for key, value in (params or {}).items()]
        compiled = command(compile_args + resolved, out / f"{name}_compile.log")
        if compiled.returncode:
            raise RuntimeError(f"Compile failed: {out / (name + '_compile.log')}")
        run = command([simulator, str(executable), *(plus or [])], out / f"{name}_run.log")
        text = run.stdout + run.stderr
        if failure:
            passed = run.returncode != 0 and failure in text and "UNEXPECTED_" not in text
        else:
            passed = run.returncode == 0 and marker in text and not re.search(r"FATAL:|ERROR:", text)
        results.append(dict(name=name, passed=passed, expected_failure=failure,
                            run_log=str(out / f"{name}_run.log"),
                            summary=[line for line in text.splitlines()
                                     if marker in line or (failure and failure in line)]))
        (out / "results.json").write_text(json.dumps(dict(results=results, source_sha256=identities),
                                                       indent=2) + "\n", encoding="utf-8")
        print(name, "PASS" if passed else "FAIL", flush=True)
        if not passed:
            raise RuntimeError(f"Simulation failed: {out / (name + '_run.log')}")

    for rows in (() if args.regressions_only else (2, 4, 8)):
        for seed in (0x4D454D31, 0x13579BDF):
            name = f"timing_rows{rows}_{seed:08x}"
            case(name, "mem_timing_tb", CORE + [TIMING_TB], {"ROWS": rows, "SEED": seed},
                 [f"+TRACE={(out / (name + '.csv')).as_posix()}"], marker="MEM_TIMING TEST_PASS")
    for rows, gap in (() if args.regressions_only else ((2, 0), (2, 1), (4, 1), (4, 5), (8, 13))):
        case(f"unsafe_rows{rows}_gap{gap}", "mem_timing_bad_transition_tb", CORE + [TIMING_TB],
             {"ROWS": rows, "GAP": gap}, failure="unsafe MEM 3-to-1 schedule")

    case("fault_regression", "mem_p1_fault_tb", CORE + ["sim/mem_p1/fault_tb.sv"])
    case("group_collision_regression", "mem_p1_group_collision_tb", CORE + ["sim/mem_p1/fault_tb.sv"])
    case("c7_entry_regression", "mem_p1_entry_tb", CORE + ADAPTERS +
         ["sim/mem_p1/runtime_checker.sv", "sim/mem_p1/entry_tb.sv"])

    # Pin the original implementation: HEAD may contain this change after commit.
    before = out / "short_baseline_source"
    old_sources: list[Path] = []
    for relative in CORE:
        snapshot = subprocess.run(["git", "show", f"{args.baseline_ref}:{relative}"], cwd=ROOT,
                                  capture_output=True, check=True).stdout
        path = before / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(snapshot)
        old_sources.append(path)
    old_trace, new_trace = out / "short_before.txt", out / "short_after.txt"
    case("short_before", "mem_p1_baseline_tb", old_sources + ["sim/mem_p1/baseline_tb.sv"],
         plus=[f"+TRACE={old_trace.as_posix()}"])
    case("short_after", "mem_p1_baseline_tb", CORE + ["sim/mem_p1/baseline_tb.sv"],
         plus=[f"+TRACE={new_trace.as_posix()}"])
    if old_trace.read_bytes() != new_trace.read_bytes():
        raise RuntimeError("Short-mode baseline trace changed")
    print("short_mode_trace_byte_identical PASS", flush=True)

    # Icarus does not support bind. Preserve each existing testbench's public-
    # port assertions; do not claim the omitted bound monitors were simulated.
    for name, filelist, top in (
        ("mem_srf_regression", "sim/filelist_mem_srf.f", "lpu_mem_srf_tb"),
        ("legacy47_adapter_regression", "sim/filelist_mem_command_adapter.f", "lpu_mem_command_adapter_tb"),
    ):
        sources = [line.strip() for line in (ROOT / filelist).read_text().splitlines()
                   if line.strip() and not line.strip().startswith("#") and "_bind.sv" not in line]
        case(name, top, sources)
        if name == "mem_srf_regression":
            timing_sources = [source for source in sources if source != "sim/tb/lpu_mem_srf_tb.sv"]
            for rows in (2, 4, 8):
                case(f"mem_srf_timing_rows{rows}", "mem_srf_timing_tb",
                     timing_sources + ["sim/mem_timing/mem_srf_timing_tb.sv"], {"ROWS": rows},
                     marker="MEM_SRF_TIMING TEST_PASS")
            case("profile16_collision_regression", "mem_profiles_collision_tb",
                 timing_sources + ["sim/mem_profiles/collision_tb.sv"], {"PROFILE": 16})
    report = dict(passed=True, cases=len(results), short_mode_trace_identical=True,
                  baseline_ref=args.baseline_ref,
                  short_mode_trace_sha256=hashlib.sha256(new_trace.read_bytes()).hexdigest(),
                  verification="Black-box MEM timing/data; legacy MEM/SRF testbench assertions; bind omitted by Icarus",
                  results=results, source_sha256=identities)
    (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"MEM_TIMING_SUITE PASS cases={len(results)} results={out / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
