"""Seven retained combinations at 32 physical byte streams, shared triangle pool."""
from pathlib import Path
import ast,subprocess,os,sys,json,hashlib,importlib.util
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL';OLD=ROOT/'learn/sxm_01_03_20261104'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
sp=importlib.util.spec_from_file_location('cases',OLD/'scripts/make_cases.py');m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
cases=[]
class WideCase(m.Case):
 def capture(self,c,cx,a,s,r,rows,bits):
  self.fields(c,cap=1,cc=cx,ct=s,ca=a,cr=r)
  for ri,row in enumerate(rows):
   for p in range(bits//8):
    idx=s*32+ri*(bits//8)+p;self.at(c)['input_valid']|=1<<idx
    self.at(c)['input']|=sum(((x>>(8*p))&255)<<(l*8) for l,x in enumerate(row))<<(idx*64)
 def output(self,c,d,rows,bits,mirror=False,phase=0,alias=False):
  for branch,row in enumerate(rows):
   for p in range(2 if mirror else bits//8):
    idx=d*32+branch*(2 if mirror else bits//8)+p
    word=sum(((x>>(16*phase+8*p if mirror else 8*p))&255)<<(l*8) for l,x in enumerate(row))
    self.at(c)['output_valid']|=1<<idx;self.at(c)['output']|=word<<(idx*64)
    if alias:self.at(c)['output_valid']|=1<<(idx+4);self.at(c)['output']|=word<<((idx+4)*64)
m.Case=WideCase
source=(E/'scripts/run_full.py').read_text();tree=ast.parse(source)
for node in tree.body:
 if isinstance(node,ast.FunctionDef) and node.name in ('save','functional'):exec(compile(ast.Module(body=[node],type_ignores=[]),str(E/'scripts/run_full.py'),'exec'))
for T in [2,4,8]:
 for bits in [16,32]:
  for mode,ig,og in [(0,'row','row'),(0,'row','block'),(0,'block','row'),(0,'block','block'),(1,'row','row'),(2,'row','row'),(2,'row','block')]:functional(T,mode,bits,ig,og)
  a=WideCase(T,f't{T}_vector_tail_{bits}');c=a.config(0,0,1,bits==32,reverse=True,direction=1)
  for frag in range(3*T+1):
   s=frag%T;row=[(0x3f000001+frag*0x10203+l*0x10405)&((1<<bits)-1) for l in range(8)]
   a.fields(c,cv=1,op=3,data=1<<s);a.capture(c+1,0,0,s,0,[row],bits)
   a.fields(c+2,pv=1,pd=0,ps=s,pq=0);a.fields(c+3,run=1,interval=4,count=1);a.output(c+4,0,[list(reversed(row))],bits);c+=5
  a.at(c)['flags']=16;save(a,'new 3*T+1 fragments, no padded rows')
 a=WideCase(T,f't{T}_full_block_mirror_pairs');c=a.config(0,0,0,True,mirror=True,alias=True)
 a.fields(c,cv=1,op=3,data=1);c+=1
 vals=[[0x3f800001+(r*8+l)*0x10007 for l in range(8)] for r in range(8)]
 a.capture(c,0,0,0,8,vals,32);c+=1
 for q in [0,2,4,6]:
  a.fields(c,pv=1,pq=q,paired=1,seq=q//2);a.fields(c+1,run=1,interval=4,count=1,rs=q//2)
  rows=[[vals[l][q+b] for l in range(8)] for b in range(2)]
  for ph in [0,1]:a.output(c+2+ph,0,rows,32,True,ph,True)
  c+=4
 a.at(c)['flags']=16;save(a,'unchanged FP32 P-pair/RUN two-phase effective timing')
tb=(E/'tmp/full03/sxm_compatible_core_tb.sv').read_text().replace('PORT_STREAMS=16','PORT_STREAMS=32')
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
  p=subprocess.run([str(obj/'Vsxm_compatible_core_tb'),f'+CASE={case["path"]}',f'+CYCLES={case["cycles"]}'],capture_output=True,text=True)
  (out/(case['name']+'.log')).write_text(p.stdout+p.stderr);rec=dict(**case,pass_=p.returncode==0 and 'SXM_COMPATIBLE_CORE PASS' in p.stdout);results.append(rec)
  print(case['name'],rec['pass_'],flush=True)
  (out/'summary.json').write_text(json.dumps(dict(results=results,passed=sum(x['pass_'] for x in results),total=len(results)),indent=2))
  if not rec['pass_']:print(p.stdout+p.stderr,flush=True)
if not all(x['pass_'] for x in results):raise SystemExit('wide regression failures')
