"""Product data-IP profile regression. Run from any directory with XSim in PATH."""
from argparse import ArgumentParser
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess

vm = Path(__file__).resolve().parents[2]
cm = vm.parent / "FTLPU-CMODEL"
lab = vm.parents[1] / "learn/data_dma_ip_p0_20261125"
ap = ArgumentParser()
ap.add_argument("run")
ap.add_argument("--cases", default="30,31,32,33,34,35,36,37")
ap.add_argument("--targets", default="16,32")
args = ap.parse_args()
if not re.fullmatch("[a-zA-Z0-9_-]+", args.run):
    ap.error("new run identifier required")
cases = [int(k) for k in args.cases.split(",")]
def profile(v):
    assert v in (16, 32)
    t, o = (lab / d / args.run / str(v) for d in ("tmp", "results"))
    t.mkdir(parents=True); o.mkdir(parents=True)
    config = json.loads((cm / f"config/ftlpu-lpu{v}-mixed.json").read_text(encoding="utf-8"))
    lock = json.loads((cm/"config/dma-integration-v2.lock.json").read_text())["profiles"][config["target"]["name"]]
    rows = config["mem"]["rows_per_bank"]; cols = config["mem"]["slices_per_hemisphere"]
    files = [vm/s for s in (vm/"sim/filelist_program_integrated.f").read_text().splitlines() if s]
    files.append(vm/"sim/program_load/shared_dma_system_tb.sv")
    (t/"files.prj").write_text("".join(f'sv work "{f.as_posix()}"\n' for f in files))
    (t/"gold.hex").write_text("00\n"*(42*v))
    (o/"manifest.json").write_text(json.dumps(dict(target=config["target"]["name"],rows=rows,columns=cols,
        lock=lock,sha256={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files}),indent=2))
    def job(label, cmd):
        batch=t/"launch.cmd"
        batch.write_text("@echo off\n"+cmd[0]+" "+" ".join(f'"{x}"' for x in cmd[1:])+"\n")
        with (o/(label+".log")).open("w") as f:
            subprocess.run(["cmd","/d","/c",str(batch)],cwd=t,stdout=f,stderr=f,timeout=1200,check=True)
        s=(o/(label+".log")).read_text(errors="replace")
        if "ERROR:" in s or "Fatal:" in s or (label=="elab" and "Built simulation snapshot p0" not in s):
            raise ValueError(o/(label+".log"))
        return s
    dpi=31 in cases
    if dpi:
        sw=cm.parent/"FTLPU-SOFTWARE"
        build=lab.parent/f"c2c_dma_broad_tasks_20261119/tmp/deploy01/rt{v}"
        image=lab.parent/f"data_dma_top_20261124/results/bank_release02/{v}/a.ftlpu"
        shutil.copyfile(image,t/"a.ftlpu")
        cpp=vm/"sim/dma_native/p0_driver_dpi.cpp"
        cmd=["g++","-std=c++20","-O1","-Wa,-mbig-obj","-shared","-static","-static-libgcc","-static-libstdc++",
             f"-I{build}/generated/include",f"-I{cm}/include",f"-I{sw}/runtime/include",str(cpp),
             str(build/"runtime/libftlpu_software.a"),str(build/"runtime/libftlpu_cmodel_static.a"),
             "-Wl,--out-implib,p0client.a","-o","p0client.dll"]
        with (o/"build_dpi.log").open("w") as f:subprocess.run(cmd,cwd=t,stdout=f,stderr=f,check=True)
        (o/"dpi_sha.json").write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in
            (image,cpp,sw/"runtime/include/ftlpu/software/runtime/static_weight_port.hpp",t/"p0client.dll")},indent=2))
    job("compile",["xvlog.bat",*(["-d","FTLPU_P0_DPI"] if dpi else []),"--prj","files.prj"])
    job("elab",["xelab.bat","work.shared_dma_system_tb","--generic_top",f"V={v}","--generic_top",
         f"PRODUCT_ROWS={rows}","--generic_top",f"PRODUCT_COLUMNS={cols}","--generic_top","BG_TEST=1",
         "--generic_top","PAGE_TEST=1","--mt","2","--timescale","1ns/1ps",*(["--sv_root",str(t),"--sv_lib","p0client"] if dpi else []),"-s","p0"])
    for k in cases:
        s=job(f"case{k}",["xsim.bat","p0","-runall","-testplusarg",f"CASE={k}","-testplusarg","GOLD=gold.hex"])
        if f"case={k} " not in s or "PASS shared DMA" not in s:raise ValueError((v,k))
        if k==30:
            assert f"rows={rows} columns={cols} rowbits={rows.bit_length()-1} P={lock['P']} RT={lock['RT']} Q={lock['Q']} mem_imem={lock['imem']['Mem']} mxm_imem={lock['imem']['Mxm']}" in s
        marker={30:"P0 BOUNDS",31:"P0 DRIVER",32:"P0 FLOW",33:"P0 TAIL",34:"P0 ID",35:"INDEXED",36:"EXPERT",37:"RECOVER"}[k]
        print(v,k,next(line for line in s.splitlines() if line.startswith(marker)),flush=True)
with ThreadPoolExecutor(2) as pool:
    list(pool.map(profile,map(int,args.targets.split(","))))
