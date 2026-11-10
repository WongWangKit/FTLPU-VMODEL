"""Supplemental SRF evidence: provenance, mixed helper, Z, checker mutation, O2."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode=True
import accept as a
import run as prep

def provenance(out):
    summaries=[]
    for path in sorted((out/'lane_vectors').glob('*.cases.json')):
        rows=prep.read(path);state={};signature=hashlib.sha256();checked=0
        for row in rows:
            if row['reset']:state={}
            consumed=set()
            for h,d,c,t,k,s,mask,api in row['c']:
                for l in range(8):
                    q=(h,d,c,t,s,l)
                    if(mask>>l)&1 and (api!=2 or q in state):consumed.add(q)
            candidates={}
            def put(q,item):candidates.setdefault(q,[]).append(item)
            for q,item in state.items():
                if q in consumed:continue
                h,d,c,t,s,l=q;dest=c+(1 if d==0 else -1)
                if 0<=dest<16:put((h,d,dest,t,s,l),item)
            for e in row['b']:
                h,d,t,s,mask,data,api=e;c=0 if d==0 else 15
                for l in range(8):
                    if(mask>>l)&1:put((h,d,c,t,s,l),((data>>(8*l))&255,('B',row['epoch'],row['seq'],h,d,c,t,s,l,api)))
            for e in row['i']:
                h,d,c,t,p,s,mask,data,api=e
                for l in range(8):
                    if(mask>>l)&1:put((h,d,c,t,s,l),((data>>(8*l))&255,('P',row['epoch'],row['seq'],h,d,c,t,p,s,l,api)))
            next_state={q:v[0] for q,v in candidates.items() if len(v)==1}
            expected,_,_,_=a.oracle({q:v[0] for q,v in state.items()},row)
            if {q:v[0] for q,v in next_state.items()}!=expected:raise RuntimeError('source mapping disagreement')
            for q,(value,origin) in sorted(next_state.items()):
                signature.update(repr((row['seq'],q,value,origin)).encode('ascii'));checked+=1
            state=next_state
        summaries.append(dict(cases=path.name,input_sha256=prep.sha(path),cycles=len(rows),source_mapped_cells=checked,source_map_digest=signature.hexdigest()))
    prep.save(out/'provenance_results.json',dict(pass_=True,source_sha256=prep.sha(Path(__file__)),suites=summaries,
        limitation='Diagnostic source mapping at the verification side. No hardware tags; byte collisions do not prove arbitrary whole-program provenance. Exact coordinate/input mapping remains reproducible from cases and this script.'))

def extra_lane(out):
    v=out/'supplemental';v.mkdir(exist_ok=False)
    q=a.Suite()
    for h in range(2):
        for d in range(2):
            q.add('mixed_helper_warm',True,i=[(h,d,6,3,0,31,0x55,0x123456789abcdef0,1)],ids=['A29'])
            q.add('consume_cell_all_including_invalid',c=[(h,d,6,3,0,31,0xff,2)],ids=['A29','A22'])
            q.add('helper_dual_read_warm',True,i=[(h,d,4,1,0,7,0xaa,0xaabbccddeeff0011,5)])
            q.add('two_conditional_consumers',c=[(h,d,4,1,0,7,0xff,2),(h,d,4,1,1,7,0xff,2)],ids=['A07','A29'])
    q.save(v,'mixed_helper');compiled=v/'mixed_helper.vectors'
    prep.required([out/'lane_reference.exe',v/'mixed_helper.input',compiled],out,v/'reference.txt')
    r=a.simulate(out,out/'lane_sim','supplemental_helper',['VECTORS='+compiled.as_posix()],'SRF_LANE TEST_PASS')
    prep.save(out/'supplemental_lane.json',r)
    if not r['pass_']:raise RuntimeError('mixed helper failure')

def z_checks(out):
    source=out/'z_wrapper.sv'
    source.write_text('''`timescale 1ns/1ps
module srf_z_wrapper;
  srf_p1_diagnostic_tb sub();
  integer c;
  initial begin
    if(!$value$plusargs("CASE=%d",c))$fatal(1,"CASE missing");
    #31;
    case(c)
      3: force sub.up[0]=1'bz;
      4: force sub.inject[0]=1'bz;
      5: force sub.consume[0]=1'bz;
      6: force sub.ud[7:0]='z;
      7: force sub.data_in[7:0]='z;
      8: force sub.rst_n=1'bz;
    endcase
    $display("Z_DIAGNOSTIC_ARMED case=%0d",c);
  end
endmodule
''',encoding='utf-8')
    work,ok=a.compile_sim(out,'z_sim',[a.ROOT/p for p in prep.SRF]+[a.HERE/'diagnostic_tb.sv',source],'srf_z_wrapper')
    if not ok:raise RuntimeError('Z wrapper compile')
    results=[]
    for case in range(3,9):
        message='unknown valid/consume control' if case<6 else 'unknown valid upstream payload' if case==6 else 'unknown valid injection payload' if case==7 else 'unknown reset'
        r=a.simulate(out,work,'z_'+str(case),['CASE='+str(case)],'',message)
        if 'Z_DIAGNOSTIC_ARMED' not in Path(r['log']).read_text():r['pass_']=False
        results.append(r)
    prep.save(out/'z_results.json',results)
    if not all(r['pass_'] for r in results):raise RuntimeError('Z failure')

def mutation(out):
    source=out/'lane_vectors/directed.vectors';lines=source.read_text().splitlines();pos=0;changed=False;seq=None;coordinate=None
    while pos<len(lines):
        header=lines[pos].split();nb,ni,nc,nbo,npost=map(int,header[2:7]);start=pos+1+nb+ni+nc+nbo
        for j in range(npost):
            fields=lines[start+j].split();mask=int(fields[5],16)
            if mask:
                lane=(mask&-mask).bit_length()-1;data=int(fields[6],16);fields[6]=format(data^(1<<(8*lane)),'x');lines[start+j]=' '.join(fields)
                changed=True;seq=int(header[0]);coordinate=list(map(int,fields[:5]))+[lane];break
        if changed:break
        pos=start+npost
    if not changed:raise RuntimeError('no mutation target')
    target=out/'checker_mutation.vectors';target.write_text('\n'.join(lines)+'\n',encoding='ascii')
    r=a.simulate(out,out/'lane_sim','checker_mutation',['VECTORS='+target.as_posix()],'','state byte mismatch')
    cases=prep.read(out/'lane_vectors/directed.cases.json');state={}
    for row in cases[:seq]:state=a.oracle(state,row)[0]
    context=dict(epoch=cases[seq]['epoch'],cycle=seq,coordinate=coordinate,input=cases[seq],
        prestate={str(q):v for q,v in state.items()},result=r,mutation='one expected valid byte flipped; original golden untouched',
        original_sha256=prep.sha(source),mutation_sha256=prep.sha(target))
    prep.save(out/'checker_mutation.json',context)
    if not r['pass_']:raise RuntimeError('checker failed to catch injected expected-byte error')

def optimized(out):
    results=[]
    # Current lane implementation: same directed vectors, optimized executable.
    w,ok=a.compile_sim(out,'optimized_lane',[a.ROOT/p for p in prep.SRF]+[a.HERE/'lane_compare_tb.sv'],'srf_p1_lane_compare_tb',opt='--O2')
    if ok:
        r=a.simulate(out,w,'directed',['VECTORS='+(out/'lane_vectors/directed.vectors').as_posix()],'SRF_LANE TEST_PASS',timeout=900)
    else:r=dict(pass_=False,reason='optimized lane elaboration failure')
    results.append(dict(test='current_lane_O2_directed',result=r))
    # Reproduce the old optimization-sensitive failure without changing old
    # source or expected results; select the first seven original input cycles.
    repro=out/'old_O2_reproducer';repro.mkdir(exist_ok=False)
    rows=prep.read(a.BASE/'cases.json')[:7];prep.save(repro/'cases.json',rows)
    with (repro/'vectors.txt').open('w',encoding='ascii') as f:
        for row in rows:
            f.write(f"{row['seq']} {row['reset']} {len(row['b'])} {len(row['i'])} {len(row['c'])}\n")
            for e in row['b']+row['i']:f.write(' '.join(map(str,e[:-1]))+f' {e[-1]:016x}\n')
            for e in row['c']:f.write(' '.join(map(str,e))+'\n')
    with (a.BASE/'expected.txt').open() as src,(repro/'expected.txt').open('w') as dst:
        for _ in rows:dst.write(src.readline())
    w,ok=a.compile_sim(out,'optimized_old',[a.BASE/'baseline_source'/p for p in prep.SRF]+[a.HERE/'legacy_trace_tb.sv'],'srf_p1_legacy_trace_tb',opt='--O2')
    trace=w/'trace.txt'
    if ok:
        r=a.simulate(out,w,'seven_cycles',['VECTORS='+(repro/'vectors.txt').as_posix(),'TRACE='+trace.as_posix()],'SRF_P1_LEGACY_TRACE PASS')
        if r['pass_']:
            try:r['comparison']=prep.compare(repro,trace)
            except Exception as e:r.update(pass_=False,projection_error=str(e))
    else:r=dict(pass_=False,reason='old O2 elaboration')
    results.append(dict(test='unchanged_old_O2_first7',result=r))
    prep.save(out/'optimization_results.json',dict(tests=results,
        conclusion='Optimization configurations are reported independently; passing O0 does not erase any O2 failure. This investigation alone is not a root-cause proof.'))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-id',required=True);args=p.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+',args.run_id):raise SystemExit('unsafe run-id')
    out=a.ROOT/'build/srf_p1'/args.run_id;a.check_identity(out)
    extra_lane(out);z_checks(out);mutation(out);optimized(out);provenance(out)
