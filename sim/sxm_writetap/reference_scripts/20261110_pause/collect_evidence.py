"""Read-only evidence index. Missing/incomplete jobs stay incomplete, never PASS.
Usage: python collect_evidence.py NEW_RUN [physical_queue_prefix] [gate_prefix]
"""
from pathlib import Path
import json,sys,re,csv,hashlib,datetime
E=Path(__file__).resolve().parents[1];R=E.parents[1]/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False)
queue=sys.argv[2] if len(sys.argv)>2 else 'l5_queue05'
gate=sys.argv[3] if len(sys.argv)>3 else 'gate_queue04'
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
expected={'model01':42,'full07':247,'c814_04':1,'wide04':51,'core_reg03':111,'switch03':3,
 'bounds01':3,'diff03':10,'cmodel01':105,'admission01':3,'sim_final02':45,
 'full_geometry01':2,'sim02':30,'latest_chain05':2,'pack_eq04':12,'count_eq02':3,'sim_smoke01':6,'sim_smoke02':2,'closure05':4}
functional=[]
for run,total in expected.items():
 p=E/'results'/run/'summary.json'
 rec=dict(run=run,expected=total,summary_sha256=sha(p) if p.exists() else None)
 if not p.exists():rec.update(status='not_finished',pass_=False)
 else:
  j=read(p)
  if run=='model01':
   rows=j['runs'];negative=next(v for k,v in j.items() if k!='runs' and isinstance(v,list))
   n=len(rows)+len(negative);passed=sum(x['status']=='PASS_MODEL' for x in rows)+sum(x['rejected'] for x in negative)
  elif isinstance(j,list):n=len(j);passed=sum(x.get('pass_',x.get('pass',False)) for x in j)
  elif 'passed' in j and 'total' in j:n=j['total'];passed=j['passed']
  elif 'pass_' in j:n=1;passed=int(j['pass_'])
  else:n=None;passed=None
  rec.update(observed=n,passed=passed,pass_=total is not None and n==total and passed==total)
  rec['status']='pass' if rec['pass_'] else 'inspect_model_schema' if total is None else 'not_closed'
 functional.append(rec)

def utilization(p):
 if not p.exists():return {}
 s=p.read_text(errors='replace');r={}
 for key,term in [('LUT','CLB LUTs*'),('FF','CLB Registers'),('LUTRAM','LUT as Memory'),('BRAM','Block RAM Tile'),('DSP','DSPs'),('latch','Register as Latch')]:
  m=re.search(r'\|\s*'+re.escape(term)+r'\s*\|\s*([\d,.]+)',s)
  if m:r[key]=float(m[1].replace(',',''))
 return r
physical=[]
for c in ['core','adapter','combined']:
 for T in [2,4,8]:
  synth=E/'results'/f'{queue}_{c}_t{T}_synth';route=E/'results'/f'{queue}_{c}_t{T}_route'
  rec=dict(T=T,component=c,synth_run=synth.name,route_run=route.name,synth=utilization(synth/'synthesized/synth_utilization.rpt'),routed=utilization(route/'routed/routed_utilization.rpt'))
  a=route/'acceptance.json';rec['acceptance']=read(a) if a.exists() else dict(pass_=False,status='not_finished')
  rt=synth/'synthesized/runtime.json'
  if rt.exists():rec['synth_runtime']=read(rt)
  report=route/'routed/io_budget_timing.rpt'
  if report.exists():
   # Whole-design timing under IO budgets; internal-only acceptance stays separate.
   s=report.read_text(errors='replace');m=re.search(r'WNS\(ns\).*?\n\s*-.*?\n\s*([-\d.]+)\s+[-\d.]+\s+\d+\s+\d+\s+([-\d.]+)',s,re.S)
   rec['io_budget']=dict(WNS_ns=float(m[1]),WHS_ns=float(m[2])) if m else dict(status='inspect_report')
  physical.append(rec)
gates=[]
for T in [2,4,8]:
 p=E/'results'/f'{gate}_t{T}'/'summary.json';j=read(p) if p.exists() else []
 gates.append(dict(T=T,run=f'{gate}_t{T}',observed=len(j),passed=sum(x['pass_'] for x in j),pass_=len(j)==10 and all(x['pass_'] for x in j)))
result=dict(created=datetime.datetime.now().astimezone().isoformat(),script_sha256=sha(Path(__file__)),functional=functional,physical=physical,post_synth=gates,
 l5_pass=all(x['acceptance']['pass_'] for x in physical) and all(x['pass_'] for x in gates))
(out/'summary.json').write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
with (out/'resources.csv').open('w',newline='',encoding='utf-8-sig') as f:
 fields=['component','T','synth_LUT','synth_FF','routed_LUT','routed_FF','BRAM','DSP','setup_ns','hold_ns','accepted']
 w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
 for r in physical:w.writerow(dict(component=r['component'],T=r['T'],synth_LUT=r['synth'].get('LUT'),synth_FF=r['synth'].get('FF'),routed_LUT=r['routed'].get('LUT'),routed_FF=r['routed'].get('FF'),BRAM=r['routed'].get('BRAM'),DSP=r['routed'].get('DSP'),setup_ns=r['acceptance'].get('setup_ns'),hold_ns=r['acceptance'].get('hold_ns'),accepted=r['acceptance']['pass_']))
print(json.dumps(dict(l5_pass=result['l5_pass'],functional=functional),ensure_ascii=False,indent=2))
