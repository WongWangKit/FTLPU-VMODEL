"""Profile regression on the approved local c7 synchronous-read R1.

Separate RunId, sources and logs; never rewrites historical audit/golden files.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import subprocess
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('mem_p1_common', ROOT/'sim/mem_p1/run.py')
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)


def tools(out):
    path = out/'tools.json'
    if not path.exists():
        vivado = Path('C:/Users/huazh/Desktop/Vivado2023/Vivado/2023.2/bin')
        data = {k: str(vivado/(k+'.bat')) for k in ('xvlog','xelab','xsim')}
        data.update(cmake=shutil.which('cmake'), compiler=shutil.which('g++'))
        common.save(path, data)


def prepare(out):
    """Preserve both dirty workspaces; never reset/checkout either repository."""
    cm=ROOT.parent/'FTLPU-CMODEL'
    if common.git(cm,'rev-parse','HEAD')!=common.CM_SHA:
        raise RuntimeError('working CModel is not the approved c7 baseline')
    out.mkdir(parents=True,exist_ok=False)
    manifest={};states={}
    with zipfile.ZipFile(out/'preimplementation_sources.zip','w',zipfile.ZIP_DEFLATED) as archive:
        for root,dirs in [(ROOT,['rtl','sim','scripts','config','spec_new_c7ae225']),
                          (cm,['include','src','tests','cmake','config'])]:
            states[root.name]={name:common.git(root,*cmd) for name,cmd in [
                ('head',['rev-parse','HEAD']),('status',['status','--short']),('diff',['diff','--binary'])]}
            files=[p for d in dirs for p in (root/d).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
            if (root/'CMakeLists.txt').exists():files.append(root/'CMakeLists.txt')
            for p in files:
                name=root.name+'/'+p.relative_to(root).as_posix()
                manifest[name]=common.sha(p);archive.writestr(name,p.read_bytes())
    common.save(out/'baseline_manifest.json',manifest)
    common.save(out/'baseline_git.json',states)
    tools(out)
    print('MEM_PROFILES_PREPARED',out,len(manifest),flush=True)
    return [dict(name='prepare',status='passed')]


def legacy(out, selected):
    entries = [
        ('srf','lpu_srf_tb'),
        ('sxm_srf','lpu_sxm_srf_tb'),
        ('sxm_command_adapter','lpu_sxm_command_adapter_tb'),
        ('mem_srf','lpu_mem_srf_tb'),
        ('mem_command_adapter','lpu_mem_command_adapter_tb'),
        ('mem_srf_multigroup_align','lpu_mem_srf_multigroup_align_tb'),
        ('mem_srf_sxm_turnaround','lpu_mem_srf_sxm_turnaround_tb'),
        ('mem_srf_sxm_roundtrip','lpu_mem_srf_sxm_roundtrip_tb'),
        ('mem_srf_sxm_existing_workload','lpu_mem_srf_sxm_existing_workload_tb'),
        ('dma_store_vector_sink','lpu_mem_srf_dma_store_vector_sink_tb'),
        ('c2c_rx_srf_integration','lpu_c2c_rx_srf_integration_tb'),
        ('c2c_tx_srf_adapter','lpu_c2c_tx_srf_adapter_tb'),
        ('c2c_srf_peer_e2e','lpu_c2c_srf_peer_e2e_tb'),
    ]
    results = common.read(out/'legacy_results.json') if (out/'legacy_results.json').exists() else []
    for name, top in entries:
        if selected and name not in selected:
            continue
        try:
            fl = ROOT/f'sim/filelist_{name}.f'
            sources = [ROOT/l.strip() for l in fl.read_text().splitlines()
                       if l.strip() and not l.strip().startswith('//')]
            attempt = 1
            while (out/f'legacy/{name}_attempt{attempt}').exists():
                attempt += 1
            work = common.compile_sim(out, f'legacy/{name}_attempt{attempt}', sources, top)
            if name=='mem_srf_sxm_existing_workload':
                shutil.copytree(ROOT/'sim/vectors',work/'sim/vectors')
                common.save(work/'vector_identity.json', {p.relative_to(ROOT).as_posix():common.sha(p)
                    for p in (ROOT/'sim/vectors').rglob('*') if p.is_file()})
            marker = 'MULTIGROUP_TILE_PIPELINE_ALIGNMENT PASS' if name=='mem_srf_multigroup_align' else 'TEST_PASS'
            result = common.simulate(out, work, 'run', marker=marker)
            results.append(dict(name=name, status='passed', result=result))
        except Exception as e:
            results.append(dict(name=name, status='failed', error=str(e)))
            print(name, 'FAILED', str(e), flush=True)
        common.save(out/'legacy_results.json', results)
    return results


def profiles(out, selected, seeds):
    """Full H2/F52/K2 MEM fixture; not an RTL SRF integration claim."""
    cm = ROOT.parent/'FTLPU-CMODEL'
    tool = common.read(out/'tools.json')
    result_path = out/'profiles_results.json'
    results = common.read(result_path) if result_path.exists() else []
    for profile, tiles, depth in [(16,2,1024),(32,4,2048),(64,8,2048)]:
        if selected and str(profile) not in selected:
            continue
        attempt = 1
        while (out/f'profiles/{profile}_attempt{attempt}').exists():
            attempt += 1
        work = out/f'profiles/{profile}_attempt{attempt}'
        work.mkdir(parents=True)
        try:
            target = cm/f'config/mem-profiles/ftlpu-lpu{profile}.json'
            header = work/'include/ftlpu/core/hardware_config.hpp'
            common.required([tool['cmake'], '-DCMODEL='+cm.as_posix(),
                '-DINPUT_JSON='+target.as_posix(), '-DOUTPUT_HEADER='+header.as_posix(),
                '-P', ROOT/'sim/mem_p1/configure_reference.cmake'],work,work/'configure.txt')
            identity = {str(p):common.sha(p) for p in [target,header,
                cm/'include/ftlpu/core/hardware_params.hpp',cm/'include/ftlpu/mem/mem_array.hpp']}
            for driver in ['reference','sync_reference']:
                common.required([tool['compiler'],'-std=c++20','-O2','-static',
                    '-I'+str(work/'include'),'-I'+str(cm/'include'),
                    ROOT/f'sim/mem_p1/{driver}.cpp',cm/'src/mem/sram.cpp','-o',work/(driver+'.exe')],
                    work,work/(driver+'_compile.txt'))
                identity[str(ROOT/f'sim/mem_p1/{driver}.cpp')]=common.sha(ROOT/f'sim/mem_p1/{driver}.cpp')
                identity[str(work/(driver+'.exe'))]=common.sha(work/(driver+'.exe'))
            common.save(work/'reference_identity.json',identity)
            sources=[ROOT/p for p in common.CORE]+[ROOT/'sim/mem_p1'/n for n in
                ['runtime_checker.sv','leaf_bind.sv','control_bind.sv']]
            sims={}
            for kind in ['full','sync']:
                sims[kind]=common.compile_sim(out,str(work.relative_to(out)/kind),
                    sources+[ROOT/f'sim/mem_p1/{kind}_tb.sv'],f'mem_p1_{kind}_tb',
                    [f'DEPTH={depth}',f'ACTIVE={depth}',f'TILES={tiles}'])
            cases=[('directed',0x4d454d00,True)]+[(f'seed{i}',0x4d454d00+i,False) for i in range(seeds)]
            for name,seed,directed in cases:
                l1=work/(name+'_l1.txt');l2=work/(name+'_l2.txt')
                common.required([work/'reference.exe','full',l1,str(depth),'0',str(seed),str(int(directed))],
                    work,work/(name+'_reference.txt'))
                common.required([work/'sync_reference.exe',l1,l2],work,work/(name+'_sync_reference.txt'))
                for kind,vector in [('full',l1),('sync',l2)]:
                    res=common.simulate(out,sims[kind],name,['VECTORS='+vector.as_posix()],timeout=1800)
                    results.append(dict(profile=profile,tiles=tiles,physical_rows=depth,case=name,
                        stage=kind,status='passed',result=res,vector_sha256=common.sha(vector),
                        coverage=common.read(str(vector)+'.coverage.json')))
                    common.save(result_path,results)
        except Exception as e:
            results.append(dict(profile=profile,status='failed',error=str(e),work=str(work)))
            common.save(result_path,results)
            print('PROFILE',profile,'FAILED',str(e),flush=True)
    return results


def integration(out, selected):
    cm=ROOT.parent/'FTLPU-CMODEL'; tool=common.read(out/'tools.json')
    result_path=out/'integration_results.json'
    results=common.read(result_path) if result_path.exists() else []
    for profile in [16,32,64]:
        if selected and str(profile) not in selected:
            continue
        attempt=1
        while (out/f'integration/{profile}_attempt{attempt}').exists():
            attempt+=1
        work=out/f'integration/{profile}_attempt{attempt}';work.mkdir(parents=True)
        try:
            header=work/'include/ftlpu/core/hardware_config.hpp'
            target=cm/f'config/mem-profiles/ftlpu-lpu{profile}.json'
            common.required([tool['cmake'],'-DCMODEL='+cm.as_posix(),'-DINPUT_JSON='+target.as_posix(),
                '-DOUTPUT_HEADER='+header.as_posix(),'-P',ROOT/'sim/mem_p1/configure_reference.cmake'],work,work/'configure.txt')
            for name,source in [('reference',HERE/'integration_reference.cpp'),
                                ('sync_unit',cm/'tests/unit/mem/mem_sync_read_test.cpp')]:
                common.required([tool['compiler'],'-std=c++20','-O2','-static','-I'+str(work/'include'),
                    '-I'+str(cm/'include'),source,cm/'src/mem/sram.cpp','-o',work/(name+'.exe')],work,work/(name+'_compile.txt'))
            common.required([work/'sync_unit.exe'],work,work/'sync_unit_run.txt')
            vector=work/'vectors.txt'
            common.required([work/'reference.exe',vector],work,work/'reference_run.txt')
            fl=ROOT/'sim/filelist_mem_srf.f'
            sources=[ROOT/l.strip() for l in fl.read_text().splitlines() if l.strip() and not l.endswith('lpu_mem_srf_tb.sv')]
            sources += [ROOT/'rtl/mem_native/mem_c7_primitive_adapter.sv']+[ROOT/'sim/mem_p1'/n for n in
                        ['runtime_checker.sv','leaf_bind.sv','control_bind.sv','entry_checks.sv']]+[HERE/'integration_tb.sv']
            sim=common.compile_sim(out,str(work.relative_to(out)/'rtl'),sources,'mem_profiles_integration_tb',[f'PROFILE={profile}'])
            res=common.simulate(out,sim,'closed_loop',['VECTORS='+vector.as_posix()],timeout=1800)
            common.save(work/'reference_identity.json',{str(p):common.sha(p) for p in [target,header,
                HERE/'integration_reference.cpp',work/'reference.exe',cm/'include/ftlpu/mem/mem_array.hpp']})
            results.append(dict(profile=profile,status='passed',result=res,vector_sha256=common.sha(vector),
                                scope='real MEM + persistent SRF H2/F52/K2; c7raw upstream adapter; full 00/FF only'))
        except Exception as e:
            results.append(dict(profile=profile,status='failed',error=str(e),work=str(work)))
            print('INTEGRATION',profile,'FAILED',str(e),flush=True)
        common.save(result_path,results)
    return results


def collisions(out, selected):
    results=[]
    for profile in [16,32,64]:
        if selected and str(profile) not in selected: continue
        sources=[ROOT/l.strip() for l in (ROOT/'sim/filelist_mem_srf.f').read_text().splitlines()
                 if l.strip() and not l.endswith('lpu_mem_srf_tb.sv')]
        sources += [ROOT/'sim/mem_p1'/n for n in ['runtime_checker.sv','leaf_bind.sv','control_bind.sv','entry_checks.sv']]
        sources += [HERE/'collision_tb.sv']
        try:
            attempt=1
            while (out/f'collisions/{profile}_attempt{attempt}').exists(): attempt+=1
            work=common.compile_sim(out,f'collisions/{profile}_attempt{attempt}',sources,'mem_profiles_collision_tb',[f'PROFILE={profile}'])
            res=common.simulate(out,work,'multiplicity')
            results.append(dict(profile=profile,status='passed',result=res))
        except Exception as e:
            results.append(dict(profile=profile,status='failed',error=str(e)))
        common.save(out/'collision_results.json',results)
    return results


def safety(out):
    import zipfile
    sys.path.insert(0,str(ROOT/'sim/mem_p1'))
    import verify
    # Original dirty T4 RTL is immutable in the preimplementation archive.
    with zipfile.ZipFile(out/'preimplementation_sources.zip') as z:
        for rel in common.CORE:
            p=out/'before'/rel;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes(z.read('FTLPU-VMODEL/'+rel))
    common.baseline(out,False)
    common.baseline(out,True)
    # Historical functional codec/mask fixtures are immutable inputs, not new
    # three-profile evidence. Record their hashes separately and replay current RTL.
    prior=ROOT/'build/mem_p1/mem_20261019_s01_s05_r1/reference'
    fixture_identity={}
    for depth in [64,8192,32768]:
        dest=out/f'reference/{depth}';dest.mkdir(parents=True,exist_ok=True)
        for name in ['codec.txt','codec_active64.txt','masks.txt']:
            source=prior/str(depth)/name
            if source.exists():
                shutil.copy2(source,dest/name);fixture_identity[str(source)]=common.sha(source)
    common.save(out/'legacy_fixture_identity.json',fixture_identity)
    verify.units(out,'safety_units')
    verify.safety(out,'safety_checks')
    verify.parameters(out,'safety_parameters')
    return [dict(name='legacy_safety',status='passed')]


def history(out):
    cm=ROOT.parent/'FTLPU-CMODEL';work=out/'cmodel_legacy';work.mkdir()
    tool=common.read(out/'tools.json')
    common.required([tool['cmake'],'-S',cm,'-B',work,'-G','MinGW Makefiles',
        '-DCMAKE_CXX_COMPILER=F:/mingw64/bin/g++.exe','-DCMAKE_MAKE_PROGRAM=F:/mingw64/bin/mingw32-make.exe',
        '-DCMAKE_BUILD_TYPE=Debug','-DCMAKE_CXX_FLAGS_DEBUG=-O1 -g0','-DCMAKE_EXE_LINKER_FLAGS=-static'],work,work/'configure.txt')
    targets=['mxm_bf16_test','mxm_decode_streamed_weight_test','mxm_decode_layout_comparison_test','mem_sync_read_test']
    results=[]
    for target in targets:
        build=common.execute([tool['cmake'],'--build',work,'--target',target,'--parallel','2'],work,work/(target+'_build.txt'),1200)
        result=None
        if build['exit']==0:
            result=common.execute([work/(target+'.exe')],work,work/(target+'_run.txt'),240)
        results.append(dict(name=target,status='build_failed' if build['exit'] else 'passed' if result['exit']==0 else 'historical_failure_reproduced',build=build,result=result))
        common.save(out/'cmodel_historical_results.json',results)
        print(target,results[-1]['status'],flush=True)
    return results


def codec(out):
    cm=ROOT.parent/'FTLPU-CMODEL';tool=common.read(out/'tools.json');results=[]
    for profile,depth in [(16,1024),(32,2048),(64,2048)]:
        work=out/f'codec/{profile}';work.mkdir(parents=True)
        try:
            header=work/'include/ftlpu/core/hardware_config.hpp'
            target=cm/f'config/mem-profiles/ftlpu-lpu{profile}.json'
            common.required([tool['cmake'],'-DCMODEL='+cm.as_posix(),'-DINPUT_JSON='+target.as_posix(),
                '-DOUTPUT_HEADER='+header.as_posix(),'-P',ROOT/'sim/mem_p1/configure_reference.cmake'],work,work/'configure.txt')
            common.required([tool['compiler'],'-std=c++20','-O2','-static','-I'+str(work/'include'),
                '-I'+str(cm/'include'),HERE/'codec_reference.cpp','-o',work/'codec.exe'],work,work/'compile.txt')
            for active in [depth,depth//2]:
                vector=work/f'e{active}.txt'
                common.required([work/'codec.exe',vector,str(active)],work,work/f'e{active}_reference.txt')
                sim=common.compile_sim(out,f'codec/{profile}/e{active}',
                    [ROOT/'rtl/mem_native/mem_c7_primitive_adapter.sv',HERE/'codec_tb.sv'],
                    'mem_profiles_codec_tb',[f'DEPTH={depth}',f'ACTIVE={active}'])
                res=common.simulate(out,sim,'codec',['VECTORS='+vector.as_posix()])
                results.append(dict(profile=profile,physical_rows=depth,active_rows=active,status='passed',result=res,vector_sha256=common.sha(vector)))
                common.save(out/'codec_results.json',results)
        except Exception as e:
            results.append(dict(profile=profile,status='failed',error=str(e)))
            common.save(out/'codec_results.json',results)
    return results


def mutations(out):
    """Require rejection of corrupted comparisons and product copies.

    Mutants exist only under the RunId; never patch product RTL or its golden.
    """
    attempt=1
    while (out/f'mutations_attempt{attempt}').exists(): attempt+=1
    work=out/f'mutations_attempt{attempt}';work.mkdir()
    prefix=work.relative_to(out)
    candidates=sorted((out/'integration').glob('16_attempt*/vectors.txt'),key=lambda p:p.stat().st_mtime)
    vector=candidates[-1]
    fl=ROOT/'sim/filelist_mem_srf.f'
    sources=[ROOT/l.strip() for l in fl.read_text().splitlines() if l.strip() and not l.endswith('lpu_mem_srf_tb.sv')]
    sources += [ROOT/'rtl/mem_native/mem_c7_primitive_adapter.sv']+[ROOT/'sim/mem_p1'/n for n in
                ['runtime_checker.sv','leaf_bind.sv','control_bind.sv','entry_checks.sv']]
    base=common.compile_sim(out,str(prefix/'base'),sources+[HERE/'integration_tb.sv'],
                            'mem_profiles_integration_tb',['PROFILE=16'])
    common.simulate(out,base,'legal_control',['VECTORS='+vector.as_posix()])
    results=[]
    def record(name,res,path):
        results.append(dict(name=name,status='passed',meaning='expected rejection captured',result=res,
                            mutant=str(path),mutant_sha256=common.sha(path)))
        common.save(out/'mutation_results.json',results)
    # Mutate expected state only, keeping all issue/boundary stimuli unchanged.
    original=vector.read_text().splitlines()
    cursor=1
    while cursor<len(original) and not original[cursor].startswith('END'):
        seq,reset,ni,nb,ns,nr,nc=map(int,original[cursor].split())
        index=cursor+1+ni+nb
        if ns: break
        cursor=index+ns+nr+nc
    for name,field,operation,error in [
        ('flip_byte',5,lambda x:format(int(x,16)^1,'x'),'integration SRF byte'),
        ('wrong_tile',3,lambda x:str(1-int(x)),'integration SRF state valid'),
        ('wrong_stream',4,lambda x:'31','integration SRF state valid')]:
        lines=original.copy();fields=lines[index].split();fields[field]=operation(fields[field]);lines[index]=' '.join(fields)
        mutant=work/(name+'.txt');mutant.write_text('\n'.join(lines)+'\n')
        res=common.simulate(out,base,name,['VECTORS='+mutant.as_posix()],failure=error)
        record(name,res,mutant)
    # Delete one PRE or POST response expectation, not an issue or data input.
    native_vector=sorted((out/'profiles').glob('16_attempt*/directed_l2.txt'),key=lambda p:p.stat().st_mtime)[-1]
    native_sources=[ROOT/p for p in common.CORE]+[ROOT/'sim/mem_p1'/n for n in
                    ['runtime_checker.sv','leaf_bind.sv','control_bind.sv','sync_tb.sv']]
    native=common.compile_sim(out,str(prefix/'native'),native_sources,'mem_p1_sync_tb',
                              ['DEPTH=1024','ACTIVE=1024','TILES=2'])
    for name,phase in [('delete_pre_valid',0),('delete_post_valid',1)]:
        lines=native_vector.read_text().splitlines();cursor=1
        while not lines[cursor].startswith('END'):
            fields=list(map(int,lines[cursor].split()));seq,reset,ni,ns,ne,np,nr,nc=fields
            index=cursor+1+ni+ns+ne+(np if phase else 0)
            if (nr if phase else np):
                fields[6 if phase else 5]-=1;lines[cursor]=' '.join(map(str,fields));del lines[index];break
            cursor+=1+ni+ns+ne+np+nr+nc
        mutant=work/(name+'.txt');mutant.write_text('\n'.join(lines)+'\n')
        res=common.simulate(out,native,name,['VECTORS='+mutant.as_posix()],failure='MEM_SYNC response valid')
        record(name,res,mutant)
    product=ROOT/'rtl/integration/lpu_mem_srf_integration.sv';text=product.read_text()
    for name,error in [('drop_second_producer','lost multiplicity'),('delay_consume','integration SRF state valid')]:
        if name=='drop_second_producer':
            before="srf_inject_valid[srf_slot_cell+STREAMS] = 1'b1;"
            assert text.count(before)==1
            mutated=text.replace(before,"srf_inject_valid[srf_slot_cell+STREAMS] = 1'b0;")
            top='mem_profiles_collision_tb';tb=HERE/'collision_tb.sv'
        else:
            mutated=text.replace('  ftlpu_sr_hemisphere_fabric #(',
                '  logic [SRF_CONSUME_CELLS-1:0] mutation_delayed_consume;\n'
                '  always_ff @(posedge clk_i or negedge rst_ni)\n'
                "    if(!rst_ni) mutation_delayed_consume <= '0; else mutation_delayed_consume <= srf_consume;\n"
                '  ftlpu_sr_hemisphere_fabric #(').replace('.consume_i(srf_consume)', '.consume_i(mutation_delayed_consume)')
            top='mem_profiles_integration_tb';tb=HERE/'integration_tb.sv'
        mutant=work/(name+'.sv');mutant.write_text(mutated)
        altered=[mutant if p==product else p for p in sources]+[tb]
        sim=common.compile_sim(out,str(prefix/name),altered,top,['PROFILE=16'])
        plus=['VECTORS='+vector.as_posix()] if name=='delay_consume' else []
        res=common.simulate(out,sim,name,plus,failure=error)
        record(name,res,mutant)
    return results


def supplement(out):
    sys.path.insert(0,str(ROOT/'sim/mem_p1'))
    import verify
    verify.legacy_default(out,'legacy32768')
    verify.filelists(out,'native_filelists')
    # Establish whether the extra SXM adapter failure is new or pre-existing.
    sources=[]
    with zipfile.ZipFile(out/'preimplementation_sources.zip') as z:
        for line in (ROOT/'sim/filelist_sxm_command_adapter.f').read_text().splitlines():
            rel=line.strip()
            if not rel:continue
            p=out/'before_sxm'/rel;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes(z.read('FTLPU-VMODEL/'+rel));sources.append(p)
    sim=common.compile_sim(out,'known_sxm_baseline',sources,'lpu_sxm_command_adapter_tb')
    tool=common.read(out/'tools.json')
    res=common.execute([tool['xsim'],'mem_sim','-runall'],sim,sim/'run.txt')
    text=(sim/'run.txt').read_text(errors='replace')
    if res['exit']!=0 or 'ERROR illegal map' not in text or 'TEST_FAIL errors=1' not in text:
        raise RuntimeError('SXM baseline failure differs; inspect '+str(sim/'run.txt'))
    common.save(out/'sxm_baseline_failure.json',dict(status='baseline_failure_reproduced',
        diagnostic='ERROR illegal map; TEST_FAIL errors=1',result=res,
        scope='unchanged preimplementation SXM command adapter path; not fixed by MEM task'))
    return [dict(name='supplement',status='passed')]


def configuration(out):
    results=[]
    attempt=1
    while (out/f'configuration_attempt{attempt}').exists(): attempt+=1
    prefix=Path(f'configuration_attempt{attempt}')
    sources=[ROOT/l.strip() for l in (ROOT/'sim/filelist_mem_srf.f').read_text().splitlines()
             if l.strip() and not l.endswith('lpu_mem_srf_tb.sv')]+[HERE/'geometry_tb.sv']
    cases=[('legacy0',['PROFILE=0'],None),
           ('lpu16',['PROFILE=16','LEGACY_GROUP=2'],None),
           ('lpu32',['PROFILE=32','LEGACY_GROUP=2'],None),
           ('lpu64',['PROFILE=64','LEGACY_GROUP=2'],None),
           ('bad_slots',['PROFILE=16','SLOTS=1'],'parameter contract violation'),
           ('bad_tile',[],'supports P_TILE_ROWS=2/4/8 only')]
    for name,generics,error in cases:
        top='mem_profiles_bad_tile_tb' if name=='bad_tile' else 'mem_profiles_geometry_tb'
        sim=common.compile_sim(out,str(prefix/name),sources,top,generics)
        res=common.simulate(out,sim,'run',failure=error)
        results.append(dict(name=name,status='passed',expected_rejection=bool(error),result=res))
        common.save(out/'configuration_results.json',results)
    # Invalid profile must fail explicitly, never silently become LPU32.
    try:
        sim=common.compile_sim(out,str(prefix/'bad_profile'),sources,'mem_profiles_geometry_tb',['PROFILE=99'])
    except RuntimeError:
        # Invalid profiles map to zero dimensions, so XSim may reject them
        # structurally before executing the explicit initial parameter guard.
        # Accept only this observed diagnostic, not arbitrary build failures.
        sim=out/prefix/'bad_profile'
        log=sim/'elaborate.txt'
        text=log.read_text(errors='replace') if log.exists() else ''
        if '[VRFC 10-1220] part-select has a negative or zero size' not in text:
            raise
        results.append(dict(name='bad_profile',status='passed',expected_rejection=True,
                            phase='elaboration',diagnostic='VRFC 10-1220: invalid profile zero dimensions',log=str(log)))
        common.save(out/'configuration_results.json',results)
        return results
    tool=common.read(out/'tools.json')
    res=common.execute([tool['xsim'],'mem_sim','-runall'],sim,sim/'run.txt')
    text=(sim/'run.txt').read_text(errors='replace')
    if 'Fatal:' not in text or not any(x in text for x in
        ['illegal MEM P_LPU_PROFILE','unsupported MEM group profile','FTLPU_DEFAULT_4T8L','supports P_TILE_ROWS=2/4/8']):
        raise RuntimeError('invalid profile was not rejected by parameter checks: '+str(sim/'run.txt'))
    results.append(dict(name='bad_profile',status='passed',expected_rejection=True,result=res))
    common.save(out/'configuration_results.json',results)
    return results


def legacy_profiles(out):
    results=[]
    sources=[ROOT/l.strip() for l in (ROOT/'sim/filelist_mem_command_adapter.f').read_text().splitlines()
             if l.strip() and not l.endswith('lpu_mem_command_adapter_tb.sv')]+[HERE/'legacy_profile_tb.sv']
    for profile in [16,32,64]:
        work=common.compile_sim(out,f'legacy_profiles/{profile}',sources,'mem_profiles_legacy_tb',[f'PROFILE={profile}'])
        res=common.simulate(out,work,'run')
        results.append(dict(profile=profile,status='passed',result=res))
        common.save(out/'legacy_profile_results.json',results)
    return results


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('stage', choices=['prepare','legacy','profiles','integration','collisions','safety','history','codec','mutations','supplement','configuration','legacy_profiles'])
    p.add_argument('--run-id', required=True)
    p.add_argument('--select', nargs='*')
    p.add_argument('--seeds', type=int, default=16)
    args = p.parse_args()
    if not common.re.fullmatch(r'[A-Za-z0-9_-]+',args.run_id):
        p.error('invalid RunId')
    out = ROOT/'build/mem_profiles'/args.run_id
    if args.stage=='prepare':
        prepare(out)
        sys.exit(0)
    if not (out/'baseline_manifest.json').is_file():
        p.error('capture preimplementation source identity first')
    tools(out)
    if args.stage=='legacy': result=legacy(out,args.select)
    elif args.stage=='profiles': result=profiles(out,args.select,args.seeds)
    elif args.stage=='integration': result=integration(out,args.select)
    elif args.stage=='collisions': result=collisions(out,args.select)
    elif args.stage=='safety': result=safety(out)
    elif args.stage=='history': result=history(out)
    elif args.stage=='codec': result=codec(out)
    elif args.stage=='mutations': result=mutations(out)
    elif args.stage=='supplement': result=supplement(out)
    elif args.stage=='configuration': result=configuration(out)
    else: result=legacy_profiles(out)
    latest = {x.get('name',(x.get('profile'),x.get('case'),x.get('stage'))): x for x in result}
    sys.exit(1 if any(x['status'] != 'passed' for x in latest.values()) else 0)
