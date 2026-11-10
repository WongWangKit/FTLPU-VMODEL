"""Pinned actual MXM -> triangle -> native WriteTap MEM/SRF -> original VXM.
Module instruction adapters only. No ACC/collector/SRAM force or TB data shuffle.
Each format produces 32 natural matrices; consumers use normal MEM Read commands.
"""
from pathlib import Path
import subprocess,os,sys,json,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
SHA='f4dd088f8ee62e4349bc0ec7d09e38cbc9507f99'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
def get(p):return subprocess.check_output(['git','-c',f'safe.directory={R}','-C',str(R),'show',f'{SHA}:{p}']).decode()
mx=get('sim/filelist_mxm_supercell.f').splitlines()
vx=[p for p in get('sim/filelist.f').splitlines() if p.startswith('rtl/vxm/') or p in ['rtl/core/lpu_pkg.sv','rtl/core/lpu_control_pipeline.sv','rtl/core/lpu_stream_stage.sv']]
src=[]
for rel in dict.fromkeys(mx+vx):
 p=tmp/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(get(rel));src.append(p)
native=[f'rtl/srf/ftlpu_sr_{x}.sv' for x in ['superlane_col_dir','column_dir','direction_fabric','hemisphere_fabric']]
native += [f'rtl/mem_native/{x}.sv' for x in ['mem_bank_superlane_leaf','mem_bank_control_column','mem_logical_bank_column','mem_slice','mem_group']]
native += ['rtl/sxm_native/sxm_triangle_core.sv','rtl/integration/lpu_sxm_writetap_completion.sv','rtl/integration/lpu_sxm_triangle_mem_adapter.sv','rtl/integration/lpu_sxm_triangle_mem_integration.sv']
native += ['rtl/sxm_native/sxm_triangle_row_frontend.sv', 'rtl/sxm_native/sxm_compat_decode.sv', 'rtl/sxm_native/sxm_compat_engine.sv', 'rtl/sxm_native/sxm_triangle_full_core.sv', 'rtl/integration/sxm_triangle_writetap_core.sv']
for rel in native:
 p=tmp/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((R/rel).read_bytes());src.append(p)
tb=get('sim/tb/mxm/lpu_mxm_core_tb.sv')
tb=tb.replace('module lpu_mxm_core_tb #(parameter integer SCENARIO=0);','module sxm_latest_chain_tb #(parameter integer SCENARIO=1);\n  import lpu_pkg::*;\n  integer FORMAT=1;\n  initial if($value$plusargs("FP=%d",FORMAT))begin end')
tb=tb.replace('LIMIT=400','LIMIT=5000').replace('BATCH=SCENARIO==7?40:32','BATCH=512')
tb=tb.replace('if(!trace_fd)','if(trace_fd==0)').replace('if(trace_fd)','if(trace_fd!=0)').replace('if((value>>b)&1)','if(((value>>b)&1)!=0)').replace("64'(seq%2)","(64'(seq)%64'd2)").replace("64'(s%2)","(64'(s)%64'd2)")
tb=tb.replace('word_value[34]=(SCENARIO==4 && seq==3) || (SCENARIO==5 && seq==4);','word_value[34]=(FORMAT==0 && seq>=3);')
tb=tb.replace('expected_bf16=(SCENARIO==4 && tag_value<3*BATCH) || (SCENARIO==5 && tag_value>=3*BATCH);','expected_bf16=(FORMAT==0);')
tb=tb.replace('t<280','t<4*BATCH+280').replace('#100000;', '#2000000;')
tb=tb.replace('    $display("MXM_CORE_PASS', '    run=0; consume_all();\n    $display("MXM_CORE_PASS')
tb=tb.replace('endmodule',(E/'scripts/latest_chain_body.svh').read_text()+'\nendmodule')
p=tmp/'sxm_latest_chain_tb.sv';p.write_text(tb);src.append(p)
waiver=tmp/'waivers.vlt'
w=(ROOT/'learn/sxm_triangle_product_20261109/scripts/inherited_mem.vlt').read_text().replace('hier_block -module "ftlpu_sr_column_dir_lane"','')
w+='\nhier_block -module "lpu_vxm_alu"\n'
w+=(E/'scripts/latest_vxm_inherited.vlt').read_text()
for pattern in ['*/rtl/core/*','*/rtl/vxm/*']:
 w+=f'lint_off -rule TIMESCALEMOD -file "{pattern}"\n'
for rule,pattern in [('TIMESCALEMOD','*/rtl/mxm/*'),('WIDTHEXPAND','*/rtl/mxm/lpu_mxm_backend_isa_pkg.sv'),('WIDTHEXPAND','*/rtl/mxm/lpu_mxm_isa_pkg.sv'),('WIDTHEXPAND','*/rtl/mxm/lpu_mxm_backend.sv')]:w+=f'lint_off -rule {rule} -file "{pattern}"\n'
waiver.write_text(w)
obj=tmp/'obj';cmd=['/usr/local/bin/verilator','--cc','--exe','--build','--main','--timing','--hierarchical','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','sxm_latest_chain_tb','--Mdir',str(obj),str(waiver),*[str(p) for p in src]]
(out/'manifest.json').write_text(json.dumps(dict(reference=SHA,command=cmd,scope=__doc__,hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in src}),indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O1')
with (out/'build.log').open('w') as log:p=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT)
if p.returncode:raise SystemExit('latest chain build failed')
results=[]
for fp in [0,1]:
 p=subprocess.run([str(obj/'Vsxm_latest_chain_tb'),f'+FP={fp}'],capture_output=True,text=True)
 (out/f'fp{fp}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr,flush=True)
 results.append(dict(FP=fp,pass_=p.returncode==0 and 'LATEST_CHAIN_PASS' in p.stdout));(out/'summary.json').write_text(json.dumps(results,indent=2))
 if not results[-1]['pass_']:raise SystemExit('latest chain mismatch')
