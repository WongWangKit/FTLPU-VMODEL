"""Additional same-row timing, dependency and comparator-negative evidence."""
import argparse
from pathlib import Path
import sys
sys.dont_write_bytecode=True
import run

ROOT,HERE=run.ROOT,run.HERE


def timing(out):
    tools=run.read(out/'tools.json');results=[]
    sources=[ROOT/p for p in (HERE/'filelist_sync.f').read_text().splitlines() if p.strip()]
    for p,mode,top in [(64,0,'64'),(8192,0,'error')]:
        work=out/'timing_v1'/f'p{p}_z{mode}';work.mkdir(parents=True,exist_ok=False)
        header=out/'reference'/str(p)/'include';snapshot=out/'cmodel_before'
        exe=work/'original_timing.exe';original=work/'original.txt';vector=work/'sync.txt'
        run.required([tools['compiler'],'-std=c++20','-O2','-static','-I'+str(header),'-I'+str(snapshot/'include'),
            HERE/'sync_timing_input.cpp',snapshot/'src/mem/sram.cpp','-o',exe],work,work/'compile_reference.txt')
        run.save(work/'reference_identity.json',dict(original_base=run.CM_SHA,
            original_header_sha256=run.sha(snapshot/'include/ftlpu/mem/mem_array.hpp'),
            generator_sha256=run.sha(HERE/'sync_timing_input.cpp'),exe_sha256=run.sha(exe)))
        run.required([exe,'full',original,str(p),str(mode),'1296387328','1'],work,work/'original_generate.txt',900)
        run.required([out/'reference'/str(p)/'sync_reference.exe',original,vector],work,work/'adapted_replay.txt',900)
        sim=run.compile_sim(out,'timing_v1/'+f'p{p}_z{mode}'+'/rtl',sources,'mem_p1_sync_'+top+'_tb')
        result=run.simulate(out,sim,'timing',['VECTORS='+vector.as_posix()],'MEM_SYNC TEST_PASS',timeout=1800)
        results.append(dict(p=p,mode=mode,original_sha256=run.sha(original),vector_sha256=run.sha(vector),
                            coverage=run.read(str(vector)+'.coverage.json'),result=result))
        run.save(out/'timing_v1_results.json',results)


def mutation(out):
    source=out/'vectors/smoke_v1_rtl_v1_p64_e64_z0_directed.txt'
    lines=source.read_text().splitlines();cursor=1;changed=None
    for c in range(int(lines[0].split()[-1])):
        seq,reset,ni,ns,ne,np,nr,nc=map(int,lines[cursor].split());cursor+=1+ni+ns+ne
        if nr and changed is None:
            index=cursor+np;fields=lines[index].split();fields[-1]=format(int(fields[-1],16)^1,'x')
            lines[index]=' '.join(fields);changed=dict(cycle=c,phase='POST_A',source=fields[:8])
        cursor+=np+nr+nc
    assert changed is not None
    target=out/'mutation_sync_byte.txt';assert not target.exists();target.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    sources=[ROOT/p for p in (HERE/'filelist_sync.f').read_text().splitlines() if p.strip()]
    work=run.compile_sim(out,'mutation_v1',sources,'mem_p1_sync_64_tb')
    result=run.simulate(out,work,'wrong_post_response',['VECTORS='+target.as_posix()],failure='MEM_SYNC response metadata/byte')
    run.save(out/'mutation_v1_result.json',dict(result=result,changed=changed,original_sha256=run.sha(source),
                                               mutated_sha256=run.sha(target)))


def dependency(out):
    tools=run.read(out/'tools.json');work=out/'dependency_v1';work.mkdir(exist_ok=False)
    source=HERE/'sync_dependency.cpp';exe=work/'dependency.exe'
    run.required([tools['compiler'],'-std=c++20','-O2','-static','-I'+str(out/'reference/8192/include'),
                  '-I'+str(run.CM/'include'),source,run.CM/'src/mem/sram.cpp','-o',exe],work,work/'compile.txt')
    result=run.required([exe],work,work/'run.txt')
    assert 'MEM_SYNC_DEPENDENCY TEST_PASS' in (work/'run.txt').read_text()
    run.save(work/'identity.json',dict(source_sha256=run.sha(source),model_sha256=run.sha(run.CM/'include/ftlpu/mem/mem_array.hpp'),
                                      exe_sha256=run.sha(exe),result=result,scope='CModel unit only, not RTL SRF integration'))


def phase_negative(out):
    source=out/'vectors/smoke_v1_rtl_v1_p64_e64_z0_directed.txt'
    results=[]
    for phase in [0,1]:
        lines=source.read_text().splitlines();cursor=1;changed=None
        for cycle in range(int(lines[0].split()[-1])):
            header=cursor;fields=list(map(int,lines[header].split()))
            seq,reset,ni,ns,ne,np,nr,nc=fields;cursor+=1+ni+ns+ne
            count=np if phase==0 else nr
            if count:
                start=cursor+(0 if phase==0 else np)
                fields[5+phase]=0;lines[header]=' '.join(map(str,fields))
                del lines[start:start+count];changed=dict(cycle=cycle,phase=phase,removed=count);break
            cursor+=np+nr+nc
        assert changed is not None
        target=out/f'mutation_phase{phase}.txt';assert not target.exists()
        target.write_text('\n'.join(lines)+'\n',encoding='utf-8')
        # The immutable compiled P64 comparator is reused, not its prior PASS.
        result=run.simulate(out,out/'mutation_v1',f'wrong_phase_{phase}',
            ['VECTORS='+target.as_posix()],failure='MEM_SYNC response valid')
        results.append(dict(result=result,changed=changed,original_sha256=run.sha(source),mutated_sha256=run.sha(target)))
    run.save(out/'phase_negative_results.json',results)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('stage',choices=['timing','mutation','dependency','phase'])
    parser.add_argument('--run-id',required=True);args=parser.parse_args()
    {'timing':timing,'mutation':mutation,'dependency':dependency,'phase':phase_negative}[args.stage](ROOT/'build/mem_p1'/args.run_id)
