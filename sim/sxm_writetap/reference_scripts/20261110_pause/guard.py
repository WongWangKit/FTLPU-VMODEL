"""Windows parent owns sleep protection for the complete WSL stage.
Screen-off is allowed; automatic system sleep is inhibited while work runs.
Timeout is awake time, not elapsed wall time. Global power settings unchanged.
"""
from pathlib import Path
import sys,os,json
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1]
sys.path.insert(0,str(ROOT/'learn/sxm_gap10_20261104/scripts'))
from host_runtime import run_command
run=sys.argv[1];entry='run_sim'
if len(sys.argv)>3 and sys.argv[2]=='--entry':
 entry=sys.argv[3];del sys.argv[2:4]
assert all(x.replace('_','').isalnum() for x in [run,entry,*sys.argv[2:]])
out=E/'results'/(run+'_host');out.mkdir(exist_ok=False)
cmd=['wsl','-d','Ubuntu-22.04','--','bash','-lc',f'cd <LPU_WORKSPACE>; ulimit -c 0; exec python3 -B learn/sxm_writetap_implementation_20261109/scripts/{entry}.py {run} '+ ' '.join(sys.argv[2:])]
(out/'command.json').write_text(json.dumps(cmd,indent=2))
rc,status=run_command(cmd,out=out,work=ROOT,env=dict(os.environ),timeout=43200,poll_seconds=10)
print(status,rc);raise SystemExit(0 if rc==0 else 1)
