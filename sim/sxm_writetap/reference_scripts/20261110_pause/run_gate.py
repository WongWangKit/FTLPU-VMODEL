"""Small functional netlist regression against the exact full-core DCP/netlist."""
from pathlib import Path
import sys,json,hashlib,re,shutil,os
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1]
sys.path.insert(0,str(ROOT/'learn/sxm_gap10_20261104/scripts'))
from host_runtime import run_command
V=Path('<USER_HOME>/Desktop/Vivado2023/Vivado/2023.2/bin')
run,physical=sys.argv[1:3];p=E/'results'/physical;m=json.loads((p/'manifest.json').read_text());T=m['T'];assert m['component']=='core'
out=E/'results'/run;out.mkdir(exist_ok=False);tmp=E/'tmp'/run;tmp.mkdir(parents=True,exist_ok=False)
net=p/'synthesized/synthesized.v';shutil.copy2(net,tmp/'synthesized.v')
s=(E/'tmp/wide02/sxm_compatible_core_tb.sv').read_text().replace('T=4, PORT_STREAMS=32',f'T={T}, PORT_STREAMS=32')
s=s.replace('sxm_triangle_full_core #(.T(T),.PORT_STREAMS(PORT_STREAMS)) dut(', 'sxm_triangle_full_core dut(')
# xvlog requires explicit net declarations before their first port connection.
s=s.replace('  wire [T*2048-1:0] batch_zero;\n','')
s=s.replace('  sxm_triangle_full_core dut(', '  wire [T*2048-1:0] batch_zero;\n  sxm_triangle_full_core dut(')
s=re.sub(r'    control_bits=\$bits.*?repeat\(2\) @\(negedge clk_i\);','    // Vendor GSR startup only; stimulus calendar unchanged.\n    repeat(22) @(negedge clk_i);',s,flags=re.S)
s=s.replace('[0:16383]','[0:4095]');(tmp/'gate_tb.sv').write_text(s);(tmp/'run.tcl').write_text('run all\nquit\n')
wide=json.loads((E/'results/wide02/summary.json').read_text())['results'];full=json.loads((E/'results/full04/summary.json').read_text())['results']
names=[f't{T}_m0_{b}_row_row_triangle' for b in [16,32]]+[f't{T}_vector_tail_{b}' for b in [16,32]]+[f't{T}_full_block_mirror_pairs',f't{T}_m0_32_block_block_triangle']
cases=[dict(c) for c in wide if c['name'] in names];assert len(cases)==6
for tail in ['compat_block_block_dir0','compat_block_block_dir1','negative_missing_plane','compat_arbitration_and_reset']:
 c=dict(next(c for c in full if c['name']==f't{T}_{tail}'));dest=tmp/'cases'/c['name'];dest.mkdir(parents=True)
 widths={'input':64,'output':64,'input_valid':1,'output_valid':1,'consume':1,'read_sel':6,'write_sel':6}
 for f in Path(c['path'].replace('/mnt/c/','C:/')).glob('*.hex'):
  vals=[int(x,16) for x in f.read_text().split()]
  if f.stem in widths:
   w=widths[f.stem];mask=(1<<(16*w))-1
   vals=[sum(((v>>(t*16*w))&mask)<<(t*32*w) for t in range(T)) for v in vals]
  (dest/f.name).write_text(''.join(f'{v:x}\n' for v in vals))
 c['path']=dest.as_posix();cases.append(c)
for c in cases:c['path']=c['path'].replace('/mnt/c/','C:/')
(out/'manifest.json').write_text(json.dumps(dict(physical=physical,cases=cases,netlist_sha256=hashlib.sha256(net.read_bytes()).hexdigest(),tb_sha256=hashlib.sha256((tmp/'gate_tb.sv').read_bytes()).hexdigest()),indent=2))
def execute(name,cmd):
 stage=out/name;stage.mkdir();(stage/'command.json').write_text(json.dumps(cmd,indent=2))
 rc,status=run_command(cmd,out=stage,work=tmp,env=dict(os.environ),timeout=43200)
 if rc:raise SystemExit(f'netlist {name} {status}: {rc}')
 return (stage/'console.log').read_text(encoding='utf-8',errors='replace')
glbl=[] if re.search(r'\bmodule\s+glbl\b',net.read_text(errors='replace')) else [(V.parent/'data/verilog/src/glbl.v').as_posix()]
execute('compile',[str(V/'xvlog.bat'),'--sv','synthesized.v','gate_tb.sv',*glbl])
execute('elaborate',[str(V/'xelab.bat'),'--debug','typical','--mt','off','-L','unisims_ver','sxm_compatible_core_tb','glbl','-s','gate'])
results=[]
for c in cases:
 args=tmp/(c['name']+'.args');args.write_text(f'-tclbatch "{(tmp/"run.tcl").as_posix()}"\n-testplusarg "CASE={c["path"]}"\n-testplusarg "CYCLES={c["cycles"]}"\n-testplusarg "COMPAT={c["compat"]}"\n')
 log=execute(c['name'],[str(V/'xsim.bat'),'gate','-f',args.as_posix()]);ok='SXM_COMPATIBLE_CORE PASS' in log and 'Fatal:' not in log
 results.append(dict(name=c['name'],pass_=ok));(out/'summary.json').write_text(json.dumps(results,indent=2));print(c['name'],ok,flush=True)
 if not ok:raise SystemExit('netlist mismatch')
