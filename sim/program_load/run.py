"""Pinned Program Load regression; run with Python in WSL/Linux.

python3 sim/program_load/run.py --out /absolute/path --stage transport
Each output directory is new; logs and source hashes are retained.
"""
import argparse, hashlib, json, os, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--stage',choices=['transport','system','qctl','frontends','mem_native','mem_subsystem','axi_read','epoch','prime_window'],default='transport')
p.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
p.add_argument('--jobs',type=int,default=2)
p.add_argument('--build-root',type=Path,required=True,help='Rebuildable binaries (outside results/)')
a=p.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
build=a.build_root.resolve();build.mkdir(parents=True,exist_ok=False)
(out/'invocation.json').write_text(json.dumps({k:str(v) for k,v in vars(a).items()},indent=2))
files=[ROOT/l for l in (ROOT/'sim/filelist_program_integrated.f').read_text().splitlines() if l]
test={'transport':'program_transport_tb','system':'program_system_tb','qctl':'program_qctl_tb','frontends':'program_frontends_tb','mem_native':'program_mem_native_tb','mem_subsystem':'program_mem_subsystem_tb','axi_read':'program_axi_read_tb','epoch':'program_epoch_tb','prime_window':'program_prime_window_tb'}[a.stage]
files.append(ROOT/f'sim/program_load/{test}.sv')
(out/'sources.json').write_text(json.dumps({str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
results=[]
configs=[(64,1),(128,3),(256,3),(512,16)] if a.stage=='transport' else [(256,3)]
for width,depth in configs:
    obj=build/f'obj_{width}_{depth}';obj.mkdir()
    cmd=[a.verilator,'--cc','--exe','--main','--build','--timing','--assert','--unroll-count','8192','-Wno-fatal','-j',str(a.jobs),
         '--output-split','10000','--Mdir',str(obj),'-f','sim/filelist_program_integrated.f',
         f'sim/program_load/{test}.sv','--top-module',test]
    if a.stage=='transport':cmd += [f'-GDMA_DATA_WIDTH={width}',f'-GFIFO_DEPTH={depth}']
    # This bench selects passive SXM/VXM stream routing; the unissued ALUs
    # are not needed to exercise the real MEM/MXM top-level cone.
    if a.stage=='system':cmd+=['-O1']
    # RTL-cycle correctness tests do not need an optimized host executable.
    cmd+=['-MAKEFLAGS','OPT_FAST=-O0 OPT_SLOW=-O0']
    (out/f'command_{width}.json').write_text(json.dumps(cmd,indent=2))
    t=time.time()
    with (out/f'build_{width}.log').open('w') as log:
        r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    if r.returncode:raise RuntimeError(f'Build failed: {out}/build_{width}.log')
    for case in (range(6) if a.stage in ('transport','mem_native') else
                 range(3) if a.stage=='system' else range(2) if a.stage=='frontends' else [0]):
        r=subprocess.run([str(obj/f'V{test}'),f'+CASE={case}'],cwd=ROOT,capture_output=True,text=True,
                         timeout=600 if a.stage=='system' else 120)
        (out/f'run_{width}_{case}.log').write_text(r.stdout+r.stderr)
        ok=r.returncode==0 and 'PASS ' in r.stdout
        results.append({'width':width,'depth':depth,'case':case,'pass':ok,'seconds':round(time.time()-t,2)})
        (out/'results.json').write_text(json.dumps(results,indent=2))
        if not ok:raise RuntimeError(f'Run failed: {out}/run_{width}_{case}.log')
        print(f'PASS {a.stage} width={width} depth={depth} case={case}',flush=True)


