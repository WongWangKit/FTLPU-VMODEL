from pathlib import Path
import subprocess,os,json,hashlib,sys
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
run=sys.argv[1];out=E/'results'/run;out.mkdir(exist_ok=False);tmp=E/'tmp'/run;tmp.mkdir(parents=True,exist_ok=False)
src=[R/f'rtl/srf/ftlpu_sr_{x}.sv' for x in ['superlane_col_dir','column_dir','direction_fabric','hemisphere_fabric']]
src += [R/f'rtl/mem_native/{x}.sv' for x in ['mem_bank_superlane_leaf','mem_bank_control_column','mem_logical_bank_column','mem_slice','mem_group']]
src += [R/'rtl/sxm_native/sxm_triangle_core.sv',R/'rtl/integration/lpu_sxm_writetap_completion.sv',R/'rtl/integration/lpu_sxm_triangle_mem_adapter.sv',R/'rtl/integration/lpu_sxm_triangle_mem_integration.sv',R/'sim/tb/sxm_triangle/sxm_writetap_mem_tb.sv']
src += [R/p for p in ['rtl/sxm_native/sxm_triangle_row_frontend.sv', 'rtl/sxm_native/sxm_compat_decode.sv', 'rtl/sxm_native/sxm_compat_engine.sv', 'rtl/sxm_native/sxm_triangle_full_core.sv', 'rtl/integration/sxm_triangle_writetap_core.sv']]
snap=[];hashes={}
for p in src:
 q=tmp/p.relative_to(R);q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(p.read_bytes());snap.append(q);hashes[str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
(out/'manifest.json').write_text(json.dumps(hashes,indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O1')
waiver=tmp/'mem.vlt';waiver.write_text((ROOT/'learn/sxm_triangle_product_20261109/scripts/inherited_mem.vlt').read_text().replace('hier_block -module "ftlpu_sr_column_dir_lane"',''))
results=[]
full_geometry='full' in sys.argv
if full_geometry:sys.argv.remove('full')
delta=sys.argv[-1]=='delta'
if delta:sys.argv.pop()
smoke='smoke' in sys.argv
if smoke:sys.argv.remove('smoke')
closure='closure' in sys.argv
if closure:sys.argv.remove('closure')
if closure:
 # Test-only command interposition, never a payload shuffle or product fallback.
 # Single faulted net feeds both native MEM and the unchanged completion logic.
 p=tmp/'rtl/integration/sxm_triangle_writetap_core.sv';s=p.read_text()
 old='.stream_valid_o,.stream_data_o,.mem_issue_valid_o,.mem_issue_o,.target_tap_o'
 assert s.count(old)==1
 s=s.replace(old,'.stream_valid_o,.stream_data_o,.mem_issue_valid_o(test_wi),.mem_issue_o(test_wc),.target_tap_o')
 hook=''' reg test_drop_root=0,test_bad_address=0;
 wire [31:0] test_wi;wire [1023:0] test_wc;
 assign mem_issue_valid_o=test_wi & (test_drop_root?32'hffffff00:32'hffffffff);
 assign mem_issue_o={test_wc[1023:30],(test_bad_address?15'd1023:test_wc[29:15]),test_wc[14:0]};
'''
 s=s.replace(' lpu_sxm_triangle_mem_adapter #',hook+' lpu_sxm_triangle_mem_adapter #');p.write_text(s)
 (out/'fault_instrumentation.json').write_text(json.dumps(dict(file=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),scope='command root only; two test controls; no payload/clock/state modifications'),indent=2))
for T in ([int(x) for x in sys.argv[2:]] or [4,2,8]):
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','sxm_writetap_mem_tb',f'-GT={T}','--Mdir',str(obj),str(waiver),*[str(p) for p in snap]]
 if full_geometry:cmd+=['-GCOLUMNS=16','-GLEFT=12']
 if closure:cmd+=['+define+SXM_FAULT_INJECTION']
 (out/f'command_t{T}.json').write_text(json.dumps(cmd,indent=2));print('BUILD',T,flush=True)
 # No wall-clock timeout here: the Windows parent owns an awake-time deadline.
 with (out/f'build_t{T}.log').open('w') as log:p=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit(f'build T{T} failed')
 configs=[dict(FP=f,N=n,MAP=0,NEG=0) for f in [0,1] for n in ([2] if delta else [1,2,3,32,100])]
 configs += [dict(FP=f,N=3,MAP=1,NEG=0) for f in [0,1]]
 configs += [dict(FP=1,N=2,MAP=0,NEG=n) for n in range(1,10)]
 configs += [dict(FP=0,N=2,MAP=0,NEG=0,SECOND=1),dict(FP=1,N=3,MAP=1,NEG=0,SCRAMBLE=1)]
 if full_geometry:configs=[dict(FP=f,N=2,MAP=0,NEG=0) for f in [0,1]]
 if smoke:configs=[dict(FP=f,N=2,MAP=1,NEG=0) for f in [0,1]]
 if closure:configs=[dict(FP=f,N=2,MAP=0,NEG=0) for f in [0,1]]+[dict(FP=1,N=2,MAP=0,NEG=n) for n in [10,11]]
 for cfg in configs:
   p=subprocess.run([str(obj/'Vsxm_writetap_mem_tb'),*[f'+{k}={v}' for k,v in cfg.items()]],capture_output=True,text=True)
   name=f't{T}_'+ '_'.join(f'{k}{v}' for k,v in cfg.items());(out/(name+'.log')).write_text(p.stdout+p.stderr)
   rec=dict(T=T,**cfg,pass_=p.returncode==0 and 'PASS WRITETAP' in p.stdout,output=p.stdout+p.stderr);results.append(rec);print(rec,flush=True)
   (out/'summary.json').write_text(json.dumps(results,indent=2))
   if not rec['pass_']:raise SystemExit('RTL mismatch')

