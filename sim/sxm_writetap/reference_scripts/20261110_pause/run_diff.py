"""Ten immutable old valid-interface cycle differentials against the full pool.
Historical reference RTL keeps its original issue register/latency. This is a
compatibility test, not the latest MXM/VXM baseline or a reference lint signoff.
"""
from pathlib import Path
import sys,os,json,hashlib,subprocess
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL';OLD=ROOT/'learn/sxm_l3_compat_20261104'
VM=ROOT/'learn/sxm_remote_baseline_20261102/tmp/20261102_01/vmodel'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
tb=(R/'sim/tb/sxm_row/sxm_compat_diff_tb.sv').read_text()
full=(E/'tmp/full04/sxm_compatible_core_tb.sv').read_text()
a=tb.index('  sxm_compatible_core #(');b=tb.index('  reg ref_tv=',a)
fa=full.index('  sxm_triangle_full_core #(');fb=full.index('  string path;',fa)
tb=tb[:a]+'  localparam integer PORT_STREAMS=16;\n'+full[fa:fb]+tb[b:]
p=tmp/'sxm_compat_diff_tb.sv';p.write_text(tb)
src=[VM/x for x in ['rtl/core/lpu_pkg.sv','rtl/core/lpu_control_pipeline.sv','rtl/sxm/lpu_sxm_control.sv','rtl/sxm/lpu_sxm_slice.sv']]
src += [R/f'rtl/sxm_native/{n}.sv' for n in ['sxm_command_decode','sxm_transpose_superlane_leaf','sxm_transpose_control_column','sxm_transpose_result_buffer_array','sxm_permute_engine','sxm_slice','sxm_triangle_core','sxm_triangle_row_frontend','sxm_compat_decode','sxm_compat_engine','sxm_triangle_full_core']]
src += [R/'rtl/integration/lpu_sxm_command_adapter.sv']
hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in src};snap=[]
for s in src:q=tmp/s.name;q.write_bytes(s.read_bytes());snap.append(q)
snap.append(p)
cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','-Wno-fatal','--unroll-count','4096','--unroll-stmts','1000000','--top-module','sxm_compat_diff_tb','--Mdir',str(tmp/'obj'),*[str(p) for p in snap]]
(out/'manifest.json').write_text(json.dumps(dict(command=cmd,hashes=hashes,scope=__doc__),indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0')
with (out/'build.log').open('w') as f:subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
results=[]
for c in json.loads((OLD/'cases/index.json').read_text()):
 if 'differential' not in c:continue
 p=subprocess.run([str(tmp/'obj/Vsxm_compat_diff_tb'),f'+CASE={OLD/"cases"/c["name"]}',f'+CYCLES={c["cycles"]}','+COMPAT=1',f'+NATIVE={int(c["differential"]=="both")}'],capture_output=True,text=True)
 (out/(c['name']+'.log')).write_text(p.stdout+p.stderr);ok=p.returncode==0 and 'SXM_COMPAT_DIFF PASS' in p.stdout
 results.append(dict(name=c['name'],pass_=ok));print(c['name'],ok,flush=True)
 (out/'summary.json').write_text(json.dumps(results,indent=2))
 if not ok:raise SystemExit('old cycle differential failed')
