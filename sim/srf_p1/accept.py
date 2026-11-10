"""SRF contract steps 6/7. Preserves the immutable step-5 runner/evidence."""
import argparse
import importlib.util
import itertools
import json
import random
import re
import shutil
from pathlib import Path
import sys
sys.dont_write_bytecode=True
import run as prep

ROOT,HERE,CM=prep.ROOT,prep.HERE,prep.CM
BASE=ROOT/'build/srf_p1/srf_20261017_steps1_5_r5'
SEEDS=[0x53524600+i for i in range(16)]
NEW=['accept.py','lane_reference.cpp','lane_compare_tb.sv','diagnostic_tb.sv','filelist_lane.f']
def packed(q):
    h,d,c,t,s,l=q;return (((((h*2+d)*16+c)*4+t)*32+s)*8+l)
def fault(q):
    h,d,c,t,s,l=q;return ((h*2+d)*16+c)*4+t
def value(epoch,beat,q,source=0):
    h,d,c,t,s=q
    x=(epoch*0x9e3779b1+beat*0x85ebca77+h*101+d*53+c*17+t*37+s*13+source*73)&0xffffffff
    return sum((((x^(x>>11)^((l+1)*0x45d9f3b))+(l*29))&255)<<(l*8) for l in range(8))
def oracle(state,row):
    if row['reset']:state={}
    consumed=set();bad=0;candidates={};bo={}
    for h,d,c,t,k,s,mask,api in row['c']:
        for l in range(8):
            q=(h,d,c,t,s,l)
            if not (mask>>l)&1:continue
            if api==2 and q not in state:continue
            consumed.add(q)
            if q not in state:bad|=1<<fault(q)
    def put(q,v):candidates.setdefault(q,[]).append(v)
    for q,v in state.items():
        if q in consumed:continue
        h,d,c,t,s,l=q;dest=c+(1 if d==0 else -1)
        if 0<=dest<16:put((h,d,dest,t,s,l),v)
        else:bo[q]=v
    for h,d,t,s,mask,data,api in row['b']:
        for l in range(8):
            if (mask>>l)&1:put((h,d,0 if d==0 else 15,t,s,l),(data>>(8*l))&255)
    seen=set()
    for h,d,c,t,p,s,mask,data,api in row['i']:
        physical=(h,d,c,t,p,s)
        if physical in seen:raise RuntimeError('duplicate physical source record')
        seen.add(physical)
        for l in range(8):
            if (mask>>l)&1:put((h,d,c,t,s,l),(data>>(8*l))&255)
    nxt={};col=0
    for q,vs in candidates.items():
        if len(vs)==1:nxt[q]=vs[0]
        else:col|=1<<fault(q)
    return nxt,col,bad,bo

class Suite:
    def __init__(self):self.rows=[];self.state={};self.epoch=0
    def add(self,name,reset=False,b=(),i=(),c=(),negative=False,ids=()):
        reset=reset or (bool(self.rows) and self.rows[-1]['negative'])
        if reset:self.epoch+=1
        r=dict(seq=len(self.rows),name=name,reset=int(reset),b=list(b),i=list(i),c=list(c),negative=negative,ids=list(ids),epoch=self.epoch)
        nxt,col,inv,bo=oracle(self.state,r)
        if bool(col or inv)!=negative:raise RuntimeError('illegal generator case '+name)
        self.rows.append(r);self.state=nxt
    def all_consume(self):
        grouped={}
        for h,d,c,t,s,l in self.state:grouped[(h,d,c,t,s)]=grouped.get((h,d,c,t,s),0)|(1<<l)
        return [(h,d,c,t,0,s,m,0) for (h,d,c,t,s),m in grouped.items()]
    def save(self,out,name):
        path=out/(name+'.input');coverage={'cycles':len(self.rows),'negative':sum(r['negative'] for r in self.rows),'case_ids':sorted({a for r in self.rows for a in r['ids']}),'seed':None}
        injected=set();consumed=set();masks=set();slots=set()
        with path.open('w',encoding='ascii') as f:
            for r in self.rows:
                f.write(f"{r['seq']} {r['reset']} {len(r['b'])} {len(r['i'])} {len(r['c'])} {int(r['negative'])}\n")
                for e in r['b']:
                    f.write(' '.join(map(str,e[:4]))+f' {e[4]:x} {e[5]:x} {e[6]}\n');masks.add(e[4])
                for e in r['i']:
                    f.write(' '.join(map(str,e[:6]))+f' {e[6]:x} {e[7]:x} {e[8]}\n');masks.add(e[6]);slots.add(e[4])
                    for l in range(8):
                        if (e[6]>>l)&1:injected.add(tuple(e[:4])+(e[5],l))
                for e in r['c']:
                    f.write(' '.join(map(str,e[:6]))+f' {e[6]:x} {e[7]}\n')
                    for l in range(8):
                        if(e[6]>>l)&1:consumed.add(tuple(e[:4])+(e[5],l))
        coverage.update(injected_coordinates=len(injected),consume_coordinates=len(consumed),masks=sorted(masks),producer_slots=sorted(slots),input_sha256=prep.sha(path))
        prep.save(out/(name+'.cases.json'),self.rows);prep.save(out/(name+'.coverage.json'),coverage)
        return coverage

def directed():
    q=Suite();q.add('empty_reset',True,ids=['A01','A05'])
    for m in range(256):
        q.add('mask_'+str(m),True,i=[(0,0,5,1,m%2,7,m,value(1,m,(0,0,5,1,7)),[0,1,3,4,5][m%5])],ids=['A21','A29'])
    coords=list(itertools.product(range(2),range(2),range(16),range(4),range(32)))
    for p in range(2):
        for l in range(8):
            inj=[(h,d,c,t,p,s,1<<l,value(2,len(q.rows),(h,d,c,t,s),p),0) for h,d,c,t,s in coords]
            q.add(f'walking_all_coords_p{p}_l{l}',i=inj,c=q.all_consume(),ids=['A06','A07','A08','A10','A11','A12','A33'])
    for m in [0x0f,0xf0,0x55,0xaa,0xff,0]:
        q.add('mixed_target_'+str(m),i=[(h,d,c,t,(c+t)%2,s,((m<<(s%8))|(m>>(8-s%8)))&255,value(3,len(q.rows),(h,d,c,t,s)),1) for h,d,c,t,s in coords],c=q.all_consume(),ids=['A11','A12','A27'])
    q.add('clear_before_boundary',True,ids=['A01'])
    for tick in range(24):
        b=[(h,d,t,s,[0x0f,0xf0,0x55,0xaa,0xff,0][(tick+h+t+s)%6],value(4,tick,(h,d,0 if d==0 else 15,t,s)),1) for h,d,t,s in itertools.product(range(2),range(2),range(4),range(32))]
        con=[]
        for h,d,c,t,s,l in q.state:
            if c==(15 if d==0 else 0) and (l+tick)%2==0:con.append((h,d,c,t,0,s,1<<l,0))
        con=merge_consumes(con)
        q.add('boundary_pipeline_'+str(tick),b=b,c=con,ids=['A02','A03','A04','A09','A13','A22','A27'])
    for t in range(18):q.add('drain_'+str(t),ids=['A03','A04','A05'])
    for h,d in itertools.product(range(2),range(2)):
        for m in [0x0f,0x55,0x01,0x80]:
            c=6;t=3;s=31;v=value(5,len(q.rows),(h,d,c,t,s));other=255^m
            q.add('disjoint_producers',True,i=[(h,d,c,t,0,s,m,v,1),(h,d,c,t,1,s,other,~v&((1<<64)-1),5)],ids=['A23','A33'])
            q.add('partial_dual_consume_and_replace',i=[(h,d,c,t,0,s,m,v^0x123456789abcdef0,0)],c=[(h,d,c,t,0,s,m,0),(h,d,c,t,1,s,m,0)],ids=['A07','A08','A22'])
            q.add('reset_partial',True,ids=['A01'])
            src=4 if d==0 else 11;dst=src+(1 if d==0 else -1)
            q.add('warm_partial_link',i=[(h,d,src,t,0,s,m,v,0)])
            q.add('link_disjoint_inject',i=[(h,d,dst,t,0,s,other,~v&((1<<64)-1),1)],ids=['A24'])
        for c in [0,7,15]:
            for l in range(8):
                for same in [False,True]:
                    v=value(6,len(q.rows),(h,d,c,3,31));w=v if same else ~v&((1<<64)-1)
                    q.add(f'single_lane_collision_{h}_{d}_{c}_{l}_{same}',True,i=[(h,d,c,3,0,31,255,v,0),(h,d,c,3,1,31,1<<l,w,1),(1-h,1-d,8,0,0,0,0x55,v,3)],negative=True,ids=['A14','A25'])
        for l in range(8):
            src=3 if d==0 else 12;dst=src+(1 if d==0 else -1);v=value(7,l,(h,d,src,2,17))
            q.add('warm_collision_link',True,i=[(h,d,src,2,0,17,255,v,0)])
            q.add('link_single_lane_collision',i=[(h,d,dst,2,0,17,1<<l,v,0)],negative=True,ids=['A15','A25'])
            edge=0 if d==0 else 15
            q.add('boundary_disjoint',True,b=[(h,d,2,17,0x55,v,1)],i=[(h,d,edge,2,0,17,0xaa,v,0)],ids=['A24'])
            q.add('boundary_overlap',True,b=[(h,d,2,17,255,v,0)],i=[(h,d,edge,2,0,17,1<<l,v,0)],negative=True,ids=['A15','A25'])
        q.add('warm_invalid_consume',True,i=[(h,d,5,1,0,2,0x55,0x123456789abcdef0,1)])
        q.add('invalid_and_collision_same_cycle',c=[(h,d,5,1,0,2,0xaa,0)],i=[(1-h,1-d,9,3,0,31,255,71,0),(1-h,1-d,9,3,1,31,1,71,0)],negative=True,ids=['A16','A17'])
        q.add('conditional_invalid_read',True,c=[(h,d,5,1,0,2,255,2)],ids=['A29'])
        for api in [0,1,2,3,4,5,6]:
            m=255 if api in [2,6] else 0x55
            q.add('api_write_'+str(api),True,i=[(h,d,5,1,0,2,m,value(8,api,(h,d,5,1,2)),api)],ids=['A29'])
            q.add('api_consume',c=[(h,d,5,1,0,2,255 if m==255 else m,1 if m==255 else 2)],ids=['A29'])
        q.add('low_half',True,i=[(h,d,5,1,0,2,0x0f,0x123456789abcdef0,1)],ids=['A32'])
        q.add('high_half_next_cycle',i=[(h,d,5,1,0,2,0xf0,0xfedcba9876543210,1)],ids=['A32','A27'])
    q.add('final_reset',True,ids=['A01']);return q

def merge_consumes(events):
    grouped={}
    for *coords,mask,api in events:
        k=tuple(coords)+(api,);grouped[k]=grouped.get(k,0)|mask
    return [(*k[:-1],mask,k[-1]) for k,mask in grouped.items()]

def random_suite(seed):
    q=Suite();rng=random.Random(seed)
    for cycle in range(1000):
        groups={}
        for h,d,c,t,s,l in q.state:groups[(h,d,c,t,s)]=groups.get((h,d,c,t,s),0)|(1<<l)
        con=[]
        for (h,d,c,t,s),mask in groups.items():
            if rng.randrange(3)==0:
                picked=mask&rng.randrange(256)
                if picked:con.append((h,d,c,t,rng.randrange(2),s,picked,0))
        r=dict(reset=cycle==0,b=[],i=[],c=con)
        provisional,_,_,_=oracle(q.state,r)
        occupied={}
        for h,d,c,t,s,l in provisional:occupied[(h,d,c,t,s)]=occupied.get((h,d,c,t,s),0)|(1<<l)
        inj=[];b=[]
        for attempt in range(32):
            h,d,c,t,s=rng.randrange(2),rng.randrange(2),rng.randrange(16),rng.randrange(4),rng.randrange(32)
            key=(h,d,c,t,s);free=255^occupied.get(key,0);mask=rng.randrange(256)&free
            # Select only legal free lanes before producing the command. No
            # generated illegal vector is discarded or silently reclassified.
            if mask==0:continue
            if any(tuple(e[:4])+(e[5],)==key for e in inj):continue
            p=rng.randrange(2);api=rng.choice([0,1,3,4,5]);data=value(seed,cycle,key,p)
            inj.append((h,d,c,t,p,s,mask,data,api));occupied[key]=occupied.get(key,0)|mask
            if rng.randrange(4)==0:
                other=(255^occupied[key])&rng.randrange(256)
                if other:
                    inj.append((h,d,c,t,1-p,s,other,value(seed,cycle,key,1-p),1));occupied[key]|=other
        for attempt in range(2):
            h,d,t,s=rng.randrange(2),rng.randrange(2),rng.randrange(4),rng.randrange(32);c=0 if d==0 else 15
            key=(h,d,c,t,s);mask=rng.randrange(256)&(255^occupied.get(key,0))
            if mask and not any((e[0],e[1],e[2],e[3])==(h,d,t,s) for e in b):
                b.append((h,d,t,s,mask,value(seed,cycle,key,2),1));occupied[key]=occupied.get(key,0)|mask
        q.add('seed_'+str(seed)+'_cycle_'+str(cycle),reset=cycle==0,b=b,i=inj,c=con,ids=['A20','A27','A33'])
    return q

def check_identity(out):
    m=prep.read(out/'manifest.json')
    for p,h in m['rtl'].items():
        if prep.sha(ROOT/p)!=h:raise RuntimeError('RTL changed after acceptance preparation: '+p)
    for p,h in m['verification'].items():
        if prep.sha(ROOT/p)!=h:raise RuntimeError('verification changed: '+p)
    if prep.git(CM,'rev-parse','HEAD')!=prep.CM_SHA or prep.git(CM,'status','--porcelain','--untracked-files=no'):raise RuntimeError('reference identity changed')
    return m

def compile_sim(out,name,sources,top,opt='--O0',default_timescale=False):
    sources=prep.with_srf_checkers(sources)
    tools=prep.read(out/'tools.json');work=out/name;work.mkdir(parents=True,exist_ok=False)
    steps=[]
    for label,args in [('compile',[tools['xvlog.bat'],'--sv',*sources]),('elaborate',[tools['xelab.bat'],top,'-s','accept_sim','--debug','typical',opt,*(['--timescale','1ns/1ps'] if default_timescale else [])])]:
        r=prep.execute(args,work,work/(label+'.txt'),300);steps.append(r)
        if r['exit']!=0:
            prep.save(work/'compile_result.json',dict(pass_=False,steps=steps));return work,False
    prep.save(work/'compile_result.json',dict(pass_=True,steps=steps));return work,True
def simulate(out,work,name,plus,marker,expected_failure=None,timeout=600):
    tools=prep.read(out/'tools.json');log=work/(name+'.txt')
    r=prep.execute([tools['xsim.bat'],'accept_sim','-runall',*[v for p in plus for v in ['-testplusarg',p]]],work,log,timeout)
    text=log.read_text(encoding='utf-8',errors='replace')
    if expected_failure:
        ok=not r['timeout'] and expected_failure in text and re.search(r'(?:Fatal:|FATAL|\$fatal)',text) is not None and 'UNEXPECTED_' not in text
    else:
        ok=r['exit']==0 and marker in text and re.search(r'(?:Fatal:|FATAL|TEST_FAIL|ERROR:)',text) is None
    r.update(pass_=bool(ok),expected_failure=expected_failure,marker=marker)
    prep.save(work/(name+'.result.json'),r);print(name,'PASS' if ok else 'FAIL',flush=True);return r

def prepare(out):
    out.mkdir(parents=True,exist_ok=False)
    if prep.git(CM,'rev-parse','HEAD')!=prep.CM_SHA or prep.git(CM,'status','--porcelain','--untracked-files=no'):raise RuntimeError('CModel must be clean fixed commit')
    prep.probe(out)
    tools=prep.read(out/'tools.json')
    if not tools['xvlog.bat']:raise RuntimeError('XSim required by this local acceptance entry; original Icarus probe retained')
    cfg=out/'generated/include/ftlpu/core/hardware_config.hpp'
    prep.required([tools['cmake'],'-DCMODEL='+CM.as_posix(),'-DOUTPUT_HEADER='+cfg.as_posix(),'-P',HERE/'configure_reference.cmake'],out,out/'configure.txt')
    prep.required([tools['g++'],'-std=c++20','-O2','-static','-I'+str(out/'generated/include'),'-I'+str(CM/'include'),HERE/'lane_reference.cpp','-o',out/'lane_reference.exe'],out,out/'reference_compile.txt')
    inventory=prep.inventory();prep.save(out/'inventory.json',inventory)
    verification_files=[p for p in HERE.iterdir() if p.is_file()]
    verification_files.extend(ROOT/p for p in prep.SRF_CHECKER_FILES)
    prep.save(out/'manifest.json',dict(reference_sha=prep.CM_SHA,rtl={p:prep.sha(ROOT/p) for p in prep.SRF},
        verification={p.relative_to(ROOT).as_posix():prep.sha(p) for p in verification_files},
        config_sha256=prep.sha(cfg),reference_exe_sha256=prep.sha(out/'lane_reference.exe'),params=prep.PARAMS,seeds=SEEDS,
        source_start_sha=prep.git(ROOT,'rev-parse','HEAD'),source_diff=prep.git(ROOT,'diff','--','rtl/srf'),contract_sha256=prep.sha(ROOT/'spec_new_c7ae225/srf改造契约.md')))
    print('ACCEPTANCE_PREPARED',out,flush=True)

def lane(out):
    check_identity(out);vectors=out/'lane_vectors';vectors.mkdir(exist_ok=False)
    work,ok=compile_sim(out,'lane_sim',[ROOT/p for p in prep.SRF]+[HERE/'lane_compare_tb.sv'],'srf_p1_lane_compare_tb')
    if not ok:raise RuntimeError('lane TB compile/elaborate failed')
    summaries=[]
    for name,seed in [('directed',None)]+[('seed_'+str(s),s) for s in SEEDS]:
        suite=directed() if seed is None else random_suite(seed)
        coverage=suite.save(vectors,name);coverage['seed']=seed;prep.save(vectors/(name+'.coverage.json'),coverage)
        compiled=vectors/(name+'.vectors')
        prep.required([out/'lane_reference.exe',vectors/(name+'.input'),compiled],out,vectors/(name+'.reference.txt'))
        result=simulate(out,work,name,['VECTORS='+compiled.as_posix()],'SRF_LANE TEST_PASS',timeout=900)
        log=Path(result['log']).read_text(encoding='utf-8',errors='replace')
        matched=re.search(r'SRF_LANE TEST_PASS cycles=(\d+) negative=(\d+) state_bytes=(\d+) boundary_bytes=(\d+)',log)
        if not matched or int(matched[1])!=coverage['cycles']:result['pass_']=False
        if matched:result['counts']=list(map(int,matched.groups()))
        summaries.append(dict(name=name,coverage=coverage,result=result,vectors_sha256=prep.sha(compiled)))
        prep.save(out/'lane_results.json',summaries)
        if not result['pass_']:
            m=re.search(r'cycle=(\d+)',log)
            if m:
                seq=int(m[1]);prep.save(out/'first_divergence.json',dict(input=suite.rows[seq],previous_input=suite.rows[seq-1] if seq else None,log=result['log']))
            raise RuntimeError('lane suite failed '+name)
    print('LANE_ALL_COMPLETE',flush=True)

def diagnostics(out):
    check_identity(out)
    work,ok=compile_sim(out,'diagnostic_sim',[ROOT/p for p in prep.SRF]+[HERE/'diagnostic_tb.sv'],'srf_p1_diagnostic_tb')
    if not ok:raise RuntimeError('diagnostics compile')
    results=[]
    for case in range(9):
        expected={2:'partial/unknown mask on legacy',3:'unknown valid/consume control',4:'unknown valid/consume control',5:'unknown valid/consume control',6:'unknown valid upstream payload',7:'unknown valid injection payload',8:'unknown reset'}.get(case)
        r=simulate(out,work,'case_'+str(case),['CASE='+str(case)],'TEST_PASS',expected);results.append(r)
    # Constant invalid parameters must fail at time zero, independently of data.
    definitions=[];tops=[]
    for mod,param in [('ftlpu_sr_superlane_col_dir_lane',p) for p in ['STREAMS','LANES','DATA_BITS','LOCAL_PRODUCERS','LOCAL_CONSUMERS']]+[
        ('ftlpu_sr_column_dir_lane','SUPERLANES'),('ftlpu_sr_direction_fabric_lane','COLUMNS'),('ftlpu_sr_direction_fabric_lane','DIRECTION'),('ftlpu_sr_fabric_lane','HEMISPHERES')]:
        name='bad_'+param.lower();v=2 if param=='DIRECTION' else 0;tops.append(name)
        definitions.append(f'module {name}; {mod} #(.{param}({v})) dut(.clk_i(1\'b0),.rst_ni(1\'b0)); initial begin #10; $display("UNEXPECTED_PARAMETER_SUCCESS"); $finish; end endmodule')
    source=out/'bad_parameter_tops.sv';source.write_text('`timescale 1ns/1ps\n'+'\n'.join(definitions)+'\n',encoding='utf-8')
    for name in tops:
        w,ok=compile_sim(out,name,[ROOT/p for p in prep.SRF]+[source],name)
        if not ok:
            diagnostic=(w/'elaborate.txt').read_text(encoding='utf-8',errors='replace') if (w/'elaborate.txt').exists() else ''
            # DATA_BITS=0 is structurally rejected before runtime assertions.
            # Only this exact parameter-specific elaboration diagnostic counts.
            rejected=name=='bad_data_bits' and 'part-select has a negative or zero size' in diagnostic
            results.append(dict(pass_=rejected,top=name,phase='elaborate',expected_parameter_rejection=rejected,log=str(w/'elaborate.txt')));continue
        r=simulate(out,w,'reject',[],'', 'DIRECTION must be' if name=='bad_direction' else 'dimensions and slot counts must be positive');results.append(r)
    prep.save(out/'diagnostic_results.json',results)
    if not all(r['pass_'] for r in results):raise RuntimeError('diagnostic failure')

def callers(out):
    check_identity(out);results=[];snapshot=BASE/'baseline_source'
    for entry in prep.read(out/'inventory.json')['callers']:
        versions=[]
        for version,root in [('old',snapshot),('new',ROOT)]:
            w,ok=compile_sim(out,'callers/'+Path(entry['filelist']).stem+'/'+version,[root/p for p in entry['files']],entry['top'],default_timescale=True)
            if (root/'sim/vectors').is_dir():shutil.copytree(root/'sim/vectors',w/'sim/vectors')
            if ok:r=simulate(out,w,'run',[],'TEST_PASS',timeout=300)
            else:r=dict(pass_=False,reason='compile/elaborate')
            versions.append(dict(version=version,result=r))
        old,new=versions
        classification='PASS_BOTH' if old['result']['pass_'] and new['result']['pass_'] else 'NEW_REGRESSION' if old['result']['pass_'] else 'BASELINE_FAILURE_REQUIRES_CLASSIFICATION'
        results.append(dict(filelist=entry['filelist'],versions=versions,classification=classification))
        prep.save(out/'caller_results.json',results)
    if any(r['classification']=='NEW_REGRESSION' for r in results):raise RuntimeError('new caller regression')

def legacy(out):
    check_identity(out)
    results=[]
    for version,root in [('old',BASE/'baseline_source'),('new',ROOT)]:
        w,ok=compile_sim(out,'legacy_'+version,[root/p for p in prep.SRF]+[HERE/'legacy_trace_tb.sv'],'srf_p1_legacy_trace_tb')
        if not ok:raise RuntimeError('legacy elaboration')
        trace=w/'trace.txt';r=simulate(out,w,'run',['VECTORS='+(BASE/'vectors.txt').as_posix(),'TRACE='+trace.as_posix()],'SRF_P1_LEGACY_TRACE PASS')
        if not r['pass_']:raise RuntimeError('legacy simulation')
        # Compare without writing inside the frozen baseline directory.
        comp=prep.compare(BASE,trace);results.append(dict(version=version,result=r,comparison=comp,trace_sha256=prep.sha(trace)))
    prep.save(out/'legacy_results.json',dict(results=results,raw_traces_identical=results[0]['trace_sha256']==results[1]['trace_sha256']))

def audit(out):
    check_identity(out);soft=ROOT.parent/'FTLPU-SOFTWARE'
    paths=['compiler/include/ftlpu/compiler/Dialect/Schedule/Analysis/stream_fabric_scheduler.hpp',
        'compiler/src/Dialect/Schedule/Analysis/StreamFabricScheduler.cpp','compiler/src/Dialect/Schedule/Transforms/MatmulScheduleEmitter.cpp',
        'compiler/src/Dialect/Schedule/Transforms/StreamToSchedule.cpp','compiler/src/Dialect/Schedule/Transforms/VerifySchedule.cpp']
    files=[]
    for rel in paths:
        p=soft/rel;lines=p.read_text(encoding='utf-8').splitlines()
        matches=[dict(line=n+1,text=s.strip()) for n,s in enumerate(lines) if re.search(r'beat|token|consume|reserve|occup|lane',s,re.I)]
        files.append(dict(path=str(p),sha256=prep.sha(p),matches=matches))
    prep.save(out/'compiler_boundary_audit.json',dict(sha=prep.git(soft,'rev-parse','HEAD'),status=prep.git(soft,'status','--short'),files=files,
        conclusion='Static whole-beat reservation/token audit only. No lane-sharing optimization enabled here. Dedicated emitters are not assumed covered by the shared scheduler. Not a whole-program provenance proof.'))

def report(out):
    check_identity(out)
    result={}
    for name in ['lane_results','diagnostic_results','caller_results','legacy_results','compiler_boundary_audit']:
        p=out/(name+'.json');result[name]=prep.read(p) if p.exists() else None
    result['rtl_hashes']=prep.read(out/'manifest.json')['rtl']
    result['scope']='fixed linear SRF byte-payload/lane-valid; bounded tests only; not all APIs or whole chip'
    result['cross_simulator']='NOT_VERIFIED_ICARUS_UNAVAILABLE'
    result['formal']='NOT_RUN_OPTIONAL_D05_A'
    prep.save(out/'report.json',result);print('REPORT',out/'report.json',flush=True)

if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('stage',choices=['prepare','lane','diagnostics','callers','legacy','audit','report','all']);a.add_argument('--run-id',required=True);args=a.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+',args.run_id):raise SystemExit('unsafe run-id')
    out=ROOT/'build/srf_p1'/args.run_id
    stages=['prepare','lane','diagnostics','callers','legacy','audit','report'] if args.stage=='all' else [args.stage]
    for stage in stages:globals()[stage](out)
