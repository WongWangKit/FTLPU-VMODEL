"""Migrate C814 values/maps/pairs to finite triangle-slot lifetimes.
The original 814-cycle fixed-16-slot schedule stays immutable and is not claimed
cycle-equivalent. This replacement checks both original matrices and all pairs.
"""
from pathlib import Path
import sys,json,hashlib,subprocess,importlib.util
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
sp=importlib.util.spec_from_file_location('cases',ROOT/'learn/sxm_01_03_20261104/scripts/make_cases.py');m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
gold=ROOT/'learn/sxm_fp32_native_20261102/cases/mxm.hex';mg=[int(x,16) for x in gold.read_text().split()]
a=m.Case(4,'c814_triangle_calendar');c=0
for matrix in [0,1]:
 c=a.config(c,matrix,0,True,True,matrix==1,matrix,matrix,alias=True)
 for group in range(4):
  d=(group-matrix)%4;a.reserve(c,matrix,group);c+=1
  for s in range(4):
   for r in range(8):
    a.capture(c,matrix,group,s,r,[[mg[matrix*1024+(group*8+r)*32+s*8+l] for l in range(8)]],32);c+=1
  for s in range(4):
   for q in range(0,8,2):
    seq=4*s+q//2
    a.fields(c,pv=1,pc=matrix,pd=d,ps=s,pq=q,paired=1,seq=seq)
    a.fields(c+1,run=1<<d,rc=matrix,interval=4,count=1,rs=seq)
    rows=[[mg[matrix*1024+(group*8+(7-l if matrix else l))*32+s*8+q+b] for l in range(8)] for b in range(2)]
    for ph in [0,1]:a.output(c+2+ph,d,rows,32,True,ph,True)
    c+=4
 a.at(c)['flags']=16;c+=2
cycles=a.last+4
for key in ['cmd','input','input_valid','output','output_valid','flags']:
 (tmp/(key+'.hex')).write_text(''.join(f'{a.rows.get(c,{}).get(key,0):x}\n' for c in range(cycles)))
hashes={}
for p in (E/'tmp/full07').glob('sxm_*.sv'):
 if p.name=='sxm_compatible_core_tb.sv':continue
 current=R/'rtl/sxm_native'/p.name
 assert p.read_bytes()==current.read_bytes(),'Rebuild required; shared core changed'
 hashes[str(current)]=hashlib.sha256(current.read_bytes()).hexdigest()
exe=E/'tmp/full07/t4/Vsxm_compatible_core_tb'
cmd=[str(exe),f'+CASE={tmp}',f'+CYCLES={cycles}']
(out/'manifest.json').write_text(json.dumps(dict(command=cmd,cycles=cycles,original='C814',gold_sha256=hashlib.sha256(gold.read_bytes()).hexdigest(),executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),hashes=hashes),indent=2))
p=subprocess.run(cmd,capture_output=True,text=True);(out/'run.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
ok=p.returncode==0 and 'SXM_COMPATIBLE_CORE PASS' in p.stdout
(out/'summary.json').write_text(json.dumps(dict(pass_=ok,original_matrix_words=2048,cycle_contract='replacement calendar, not original C814'),indent=2))
raise SystemExit(0 if ok else 1)

