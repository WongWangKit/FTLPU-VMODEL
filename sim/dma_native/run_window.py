"""XSim component regression; no product top or program DMA in the file list."""
import argparse
import csv
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess

vm = Path(__file__).resolve().parents[2]
learn = vm.parents[1] / "learn"
ap = argparse.ArgumentParser()
ap.add_argument("run_id")
ap.add_argument("--fixture", type=Path, default=learn / "data_dma_moe_20261124/results/stage03")
ap.add_argument("--check-only",action="store_true",help="recheck saved edge traces against the same CModel descriptors")
args = ap.parse_args()
if Path(args.run_id).name != args.run_id or args.run_id in ("", ".", ".."):
    ap.error("use a new run name, not a path")
exp = learn / "data_dma_window_20261124"
out = exp / "results" / args.run_id
if not args.check_only:
    out.mkdir(parents=True, exist_ok=False)
files = [s for s in (vm/"sim/filelist_mem_srf.f").read_text().splitlines() if s.startswith("rtl/")]
files += ["rtl/queue/lpu_queue_fifo.sv", "rtl/dma_native/lpu_dma_data_channel.sv",
          "rtl/dma_native/lpu_dma_mem_wave.sv", "rtl/dma_native/lpu_dma_weight_window.sv",
          "sim/dma_native/data_window_tb.sv"]

def check_replay(report, desc, v):
    """Compare accepted transactions (not wall cycles) to the CModel layout."""
    groups = {}
    with (report/"edges.csv").open() as f:
        for row in csv.DictReader(f):
            groups.setdefault(int(row["tag"]), {}).setdefault(row["event"].strip(), []).append(
                tuple(int(row[k]) for k in ("edge","index_or_address","value","bank","stream")))
    comparison = []
    for j, line in enumerate(desc.read_text().splitlines()):
        hem,bank,lane,first,addr,count,stride,slot,page,last = map(int,line.split())
        for st in (False,True):
            tag = 2*j+1+int(st)
            g = groups[tag]
            ax = g["AW" if st else "AR"]
            native = g["MEM_read" if st else "RX_launch"]
            ret = g["native_retire"]
            source = 0xc000 if st else addr
            expected = [source+i*(v if st else stride) for i in range(count)]
            actual = [start+i*v for _,start,n,_,_ in ax for i in range(n)]
            if actual != expected or [(n[1],n[3],n[4]) for n in native] != [
                    (first+i,bank,lane if st else 24+lane) for i in range(count)]:
                raise RuntimeError(f"tag={tag} transaction addresses or native layout differ; see edges.csv")
            if len(ret)!=count or any(n[2] or n[1]!=first+i for i,n in enumerate(ret)):
                raise RuntimeError(f"tag={tag} failed or missing retirement")
            tiles = g["TX_gather" if st else "registered_leaf_write"]
            if len(tiles)!=count*(v//8):
                raise RuntimeError(f"tag={tag} incomplete tile trace")
            for i in range(count):
                slice_ = tiles[i*(v//8):(i+1)*(v//8)]
                if not (native[i][0]<slice_[0][0]<=slice_[-1][0]<ret[i][0]):
                    raise RuntimeError(f"tag={tag} vector={i} tile retirement order")
                if not st and g["R"][i][0]>=native[i][0]:
                    raise RuntimeError(f"tag={tag} replay before R")
            result = g["result_accept"][0][0]
            if result <= max(ret[-1][0],g["B"][-1][0] if st else 0):
                raise RuntimeError(f"tag={tag} early result")
            comparison.append(dict(tag=tag,page=page,slot=slot,store=st,vectors=count,
                                   first_address_edge=ax[0][0],last_tile_sample=tiles[-1][0],
                                   last_native_retire=ret[-1][0],result_accept=result))
    if len(comparison)!=48:
        raise RuntimeError("expected 24 CModel segments, LOAD and STORE each")
    (report/"comparison.json").write_text(json.dumps(comparison,indent=1))

def run(v):
    work = exp / "tmp" / args.run_id / str(v)
    work.mkdir(parents=True)
    report = out / str(v)
    report.mkdir()
    for ext in ("desc", "hex"):
        src, = args.fixture.glob(f"v{v}-ab1-rt128-*-s17.{ext}")
        shutil.copyfile(src, work / ("gold."+ext))
    (work/"files.prj").write_text("".join(f'sv work "{(vm/f).as_posix()}"\n' for f in files))
    for name, argv in [("compile", ["xvlog.bat","--prj","files.prj"]),
                       ("elab", ["xelab.bat","work.data_window_tb","--generic_top",f"T={v//8}",
                                 "--timescale","1ns/1ps","--mt","2","-s","test"]),
                       ("sim", ["xsim.bat","test","-runall","-testplusarg","DESC=gold.desc",
                                "-testplusarg","HEX=gold.hex"])]:
        batch = work / "launch.cmd"
        batch.write_text("@echo off\n"+argv[0]+" "+" ".join(f'"{a}"' for a in argv[1:])+"\n")
        log = report/(name+".log")
        with log.open("w") as f:
            subprocess.run(["cmd","/d","/c",str(batch)],cwd=work,stdout=f,stderr=f,check=True,timeout=600)
    log = (report/"sim.log").read_text(errors="replace")
    if (work/"edges.csv").exists():
        shutil.copyfile(work/"edges.csv", report/"edges.csv")
    inputs = [vm/f for f in files] + [work/"gold.desc", work/"gold.hex"]
    (report/"inputs.json").write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                                                 for p in inputs}, indent=2))
    if f"PASS T={v//8} " not in log or "Fatal:" in log or "Error:" in log:
        raise RuntimeError(f"LPU{v}: see {report}")
    check_replay(report,work/"gold.desc",v)

if args.check_only:
    for v in (16,32):
        report=out/str(v)
        src,=args.fixture.glob(f"v{v}-ab1-rt128-*-s17.desc")
        if hashlib.sha256(src.read_bytes()).hexdigest()!=json.loads((report/"inputs.json").read_text())["gold.desc"]:
            raise ValueError("CModel fixture differs from simulation")
        check_replay(report,src,v)
else:
    with ThreadPoolExecutor(2) as pool:
        list(pool.map(run, (16,32)))
