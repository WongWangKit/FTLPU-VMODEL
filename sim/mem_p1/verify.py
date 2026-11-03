"""Standalone MEM RTL tests; original c7 functional reference, no L2 adaptation."""
import argparse
from pathlib import Path
import sys
import re
sys.dont_write_bytecode = True
import run

ROOT, HERE = run.ROOT, run.HERE
CHECKERS = [HERE / p for p in ['runtime_checker.sv', 'leaf_bind.sv', 'control_bind.sv']]
SOURCES = [ROOT / p for p in run.CORE] + [ROOT / 'rtl/mem_native/mem_c7_primitive_adapter.sv']
SEEDS = [0x4d454d00 + i for i in range(16)]


def references(out):
    tools = run.read(out / 'tools.json')
    snapshot = out / 'reference_source'
    for depth in [64, 8192, 32768]:
        work = out / 'reference' / str(depth); work.mkdir(parents=True, exist_ok=False)
        config = run.read(snapshot / 'config/ftlpu-lpu32.json')
        config['mem']['rows_per_bank'] = depth
        run.save(work / 'target.json', config)
        header = work / 'include/ftlpu/core/hardware_config.hpp'
        run.required([tools['cmake'], '-DCMODEL=' + snapshot.as_posix(),
            '-DINPUT_JSON=' + (work / 'target.json').as_posix(), '-DOUTPUT_HEADER=' + header.as_posix(),
            '-P', HERE / 'configure_reference.cmake'], work, work / 'configure.txt')
        run.required([tools['compiler'], '-std=c++20', '-O2', '-static',
            '-I' + str(work / 'include'), '-I' + str(snapshot / 'include'),
            HERE / 'reference.cpp', snapshot / 'src/mem/sram.cpp', '-o', work / 'reference.exe'],
            work, work / 'compile.txt')
        run.required([work / 'reference.exe', 'codec', work / 'codec.txt', str(depth)], work, work / 'codec_reference.txt')
        if depth == 64:
            run.required([work / 'reference.exe', 'masks', work / 'masks.txt'], work, work / 'mask_reference.txt')
        if depth == 8192:
            run.required([work / 'reference.exe', 'codec', work / 'codec_active64.txt', '64'], work, work / 'active_reference.txt')
        run.save(work / 'identity.json', dict(source_sha256=run.sha(HERE / 'reference.cpp'),
            config_sha256=run.sha(work / 'target.json'), generated_sha256=run.sha(header),
            exe_sha256=run.sha(work / 'reference.exe'), reference_sha=run.CM_SHA,
            cmodel_modified=False, physical_rows=depth))
        print('MEM_REFERENCE_READY', depth, flush=True)


def vectors(out, depth, active, mode, name, seed, directed):
    assert mode == 0, 'MEM RTL supports Error only'
    ref = out / 'reference' / str(depth)
    assert run.read(ref / 'identity.json')['source_sha256'] == run.sha(HERE / 'reference.cpp')
    directory = out / 'vectors'; directory.mkdir(exist_ok=True)
    path = directory / (name + '.txt')
    if path.exists(): raise RuntimeError('vector exists: ' + str(path))
    run.required([ref / 'reference.exe', 'full', path, str(active), str(mode), str(seed), str(int(directed))],
                 directory, directory / (name + '.reference.txt'), 900)
    return path


def full(out, tag, smoke=False):
    results = []
    configs = [(64,64,0,'mem_p1_full_64_tb')] if smoke else [
        (8192,8192,0,'mem_p1_full_error_tb'),
        (64,64,0,'mem_p1_full_64_tb'), (32768,32768,0,'mem_p1_full_32768_tb'),
        (8192,64,0,'mem_p1_full_active64_tb')]
    for depth, active, mode, top in configs:
        name = f'p{depth}_e{active}_z{mode}'
        work = run.compile_sim(out, tag + '/' + name, SOURCES + CHECKERS + [HERE / 'full_tb.sv'], top)
        suite = [('directed',0x4d454d00,True)]
        if not smoke and depth == active == 8192:
            suite += [('seed_' + str(seed),seed,False) for seed in SEEDS]
        for case,seed,directed in suite:
            case_name = tag + '_' + name + '_' + case
            path = vectors(out, depth, active, mode, case_name, seed, directed)
            result = run.simulate(out, work, case, ['VECTORS=' + path.as_posix()], 'MEM_FULL TEST_PASS', timeout=1800)
            results.append(dict(name=case_name, result=result, vector_sha256=run.sha(path),
                                coverage=run.read(str(path) + '.coverage.json')))
            run.save(out / (tag + '_full_results.json'), results)
    return results


def units(out, tag):
    results = []
    work = run.compile_sim(out, tag + '/unit', SOURCES + CHECKERS + [HERE / 'unit_tb.sv'], 'mem_p1_unit_tb')
    results.append(run.simulate(out, work, 'functional', ['CASE=0', 'MASKS=' +
                    (out / 'reference/64/masks.txt').as_posix()], 'MEM_UNIT TEST_PASS'))
    messages = {1:'unknown MEM command valid',2:'unknown valid MEM command',
                3:'unknown valid MEM command',4:'unknown MEM segment valid',
                5:'unknown valid MEM write payload',6:'unknown MEM reset',
                7:'unknown MEM command valid',8:'unknown MEM segment valid',
                9:'unknown valid MEM write payload'}
    for case,message in messages.items():
        results.append(run.simulate(out, work, 'unknown_' + str(case), ['CASE=' + str(case)], failure=message))
    legacy = ROOT / 'rtl/integration/lpu_mem_command_adapter.sv'
    work = run.compile_sim(out, tag + '/adapter', SOURCES + [legacy] + CHECKERS + [HERE / 'adapter_tb.sv'], 'mem_p1_adapter_tb')
    for selected, path in [(0,'64/codec.txt'),(1,'8192/codec.txt'),(2,'32768/codec.txt'),(3,'8192/codec_active64.txt')]:
        results.append(run.simulate(out, work, 'codec_' + str(selected),
            ['SELECT=' + str(selected), 'VECTORS=' + (out / 'reference' / path).as_posix()], 'MEM_ADAPTER TEST_PASS'))
    run.save(out / (tag + '_unit_results.json'), results)
    return results


def safety(out, tag):
    results = []
    sources = SOURCES + CHECKERS + [HERE / 'entry_checks.sv']
    for name, top, tb in [('safety','mem_p1_fault_tb','fault_tb.sv'),
                          ('group','mem_p1_group_collision_tb','fault_tb.sv'),
                          ('active','mem_p1_active_depth_tb','active_depth_tb.sv'),
                          ('entry','mem_p1_entry_tb','entry_tb.sv')]:
        work = run.compile_sim(out, tag + '/' + name, sources + [HERE / tb], top)
        results.append(run.simulate(out, work, 'functional'))
        if name == 'entry':
            for case, message in {1:'unknown MEM command valid',2:'unknown valid MEM command',
                3:'unknown valid MEM collision feedback',4:'unknown valid MEM command',
                5:'unknown MEM command valid',6:'unknown MEM command valid',
                7:'unknown valid MEM command',8:'unknown valid MEM collision feedback'}.items():
                results.append(run.simulate(out, work, 'entry_unknown_' + str(case),
                                            ['CASE=' + str(case)], failure=message))
        run.save(out / (tag + '_safety_results.json'), results)
    return results


def parameters(out, tag):
    tools = run.read(out / 'tools.json')
    work = out / tag / 'parameters'; work.mkdir(parents=True, exist_ok=False)
    sources = SOURCES + CHECKERS + [HERE / 'parameter_tops.sv']
    fl = work / 'sources.f'; fl.write_text(''.join(p.as_posix()+'\n' for p in sources),encoding='utf-8')
    run.save(work / 'source_identity.json', {str(p): run.sha(p) for p in sources})
    run.required([tools['xvlog'],'--sv','-f',fl],work,work/'compile.txt')
    tests = {
        'physical_zero':'illegal MEM physical/active depth',
        'physical_nonpower':'illegal MEM physical/active depth',
        'physical_large':'illegal MEM physical/active depth',
        'active_zero':'illegal MEM physical/active depth',
        'active_nonpower':'illegal MEM physical/active depth',
        'active_large':'illegal MEM physical/active depth',
        'latency':'unsupported MEM leaf profile',
        'hop':'supports one-cycle hops only','bank_count':'supports the FTLPU_DEFAULT_4T8L profile only',
        'group_count':'unsupported MEM group profile','hemisphere_count':'invalid slice/group topology',
        'c7_legacy_depth':'illegal c7 MEM physical/active depth','c7_active':'illegal c7 MEM physical/active depth'}
    results = []
    for name, message in tests.items():
        top='mem_bad_'+name
        run.required([tools['xelab'],top,'-s',top,'--O0','--timescale','1ns/1ps'],work,work/(name+'_elaborate.txt'))
        result=run.execute([tools['xsim'],top,'-runall'],work,work/(name+'.txt'))
        text=Path(result['log']).read_text(encoding='utf-8',errors='replace')
        result.update(pass_=not result['timeout'] and 'Fatal:' in text and message in text and 'UNEXPECTED_' not in text,
                      expected_failure=message)
        results.append(dict(name=name,result=result));run.save(out/(tag+'_parameter_results.json'),results)
        if not result['pass_']:raise RuntimeError('parameter rejection failed: '+name)
        print('parameter_'+name,'PASS',flush=True)
    return results


def mutation(out, tag):
    source=out/'vectors/smoke_v1_p64_e64_z0_directed.txt'
    target=out/(tag+'_mutated_read.txt')
    lines=source.read_text().splitlines();cursor=1;changed=None
    cycles=int(lines[0].split()[-1])
    for cycle in range(cycles):
        frame=list(map(int,lines[cursor].split()));cursor+=1
        _,_,ni,ns,ne=frame;cursor+=ni+ns
        for event in range(ne):
            fields=lines[cursor+event].split()
            if changed is None and int(fields[4])==0:
                fields[10]=format(int(fields[10],16)^1,'x')
                lines[cursor+event]=' '.join(fields);changed=dict(cycle=cycle,event=event,coordinate=fields[:8])
        cursor+=ne
    assert changed is not None
    target.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    work=run.compile_sim(out,tag+'/mutation',SOURCES+CHECKERS+[HERE/'full_tb.sv'],'mem_p1_full_64_tb')
    result=run.simulate(out,work,'mutation',['VECTORS='+target.as_posix()],failure='MEM response metadata/byte')
    run.save(out/(tag+'_mutation_result.json'),dict(result=result,mutation=changed,
             original_sha256=run.sha(source),mutated_sha256=run.sha(target),original_unchanged=True))


def legacy_default(out, tag):
    results=[]
    for version,base in [('old',out/'before'),('new',ROOT)]:
        sources=[base/p for p in run.CORE]+([*CHECKERS] if version=='new' else [])+[HERE/'legacy_default_tb.sv']
        work=run.compile_sim(out,tag+'/legacy_default_'+version,sources,'mem_p1_legacy_default_tb')
        trace=work/'trace.txt'
        result=run.simulate(out,work,'run',['TRACE='+trace.as_posix()],'MEM_BASELINE TEST_PASS')
        results.append(dict(version=version,result=result,trace_sha256=run.sha(trace)))
    assert results[0]['trace_sha256']==results[1]['trace_sha256'],'legacy32768 legal trace changed'
    run.save(out/(tag+'_legacy_default_results.json'),dict(pass_=True,results=results,raw_traces_identical=True))


def filelists(out, tag):
    results=[]
    entries=[('leaf','mem_p1_unit_tb',['CASE=0','MASKS='+(out/'reference/64/masks.txt').as_posix()]),
             ('adapter','mem_p1_adapter_tb',['SELECT=1','VECTORS='+(out/'reference/8192/codec.txt').as_posix()]),
             ('active','mem_p1_active_depth_tb',[])]
    for name,top,plus in entries:
        fl=HERE/('filelist_'+name+'.f')
        sources=[ROOT/p.strip() for p in fl.read_text().splitlines() if p.strip()]
        work=run.compile_sim(out,tag+'/filelist_'+name,sources,top)
        results.append(dict(filelist=fl.relative_to(ROOT).as_posix(),filelist_sha256=run.sha(fl),
                            result=run.simulate(out,work,'run',plus)))
    run.save(out/(tag+'_filelist_results.json'),results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['reference','smoke','full','units','safety','parameters','mutation','legacy','filelists'])
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--tag', default='rtl_v1')
    args = parser.parse_args()
    if not all(re.fullmatch(r'[A-Za-z0-9_-]+', s) for s in [args.run_id,args.tag]): parser.error('invalid ID')
    out = ROOT / 'build/mem_p1' / args.run_id
    if args.stage == 'reference': references(out)
    elif args.stage == 'units': units(out, args.tag)
    elif args.stage == 'safety': safety(out, args.tag)
    elif args.stage == 'parameters': parameters(out, args.tag)
    elif args.stage == 'mutation': mutation(out, args.tag)
    elif args.stage == 'legacy': legacy_default(out, args.tag)
    elif args.stage == 'filelists': filelists(out, args.tag)
    else: full(out, args.tag, args.stage == 'smoke')
