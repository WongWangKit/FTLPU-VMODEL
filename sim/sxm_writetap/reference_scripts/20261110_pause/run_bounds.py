"""Preserved maximum ROW delay/count/sequence, last-CAP edge and reset."""
from pathlib import Path
import sys,os,json,subprocess,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
tb=(R/'sim/tb/sxm_row/sxm_row_bounds_tb.sv').read_text();full=(E/'tmp/full04/sxm_compatible_core_tb.sv').read_text()
a=tb.index('  sxm_row_core #(');b=tb.index('  integer d,r,l',a);fa=full.index('  sxm_triangle_full_core #(');fb=full.index('  string path;',fa)
extra='''  localparam integer PORT_STREAMS=16,RAW_BITS=((240+8*T*(T<4?5:$clog2(8*T))+8+(T<4?3:$clog2(T)+1)+31)/32)*32;
  wire [3:0] compat_fault_o;reg [5:0] lc=0;reg [RAW_BITS-1:0] tcmd=0,pcmd=0;
'''
body=tb[b:].replace('dut.','dut.u_core.').replace('2048*T*T','2048*T*(T+1)/2').replace('(19+$clog2(T))*T*T','(19+$clog2(T))*T*(T+1)/2')
tb=tb[:a]+extra+full[fa:fb]+body
p=tmp/'sxm_row_bounds_tb.sv';p.write_text(tb);src=[]
for n in ['sxm_triangle_core','sxm_triangle_row_frontend','sxm_compat_decode','sxm_compat_engine','sxm_triangle_full_core']:
 s=R/f'rtl/sxm_native/{n}.sv';q=tmp/s.name;q.write_bytes(s.read_bytes());src.append(q)
src.append(p);(out/'manifest.json').write_text(json.dumps({str(s):hashlib.sha256(s.read_bytes()).hexdigest() for s in src},indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0');results=[]
for T in [2,4,8]:
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','sxm_row_bounds_tb',f'-GT={T}','--Mdir',str(obj),*[str(p) for p in src]]
 with (out/f'build_t{T}.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit('bounds build failed')
 p=subprocess.run([str(obj/'Vsxm_row_bounds_tb')],capture_output=True,text=True);(out/f't{T}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr,flush=True)
 results.append(dict(T=T,pass_=p.returncode==0 and 'SXM_ROW_BOUNDS PASS' in p.stdout));(out/'summary.json').write_text(json.dumps(results,indent=2))
 if not results[-1]['pass_']:raise SystemExit('bounds failed')
