from pathlib import Path
import subprocess,os,json,sys,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(exist_ok=False)
src=[R/'rtl/sxm_native/sxm_triangle_core.sv',R/'sim/tb/sxm_triangle/sxm_triangle_core_tb.sv']
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0')
(out/'manifest.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in src},indent=2));results=[]
for T in (2,4,8):
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','sxm_triangle_core_tb',f'-GT={T}','--Mdir',str(obj),*[str(p) for p in src]]
 with (out/f'build_t{T}.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit(f'build T{T} failed')
 configs=[dict(MODE=m,FP=f,N=n,NEG=0) for m in range(4) for f in range(2) for n in (1,2,32,100)]
 configs += [dict(MODE=1,FP=1,N=1,NEG=n) for n in range(1,6)]
 for cfg in configs:
  p=subprocess.run([str(obj/'Vsxm_triangle_core_tb'),*[f'+{k}={v}' for k,v in cfg.items()]],capture_output=True,text=True)
  name=f't{T}_'+ '_'.join(f'{k}{v}' for k,v in cfg.items());(out/(name+'.log')).write_text(p.stdout+p.stderr)
  results.append(dict(T=T,**cfg,pass_=p.returncode==0 and 'PASS CORE' in p.stdout))
  (out/'summary.json').write_text(json.dumps(results,indent=2))
  if not results[-1]['pass_']:print(p.stdout+p.stderr);raise SystemExit('core mismatch')
 print('CORE',T,len(configs),'PASS',flush=True)
