from pathlib import Path
import subprocess,sys,json,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];EXP=ROOT/'learn/sxm_l3_compat_20261104'
SHA='1c203d4773fb6b222a42d236adc750eade11293b';repo=ROOT/'lpu_src/FTLPU-CMODEL'
CM=E/'tmp'/sys.argv[1]/'source';CM.mkdir(parents=True,exist_ok=False)
import tarfile,io
archive=subprocess.check_output(['git','-c',f'safe.directory={repo}','-C',str(repo),'archive',SHA])
with tarfile.open(fileobj=io.BytesIO(archive)) as tf:tf.extractall(CM,filter='data')
run=sys.argv[1];out=E/'results'/run;out.mkdir(parents=True,exist_ok=False)
tmp=E/'tmp'/run
cases=json.loads((EXP/'cases/index.json').read_text());results=[]
for T,profile in [(2,'ftlpu-lpu16-decode'),(4,'ftlpu-lpu32'),(8,'ftlpu-lpu64-tiles8')]:
    build=tmp/f't{T}'
    with (out/f'build_t{T}.log').open('w') as log:
        subprocess.run(['cmake','-S',str(CM),'-B',str(build),f'-DFTLPU_HARDWARE_CONFIG={CM/"config"/(profile+".json")}'],stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run(['g++','-std=c++20','-O1','-I'+str(build/'generated/include'),'-I'+str(CM/'include'),
                        str(EXP/'scripts/cmodel_probe.cpp'),'-o',str(build/'probe')],stdout=log,stderr=subprocess.STDOUT,check=True)
    for case in [x for x in cases if x['T']==T and not any(n in x['name'] for n in
            ('reject_','missing_plane','occupied','cross_destination','arbitration','legacy_row_legacy',
             'idle_entry_collision','bad_t_then_valid','vmodel_unready_selected'))]:
        p=subprocess.run([str(build/'probe'),str(EXP/'cases'/case['name'])],capture_output=True,text=True)
        (out/(case['name']+'.log')).write_text(p.stdout+p.stderr)
        ok=p.returncode==0 and 'CMODEL_COMPAT PASS' in p.stdout
        results.append(dict(name=case['name'],T=T,pass_=ok));print(case['name'],ok,flush=True)
        if not ok: print(p.stdout+p.stderr,flush=True)
paths=[EXP/'scripts/cmodel_probe.cpp',Path(__file__),CM/'include/ftlpu/core/instruction_codec.hpp',CM/'include/ftlpu/sxm/slice.hpp']
paths += list((EXP/'cases').rglob('*.hex'))
(out/'summary.json').write_text(json.dumps(dict(baseline=SHA,
    results=results,passed=sum(x['pass_'] for x in results),total=len(results),
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}),indent=2)+'\n')
sys.exit(0 if all(x['pass_'] for x in results) else 1)
