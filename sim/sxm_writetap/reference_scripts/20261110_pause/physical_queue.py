"""Sequential unattended L5 matrix; never run two Vivado jobs together.
Uses same-thread system-awake lease, permits display-off, keeps stage logs.
No global power-plan edits, no broad process kills, no automatic RTL retries.
"""
from pathlib import Path
import sys,os,json,subprocess,ctypes,time,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
sys.path.insert(0,str(ROOT/'learn/sxm_gap10_20261104/scripts'))
from host_runtime import WindowsRuntime,KeepAwake
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False)
gate={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in list((R/'rtl/sxm_native').glob('sxm_triangle*.sv'))+list((R/'rtl/integration').glob('*writetap*.sv'))+[R/'rtl/integration/lpu_sxm_triangle_mem_adapter.sv']}
(out/'gate.json').write_text(json.dumps(gate,indent=2));results=[]
def call(run,T,component,*args):
 if any(hashlib.sha256(Path(p).read_bytes()).hexdigest()!=h for p,h in gate.items()):raise SystemExit('Source changed during queue; stop before mixing baselines')
 cmd=[sys.executable,'-X','utf8',str(E/'scripts/run_physical.py'),run,str(T),component,*map(str,args)]
 with (out/(run+'.log')).open('w') as log:
  print('QUEUE START',run,flush=True);p=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
 results.append(dict(run=run,T=T,component=component,exit_code=p.returncode));(out/'summary.json').write_text(json.dumps(results,indent=2))
 return p.returncode==0
with KeepAwake(WindowsRuntime()):
 if len(sys.argv)>2:
  # Open a process handle once, avoiding PID-reuse confusion while waiting.
  k=ctypes.WinDLL('kernel32',use_last_error=True);k.OpenProcess.restype=ctypes.c_void_p
  k.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_uint32];k.CloseHandle.argtypes=[ctypes.c_void_p]
  h=k.OpenProcess(0x100000,False,int(sys.argv[2]))
  if h:
   try:
    while k.WaitForSingleObject(h,60000)==258:pass
   finally:k.CloseHandle(h)
 plans=[(T,c) for c in ['adapter','core','combined'] for T in [2,4,8]]
 ready=[]
 for T,c in plans:
  run=f'{sys.argv[1]}_{c}_t{T}_synth'
  # Reuse a completed unchanged full-core mapping after a shell-only change.
  # A fresh manifest/hash check prevents accidentally accepting a stale netlist.
  if c=='adapter' or (c=='core' and T==2):
   old=E/'results'/f'l5_queue04_{c}_t{T}_synth'
   if (old/'synthesized/synthesized.dcp').exists():
    m=json.loads((old/'manifest.json').read_text())
    if m.get('synth_mode')=='structural' and all(hashlib.sha256((R/p).read_bytes()).hexdigest()==h for p,h in m['hashes'].items()):
     import shutil
     shutil.copytree(old,E/'results'/run)
     (E/'results'/run/'reused_from.json').write_text(json.dumps(dict(source=old.name,reason='all component source hashes unchanged; same synthesis configuration'),indent=2))
     results.append(dict(run=run,T=T,component=c,exit_code=0,reused_from=old.name));(out/'summary.json').write_text(json.dumps(results,indent=2))
     ready.append((T,c,run));continue
  if call(run,T,c,'--synth-only'):ready.append((T,c,run))
 for T,c,prev in ready:
  call(f'{sys.argv[1]}_{c}_t{T}_route',T,c,'--resume',E/'results'/prev/'synthesized/synthesized.dcp')
(out/'finished.json').write_text(json.dumps(dict(finished=time.time(),runs=len(results),all_commands_ok=all(x['exit_code']==0 for x in results)),indent=2))
