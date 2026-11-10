"""Frozen-source sequential Vivado checkpoints with task-scoped sleep guard.
Existing SRAM/SRF not re-synthesized as new SXM storage. No automatic RTL retry.
"""
from pathlib import Path
import argparse,os,sys,json,hashlib,shutil,time
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
sys.path.insert(0,str(ROOT/'learn/sxm_gap10_20261104/scripts'))
from host_runtime import run_command
ap=argparse.ArgumentParser();ap.add_argument('run');ap.add_argument('T',type=int,choices=[2,4,8]);ap.add_argument('component',choices=['core','adapter','combined']);ap.add_argument('--synth-only',action='store_true');ap.add_argument('--resume',type=Path);ap.add_argument('--stage',default='synthesized');ap.add_argument('--timeout',type=int,default=43200);ap.add_argument('--synth-mode',choices=['structural','default'],default='structural')
a=ap.parse_args();base=E/'results'/a.run;base.mkdir(parents=True,exist_ok=False);work=E/'tmp'/a.run;work.mkdir(parents=True,exist_ok=False);src=work/'src';src.mkdir()
core=['rtl/sxm_native/'+n+'.sv' for n in ['sxm_triangle_core','sxm_triangle_row_frontend','sxm_compat_decode','sxm_compat_engine','sxm_triangle_full_core']]
shell=['rtl/integration/'+n+'.sv' for n in ['lpu_sxm_triangle_mem_adapter','lpu_sxm_writetap_completion','lpu_sxm_writetap_shell']]
files=core if a.component=='core' else shell if a.component=='adapter' else core+shell+['rtl/integration/sxm_triangle_writetap_core.sv']
top={'core':'sxm_triangle_full_core','adapter':'lpu_sxm_writetap_shell','combined':'sxm_triangle_writetap_core'}[a.component]
hashes={}
for rel in files:
 p=R/rel;(src/p.name).write_bytes(p.read_bytes());hashes[rel]=hashlib.sha256(p.read_bytes()).hexdigest()
(src/'rtl_files.txt').write_text('\n'.join(Path(p).name for p in files))
for name in ['physical.tcl','timing.xdc','io_budget.tcl']:(src/name).write_bytes((E/'scripts'/name).read_bytes())
manifest=dict(T=a.T,component=a.component,top=top,hashes=hashes,synth_mode=a.synth_mode,part='xcvu9p-flga2104-2L-e',period_ns=10,scope='internal signoff; IO budget separate',clock='QueryUnbiasedInterruptTime',display_required=False)
(base/'manifest.json').write_text(json.dumps(manifest,indent=2))
env=dict(os.environ);overlay=ROOT/'learn/sxm_gap10_20261104/tmp/vendor_overlay_01'
installed=Path('<USER_HOME>/Desktop/Vivado2023/Vivado/2023.2')
if overlay.exists():
 vendor={}
 for p in (installed/'scripts').rglob('*'):
  if p.is_file():
   q=overlay/p.relative_to(installed);h=hashlib.sha256(p.read_bytes()).hexdigest();assert q.is_file() and hashlib.sha256(q.read_bytes()).hexdigest()==h
   vendor[str(p.relative_to(installed))]=h
 (base/'vendor_hashes.json').write_text(json.dumps(vendor,indent=2));env['XILINX_PATH']=overlay.as_posix();env['SYNTH_COMMON']=(overlay/'scripts/rt/data').as_posix()
v=(installed/'bin/vivado.bat').as_posix();previous=a.resume;previous_stage=a.stage
stages=['synthesized'] if a.synth_only else ['synthesized','placed','physopt','routed']
if previous:
 old=json.loads((previous.parent.parent/'manifest.json').read_text())
 assert old['hashes']==hashes and old['T']==a.T and old['component']==a.component and old.get('synth_mode','default')==a.synth_mode, 'resume source/config mismatch'
 stages=stages[stages.index(previous_stage)+1:]
results=[]
for stage in stages:
 out=base/stage;out.mkdir();stage_work=work/stage;stage_work.mkdir()
 cmd=[v,'-mode','batch','-nojournal','-log',(out/'vivado.log').as_posix(),'-source',(src/'physical.tcl').as_posix(),'-tclargs',src.as_posix(),out.as_posix(),str(a.T),stage_work.as_posix(),previous.resolve().as_posix() if previous else 'none',a.synth_mode,previous_stage,'BUFGCE_X0Y120','Default',stage,'1','internal',top]
 (out/'command.json').write_text(json.dumps(cmd,indent=2));print('START',a.run,stage,flush=True)
 rc,status=run_command(cmd,out=out,work=stage_work,env=env,timeout=a.timeout,poll_seconds=20)
 checkpoint=out/(stage+'.dcp');ok=rc==0 and checkpoint.exists()
 results.append(dict(stage=stage,status=status,exit_code=rc,checkpoint=str(checkpoint),completed=ok));(base/'summary.json').write_text(json.dumps(results,indent=2))
 if not ok:raise SystemExit('Vivado stage incomplete; retained logs, no blind retry')
 previous=checkpoint;previous_stage=stage
if not a.synth_only:
 out=base/'io';out.mkdir();cmd=[v,'-mode','batch','-nojournal','-log',(out/'vivado.log').as_posix(),'-source',(src/'io_budget.tcl').as_posix(),'-tclargs',(base/'routed').as_posix(),(src/'timing.xdc').as_posix(),'BUFGCE_X0Y120','1']
 rc,status=run_command(cmd,out=out,work=work,env=env,timeout=a.timeout)
 if rc:raise SystemExit('IO budget analysis incomplete')
if not a.synth_only:
 from physical_acceptance import inspect
 result=inspect(base,a.resume.parent.parent if a.resume else None)
 print('ACCEPTANCE',result,flush=True)
 if not result['pass_']:raise SystemExit('Physical evidence complete but signoff failed; no PASS claim')
print('COMPLETED',a.run,flush=True)
