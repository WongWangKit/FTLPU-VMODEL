"""Recheck historical CModel MEM/MXM failures at pinned latest main."""
from pathlib import Path
import sys,subprocess,json,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1]
src=E/'tmp/cmodel01/source';out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False)
tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
with (out/'configure.log').open('w') as f:
 subprocess.run(['cmake','-S',str(src),'-B',str(tmp),f'-DFTLPU_HARDWARE_CONFIG={src}/config/ftlpu-lpu32.json','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_CXX_FLAGS_RELEASE=-O1 -g0'],stdout=f,stderr=subprocess.STDOUT,check=True)
cmake=(src/'CMakeLists.txt').read_text();results=[]
for name in ['mxm_bf16_test','mxm_decode_streamed_weight_test','mxm_decode_layout_comparison_test','mem_sync_read_test']:
 if name not in cmake:
  results.append(dict(name=name,status='target_removed_at_pinned_main',pass_=False));continue
 with (out/(name+'_build.log')).open('w') as f:p=subprocess.run(['cmake','--build',str(tmp),'--target',name,'--parallel','2'],stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:results.append(dict(name=name,status='build_failed',pass_=False));continue
 p=subprocess.run([str(tmp/name)],cwd=tmp,capture_output=True,text=True)
 (out/(name+'.log')).write_text(p.stdout+p.stderr);print(name,p.returncode,flush=True)
 results.append(dict(name=name,status='passed' if p.returncode==0 else 'historical_failure_reproduced',pass_=p.returncode==0))
(out/'summary.json').write_text(json.dumps(dict(reference='1c203d4773fb6b222a42d236adc750eade11293b',results=results,cmake_sha256=hashlib.sha256((src/'CMakeLists.txt').read_bytes()).hexdigest()),indent=2))
