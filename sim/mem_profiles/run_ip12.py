"""Run MEM IP-12 lint and XSim elaboration for the full T2/T4 MEM geometry."""
import argparse
import importlib.util
import re
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mem_runner", ROOT / "sim/mem_p1/run.py")
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--stage", choices=("lint", "elab"), required=True)
    parser.add_argument("--xsim-bin", type=Path,
                        default=Path("C:/Users/huazh/Desktop/Vivado2023/Vivado/2023.2/bin"))
    parser.add_argument("--wsl-distro", default="Ubuntu-22.04")
    parser.add_argument("--verilator", default="/home/huazhe/.local/bin/verilator")
    parser.add_argument("--golden-root", type=Path, help="Optional frozen L1/L2 vectors to replay")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sources = [ROOT / p for p in common.CORE]
    common.save(out / "source_identity.json", {str(p): common.sha(p) for p in sources})
    (out / "git_head.txt").write_text(common.git(ROOT, "rev-parse", "HEAD") + "\n")
    result = []
    if args.stage == "lint":
        wsl = ["wsl.exe", "-d", args.wsl_distro, "--"]
        drive, tail = ROOT.as_posix().split(":", 1)
        linux_root = f"/mnt/{drive.lower()}{tail}"
        common.required(wsl + [args.verilator, "--version"], out, out / "version.log")
    else:
        common.save(out / "tools.json", {n: str(args.xsim_bin / f"{n}.bat")
                                         for n in ("xvlog", "xelab", "xsim")})

    for profile, tiles, depth in ((16, 2, 1024), (32, 4, 2048)):
        if args.stage == "lint":
            log = out / f"lpu{profile}.log"
            common.required(wsl + [args.verilator, "--lint-only", "--Wall", "--Wno-fatal",
                "--top-module", "mem_hemisphere", f"-GP_TILE_ROWS={tiles}",
                f"-GP_MEM_BANK_DEPTH_ROWS={depth}", f"-GP_MEM_ACTIVE_ROWS={depth}",
                *[f"{linux_root}/{p}" for p in common.CORE]], out, log)
            warning_lines = [line for line in log.read_text(encoding="utf-8").splitlines()
                             if line.startswith("%Warning")]
            # Keep original warnings in the log. Only these reviewed classes
            # are nonblocking; other warning types fail this gate.
            allowed = {"PINCONNECTEMPTY", "UNUSEDPARAM", "UNUSEDSIGNAL"}
            counts = {}
            for line in warning_lines:
                kind = re.match(r"%Warning-([^:]+):", line)
                if not kind or kind[1] not in allowed:
                    raise RuntimeError("unresolved lint finding: " + line)
                counts[kind[1]] = counts.get(kind[1], 0) + 1
            result.append(dict(profile=profile, status="passed", warning_counts=counts, log=str(log)))
        else:
            tb_dir = ROOT / "sim/mem_p1"
            checker = [tb_dir / n for n in ("runtime_checker.sv", "leaf_bind.sv", "control_bind.sv")]
            for kind, level in (("full", "l1"), ("sync", "l2")):
                work = common.compile_sim(out, f"lpu{profile}_{level}", sources + checker +
                                          [tb_dir / f"{kind}_tb.sv"], f"mem_p1_{kind}_tb",
                                          [f"DEPTH={depth}", f"ACTIVE={depth}", f"TILES={tiles}"])
                entry = dict(profile=profile, level=level, status="elaborated",
                             log=str(work / "elaborate.txt"), runs=[])
                if args.golden_root:
                    golden = max(args.golden_root.glob(f"{profile}_attempt*"),
                                 key=lambda p: int(p.name.split("attempt")[-1]))
                    for case in ("directed", "seed0", "seed15"):
                        vector = (golden / f"{case}_{level}.txt").resolve()
                        res = common.simulate(out, work, case, ["VECTORS=" + vector.as_posix()])
                        entry["runs"].append(dict(case=case, vector_sha256=common.sha(vector), result=res))
                result.append(entry)
        common.save(out / "results.json", result)
    print(f"MEM_IP12_{args.stage.upper()}_PASS", out, flush=True)


if __name__ == "__main__":
    main()
