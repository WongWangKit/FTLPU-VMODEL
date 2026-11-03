"""S06/S07: frozen c7 + local synchronous-read model; MEM-only RTL regression."""
import argparse
import json
import re
import shutil
import sys
from pathlib import Path
sys.dont_write_bytecode = True
import run

ROOT, HERE, CM = run.ROOT, run.HERE, run.CM
PRIOR = ROOT / 'build/mem_p1/mem_20261019_s01_s05_r1'


def prepare(out):
    assert run.git(CM, 'rev-parse', 'HEAD') == run.CM_SHA
    assert not run.git(CM, 'status', '--porcelain', '--untracked-files=no')
    out.mkdir(parents=True, exist_ok=False)
    files = run.git(CM, 'ls-files').splitlines()
    copied = {}
    for rel in files:
        if rel == 'CMakeLists.txt' or rel.split('/')[0] in ['include','src','tests','cmake','config','examples']:
            p = CM / rel
            target = out / 'cmodel_before' / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, target)
            copied[rel] = run.sha(p)
    contract = next((ROOT / 'spec_new_c7ae225').glob('mem*契约.md'))
    shutil.copy2(contract, out / 'contract_before.md')
    run.save(out / 'manifest_before.json', dict(cmodel_base=run.CM_SHA, cmodel_files=copied,
        vm_revision=run.git(ROOT, 'rev-parse', 'HEAD'), vm_files=run.protected(),
        prior_test_files={p.relative_to(ROOT).as_posix():run.sha(p) for p in HERE.rglob('*') if p.is_file()},
        contract=contract.relative_to(ROOT).as_posix(), prior_summary_sha256=run.sha(PRIOR/'summary.json')))
    shutil.copy2(PRIOR / 'tools.json', out / 'tools.json')
    print('SYNC_PREPARED', out, flush=True)


def cmodel(out, name, source):
    work = out / name
    work.mkdir(parents=True, exist_ok=False)
    tools = run.read(out / 'tools.json')
    cmake = tools['cmake']
    args = [cmake, '-S', source, '-B', work, '-G', 'MinGW Makefiles',
        '-DCMAKE_CXX_COMPILER=F:/mingw64/bin/g++.exe', '-DCMAKE_MAKE_PROGRAM=F:/mingw64/bin/mingw32-make.exe',
        '-DCMAKE_BUILD_TYPE=Debug', '-DCMAKE_CXX_FLAGS_DEBUG=-O1 -g0', '-DCMAKE_EXE_LINKER_FLAGS=-static']
    run.required(args, work, work/'configure.txt', 180)
    targets = re.findall(r'ftlpu_add_test\(\s*(\w+)\s+\S+\s+\S+\s+([^)]*)\)',
                         (source/'CMakeLists.txt').read_text(encoding='utf-8'))
    fast = [target for target, labels in targets if 'fast' in labels.split()]
    run.save(work/'source_identity.json', {p.relative_to(source).as_posix():run.sha(p)
        for directory in ['include','src','tests','cmake','config'] for p in (source/directory).rglob('*') if p.is_file()})
    run.required([cmake,'--build',work,'--parallel','3','--target',*fast],work,work/'build.txt',3600)
    ctest = Path(cmake).with_name('ctest.exe')
    result = run.execute([ctest,'--test-dir',work,'-L','fast','--output-on-failure','--timeout','180',
                          '--output-junit',work/'results.xml'],work,work/'ctest.txt',3600)
    run.save(work/'regression.json', dict(result=result, targets=fast, assertions_enabled=True,
                                         scope='all CMake fast-labeled tests; failures preserved, no expected rewrites'))
    print('CMODEL_REGRESSION', name, 'exit',result['exit'],flush=True)


def references(out):
    tools=run.read(out/'tools.json')
    for depth in [64,8192,32768]:
        work=out/'reference'/str(depth);work.mkdir(parents=True,exist_ok=False)
        prior=PRIOR/'reference'/str(depth)
        shutil.copy2(prior/'target.json',work/'target.json')
        header=work/'include/ftlpu/core/hardware_config.hpp'
        run.required([tools['cmake'],'-DCMODEL='+CM.as_posix(),'-DINPUT_JSON='+(work/'target.json').as_posix(),
            '-DOUTPUT_HEADER='+header.as_posix(),'-P',HERE/'configure_reference.cmake'],work,work/'configure.txt')
        assert run.sha(header)==run.sha(prior/'include/ftlpu/core/hardware_config.hpp')
        for name,source in [('sync_reference','sync_reference.cpp'),('functional_reference','reference.cpp')]:
            run.required([tools['compiler'],'-std=c++20','-O2','-static','-I'+str(work/'include'),'-I'+str(CM/'include'),
                          HERE/source,CM/'src/mem/sram.cpp','-o',work/(name+'.exe')],work,work/(name+'_compile.txt'))
        for task,args,file in [('codec',[str(depth)],'codec.txt')]+([('masks',[],'masks.txt')] if depth==64 else []):
            run.required([work/'functional_reference.exe',task,work/file,*args],work,work/(task+'_run.txt'))
            assert (work/file).read_bytes()==(prior/file).read_bytes(),'original/adapted functional drift: '+file
        run.save(work/'identity.json',dict(cmodel_base=run.CM_SHA,cmodel_adapted=True,
            model_sha256=run.sha(CM/'include/ftlpu/mem/mem_array.hpp'),driver_sha256=run.sha(HERE/'sync_reference.cpp'),
            config_sha256=run.sha(work/'target.json'),header_sha256=run.sha(header),
            exe_sha256=run.sha(work/'sync_reference.exe'),functional_crosscheck=True))
        print('SYNC_REFERENCE_READY',depth,flush=True)


def continue_regression(out, name, source):
    work=out/name;tools=run.read(out/'tools.json');cmake=tools['cmake']
    entries=re.findall(r'ftlpu_add_test\(\s*(\w+)\s+\S+\s+(\S+)\s+([^)]*)\)',
                       (source/'CMakeLists.txt').read_text(encoding='utf-8'))
    logs=work/'individual';logs.mkdir(exist_ok=False);results=[]
    for target,test,labels in entries:
        if 'fast' not in labels.split():continue
        build=run.execute([cmake,'--build',work,'--parallel','2','--target',target],work,logs/(target+'_build.txt'),900)
        result=None
        if build['exit']==0:
            result=run.execute([Path(cmake).with_name('ctest.exe'),'--test-dir',work,'-R','^'+re.escape(test)+'$',
                '--output-on-failure','--timeout','180'],work,logs/(target+'_test.txt'),240)
        status='build_failure' if build['exit'] else 'pass' if result['exit']==0 else 'test_failure'
        results.append(dict(target=target,test=test,status=status,build=build,result=result))
        run.save(work/'individual_results.json',results)
        print(name,test,status,flush=True)
    print('REGRESSION_COMPLETE',name,len(results),flush=True)


def rtl(out,tag,smoke=False,sample=False):
    cases=[r for r in run.read(PRIOR/'rtl_v1_full_results.json') if '_z0_' in r['name']]
    if smoke:cases=[r for r in cases if r['name']=='rtl_v1_p64_e64_z0_directed']
    if sample:
        selected={'rtl_v1_p8192_e8192_z0_seed_1296387335',
                  'rtl_v1_p64_e64_z0_directed',
                  'rtl_v1_p8192_e64_z0_directed'}
        cases=[r for r in cases if r['name'] in selected]
        assert len(cases)==3
    sources=[ROOT/p.strip() for p in (HERE/'filelist_sync.f').read_text().splitlines() if p.strip()]
    workspaces={};results=[]
    tops={(8192,8192,0):'error',(64,64,0):'64',
          (32768,32768,0):'32768',(8192,64,0):'active64'}
    directory=out/'vectors';directory.mkdir(exist_ok=True)
    for case in cases:
        c=case['coverage'];p,e=c['physical_rows'],c['active_rows'];mode=int('_z1_' in case['name'])
        key=p,e,mode
        if key not in workspaces:
            workspaces[key]=run.compile_sim(out,tag+'/p'+str(p)+'_e'+str(e)+'_z'+str(mode),sources,
                                             'mem_p1_sync_'+tops[key]+'_tb')
        ref=out/'reference'/str(p);identity=run.read(ref/'identity.json')
        assert identity['model_sha256']==run.sha(CM/'include/ftlpu/mem/mem_array.hpp')
        assert identity['driver_sha256']==run.sha(HERE/'sync_reference.cpp')
        source=next(Path(x[8:]) for x in case['result']['command'] if x.startswith('VECTORS='))
        assert run.sha(source)==case['vector_sha256']
        target=directory/(tag+'_'+case['name']+'.txt');assert not target.exists()
        run.required([ref/'sync_reference.exe',source,target],directory,target.with_suffix('.reference.txt'),1800)
        result=run.simulate(out,workspaces[key],case['name'],['VECTORS='+target.as_posix()],'MEM_SYNC TEST_PASS',timeout=1800)
        results.append(dict(name=case['name'],source_vector_sha256=run.sha(source),vector_sha256=run.sha(target),
                            coverage=run.read(str(target)+'.coverage.json'),result=result))
        run.save(out/(tag+'_results.json'),results)
    return results


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=['prepare','baseline','adapted','reference','smoke','full','sample','baseline_finish','adapted_finish'])
    parser.add_argument('--run-id',required=True)
    parser.add_argument('--tag',default='l2_v1')
    args=parser.parse_args()
    if not all(re.fullmatch(r'[A-Za-z0-9_-]+',s) for s in [args.run_id,args.tag]):parser.error('invalid RunId/Tag')
    out=ROOT/'build/mem_p1'/args.run_id
    if args.stage=='prepare':prepare(out)
    elif args.stage=='baseline':cmodel(out,'cmodel_baseline',out/'cmodel_before')
    elif args.stage=='adapted':cmodel(out,'cmodel_adapted',CM)
    elif args.stage=='reference':references(out)
    elif args.stage=='baseline_finish':continue_regression(out,'cmodel_baseline',out/'cmodel_before')
    elif args.stage=='adapted_finish':continue_regression(out,'cmodel_adapted',CM)
    else:rtl(out,args.tag,args.stage=='smoke',args.stage=='sample')
