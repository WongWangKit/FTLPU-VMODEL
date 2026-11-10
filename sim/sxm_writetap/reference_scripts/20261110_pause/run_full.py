"""Immutable legacy goldens + explicitly rescheduled row matrix functionality.
No second payload pool. Old fixed-T*T all-capture-before-P calendars are
replaced with per-group capture/P, with identical coordinate oracle values.
"""
from pathlib import Path
import subprocess,os,json,hashlib,sys,importlib.util
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
OLD=ROOT/'learn/sxm_01_03_20261104';LEG=ROOT/'learn/sxm_l3_compat_20261104'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
spec=importlib.util.spec_from_file_location('cases',OLD/'scripts/make_cases.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
cases=[]
def save(case,old_id):
 path=tmp/'cases'/case.name;path.mkdir(parents=True);cycles=case.last+4
 for key in ('cmd','input','input_valid','output','output_valid','flags'):
  (path/(key+'.hex')).write_text(''.join(f'{case.rows.get(c,{}).get(key,0):x}\n' for c in range(cycles)))
 cases.append(dict(name=case.name,T=case.T,cycles=cycles,path=str(path),compat=0,migration='rescheduled physical-slot lifetime, same values',original=old_id))
def functional(T,mode,bits,ingrain,outgrain,consume=False):
 old=f't{T}_m{mode}_{bits}_{ingrain}_{outgrain}'+('_consume' if consume else '')
 a=m.Case(T,old+'_triangle');gm={2:[1,0],4:[2,0,3,1],8:[3,0,7,4,1,6,2,5]}[T]
 c=a.config(0,0,mode,bits==32,reverse=True,direction=0,group_map=gm)
 def val(g,s,r,q):return (0x81234567+(((g*T+s)*8+r)*8+q)*0x01030107)&((1<<bits)-1)
 for group in range(T):
  a.reserve(c,0,group);c+=1
  for s in range(T):
   if ingrain=='block':a.capture(c,0,group,s,8,[[val(group,s,r,q) for q in range(8)] for r in range(8)],bits);c+=1
   else:
    for r in range(8 if mode==0 else 1):a.capture(c,0,group,s,r,[[val(group,s,r,q) for q in range(8)]],bits);c+=1
  d=gm.index(group)
  for s in range(T):
   def row(q):return [val(group,s,7-l,q) if mode==0 else val(group,s,0,7-l if mode==1 else q) for l in range(8)]
   if outgrain=='block':a.fields(c,pv=1,pd=d,ps=s,pq=8);a.output(c,d,[row(q) for q in range(8)],bits);c+=1
   else:
    for q in ([0] if mode==1 else ([2] if consume else range(8))):
     a.fields(c,pv=1,pd=d,ps=s,pq=q+9 if consume else q);a.fields(c+1,run=1<<d,interval=4,count=1);a.output(c+2,d,[row(q)],bits);c+=3
 a.at(c)['flags']=16;save(a,old)
for entry in json.loads((OLD/'cases/index.json').read_text()):
 name=entry['name']
 if name=='c814':continue # A separate current calendar test owns this replaced schedule.
 if name.split('_')[1] in ('m0','m1','m2'):
  parts=name.split('_');functional(entry['T'],int(parts[1][1:]),int(parts[2]),parts[3],parts[4],name.endswith('_consume'))
 else:cases.append(dict(**entry,path=str(OLD/'cases'/name),compat=0,migration='unchanged golden'))
for entry in json.loads((LEG/'cases/index.json').read_text()):
 if entry['name'].endswith('legacy_row_legacy'):
  T=entry['T'];oldpath=LEG/'cases'/entry['name'];start=T+1
  oldlen=len((OLD/'cases'/f't{T}_m0_32_row_row'/'cmd.hex').read_text().split())
  middle=next(x for x in cases if x.get('original')==f't{T}_m0_32_row_row');newlen=middle['cycles']
  path=tmp/'cases'/entry['name'];path.mkdir(parents=True)
  for f in oldpath.glob('*.hex'):
   old=[int(x,16) for x in f.read_text().split()];mf=Path(middle['path'])/f.name
   mid=[int(x,16) for x in mf.read_text().split()] if mf.exists() else [0]*newlen
   if f.stem in ('raw_p','legacy'):mid[T+3]=old[start+T+3]
   if f.stem=='flags':mid[T+3]|=8<<8
   values=old[:start]+mid+old[start+oldlen:]
   (path/f.name).write_text(''.join(f'{x:x}\n' for x in values))
  cases.append(dict(**{**entry,'cycles':entry['cycles']-oldlen+newlen},path=str(path),compat=1,migration='only embedded old fixed-pool ROW calendar rescheduled; raw timing unchanged'))
 else:cases.append(dict(**entry,path=str(LEG/'cases'/entry['name']),compat=1,migration='unchanged golden'))
tb=(R/'sim/tb/sxm_row/sxm_compatible_core_tb.sv').read_text()
tb=tb.replace('sxm_compatible_core #(', 'sxm_triangle_full_core #(')
tb=tb.replace('  string path;', "  wire [T*2048-1:0] batch_zero;\n  for(genvar bz=0;bz<T*32;bz++)assign batch_zero[bz*64+:64]=64'b0;\n  string path;")
tb=tb.replace('.compat_t_raw_i(tcmd),.compat_p_raw_i(pcmd),.compat_fault_o);', '''.compat_t_raw_i(tcmd),.compat_p_raw_i(pcmd),.compat_fault_o,
    .batch_job_i(1'b0),.batch_mode_i(2'b0),.batch_dtype_i(2'b0),.batch_count_i(16'b0),.batch_lane_map_i('0),.batch_tile_map_i('0),
    .batch_ready_o(),.batch_fault_o(),.batch_cap_valid_i('0),.batch_lane_valid_i('0),.batch_cap_data_i(batch_zero),.batch_cap_accept_o(),
    .batch_block_ready_i('0),.batch_block_valid_o(),.batch_block_fp32_o(),.batch_block_vector_o(),.batch_block_data_o(),.batch_block_matrix_o(),.batch_block_column_o());''')
test=tmp/'sxm_compatible_core_tb.sv';test.write_text(tb)
src=[R/f'rtl/sxm_native/{n}.sv' for n in ['sxm_triangle_core','sxm_triangle_row_frontend','sxm_compat_decode','sxm_compat_engine','sxm_triangle_full_core']]+[test]
snap=[]
for p in src[:-1]:q=tmp/p.name;q.write_bytes(p.read_bytes());snap.append(q)
snap.append(test)
(out/'manifest.json').write_text(json.dumps(dict(hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in src},cases=cases),indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0');results=[]
for T in [2,4,8]:
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','sxm_compatible_core_tb',f'-GT={T}','--Mdir',str(obj),*[str(p) for p in snap]]
 with (out/f'build_t{T}.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit(f'build T{T} failed')
 for case in [x for x in cases if x['T']==T]:
  p=subprocess.run([str(obj/'Vsxm_compatible_core_tb'),f'+CASE={case["path"]}',f'+CYCLES={case["cycles"]}',f'+COMPAT={case["compat"]}'],capture_output=True,text=True)
  (out/(case['name']+'.log')).write_text(p.stdout+p.stderr);rec=dict(**case,pass_=p.returncode==0 and 'SXM_COMPATIBLE_CORE PASS' in p.stdout);results.append(rec)
  print(case['name'],rec['pass_'],flush=True)
  (out/'summary.json').write_text(json.dumps(dict(results=results,passed=sum(x['pass_'] for x in results),total=len(results)),indent=2))
  if not rec['pass_']:print(p.stdout+p.stderr,flush=True)
if not all(x['pass_'] for x in results):raise SystemExit('regression failures')
