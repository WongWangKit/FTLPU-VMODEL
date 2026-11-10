"""Run post-synthesis checks only after the serial Vivado queue exits."""
from pathlib import Path
import sys,json,subprocess,ctypes
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1]
sys.path.insert(0,str(ROOT/'learn/sxm_gap10_20261104/scripts'))
from host_runtime import WindowsRuntime,KeepAwake
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);prefix=sys.argv[2]
with KeepAwake(WindowsRuntime()):
 k=ctypes.WinDLL('kernel32',use_last_error=True);k.OpenProcess.restype=ctypes.c_void_p
 k.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_uint32];k.CloseHandle.argtypes=[ctypes.c_void_p]
 h=k.OpenProcess(0x100000,False,int(sys.argv[3]))
 if h:
  try:
   while k.WaitForSingleObject(h,60000)==258:pass
  finally:k.CloseHandle(h)
 results=[]
 for T in [2,4,8]:
  physical=f'{prefix}_core_t{T}_synth';run=f'{sys.argv[1]}_t{T}'
  if not (E/'results'/physical/'synthesized/synthesized.v').exists():
   results.append(dict(T=T,status='no_synthesized_netlist',pass_=False))
  else:
   cmd=[sys.executable,'-X','utf8',str(E/'scripts/run_gate.py'),run,physical]
   with (out/f't{T}.log').open('w') as f:p=subprocess.run(cmd,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT)
   results.append(dict(T=T,run=run,exit_code=p.returncode,pass_=p.returncode==0))
  (out/'summary.json').write_text(json.dumps(results,indent=2))
