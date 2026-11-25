"""Runtime-certified commands -> scheduled RTL port -> actual data channel/SR/SRAM."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import subprocess
import shutil

vm = Path(__file__).resolve().parents[2]
root = vm.parents[1]
sw, cm = (vm.parent / ("FTLPU-" + name) for name in ("SOFTWARE", "CMODEL"))
exp = root / "learn/data_dma_window_20261124"
p = argparse.ArgumentParser()
p.add_argument("run_id")
p.add_argument("--deploy", type=Path, default=root/"learn/c2c_dma_broad_tasks_20261119/tmp/deploy01")
p.add_argument("--software-only", action="store_true")
a = p.parse_args()
if Path(a.run_id).name != a.run_id or a.run_id in ("", ".", ".."):
    p.error("expected a new run name")
def run(v):
    work, report = [exp/k/a.run_id/str(v) for k in ("tmp","results")]
    report.mkdir(parents=True,exist_ok=False)
    work.mkdir(parents=True,exist_ok=False)
    def execute(name, cmd, batch=False):
        if batch:
            launcher=work/"run.cmd"
            launcher.write_text("@echo off\n"+cmd[0]+" "+" ".join(f'"{s}"' for s in cmd[1:])+"\n")
            cmd=["cmd","/d","/c",str(launcher)]
        with (report/(name+".log")).open("w") as f:
            subprocess.run(cmd,cwd=work,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=600)
    b=a.deploy/f"rt{v}"
    exe=work/"emit.exe"
    test=sw/"runtime/tests/runtime/weight_calendar_wire_test.cpp"
    image=a.deploy/f"proj{v}.ftlpu"
    libs=[b/"runtime"/n for n in ("libftlpu_software.a","libftlpu_cmodel_static.a")]
    execute("build",["g++","-std=c++20","-O1","-Wa,-mbig-obj",f"-I{b}/generated/include",
                     f"-I{cm}/include",f"-I{sw}/runtime/include",test,*libs,"-o",exe])
    cmdfile=report/"commands.hex"
    execute("issuer",[exe,image,cmdfile])
    if a.software_only:return
    files=[vm/s for s in (vm/"sim/filelist_mem_srf.f").read_text().splitlines() if s.startswith("rtl/")]
    files += [vm/f for f in ("rtl/queue/lpu_queue_fifo.sv","rtl/dma_native/lpu_dma_data_channel.sv",
              "rtl/dma_native/lpu_dma_mem_wave.sv","rtl/dma_native/lpu_dma_weight_window.sv",
              "rtl/dma_native/lpu_dma_weight_schedule_port.sv","rtl/dma_native/lpu_dma_scheduled_weight_load.sv",
              "sim/dma_native/weight_schedule_tb.sv")]
    (work/"files.prj").write_text("".join(f'sv work "{f.as_posix()}"\n' for f in files))
    shutil.copyfile(cmdfile,work/"commands.hex")
    execute("compile",["xvlog.bat","--prj","files.prj"],True)
    execute("elab",["xelab.bat","work.weight_schedule_tb","--generic_top",f"T={v//8}",
                    "--timescale","1ns/1ps","--mt","2","-s","test"],True)
    execute("sim",["xsim.bat","test","-runall"],True)
    log=(report/"sim.log").read_text(errors="replace")
    if f"PASS scheduled V={v} " not in log or "Fatal:" in log or "Error:" in log:
        raise RuntimeError(f"see {report}")
    inputs=[*files,test,image,cmdfile,*libs,sw/"runtime/include/ftlpu/software/runtime/weight_dma_calendar.hpp",
            sw/"runtime/include/ftlpu/software/runtime/common_overlap.hpp"]
    (report/"inputs.json").write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs},indent=2))
with ThreadPoolExecutor(2) as pool:list(pool.map(run,(16,32)))
