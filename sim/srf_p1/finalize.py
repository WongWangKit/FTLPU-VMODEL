"""Evidence accounting, explicit caller success markers, acceptance matrix."""
import argparse
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode=True
import accept as a
import run as prep

def caller_accounting(out):
    rows=prep.read(out/'caller_results.json');result=[]
    for row in rows:
        item=dict(filelist=row['filelist'],versions=[],classification=row['classification'])
        observations=[]
        for version in row['versions']:
            r=version['result'];specific=None
            if row['filelist']=='sim/filelist_mem_srf_multigroup_align.f' and r.get('log'):
                text=Path(r['log']).read_text(encoding='utf-8',errors='replace')
                markers=['MULTIGROUP_PRELOAD PASS','MULTIGROUP_E0_E15_ALIGNED PASS','MULTIGROUP_NO_COLLISION PASS',
                    'MULTIGROUP_TILE_PIPELINE_ALIGNMENT PASS','PHASE4A_PREVIOUS_BLOCKER_INVALID']
                # This TB intentionally has no TEST_PASS string. Its errors==0
                # branch emits these markers, while errors!=0 emits the blocker.
                # Preserve the original generic-marker FAIL and account for
                # actual published TB semantics, not a relaxed data assertion.
                passed=r['exit']==0 and all(m in text for m in markers) and 'CAPTURE_CYCLES tile0=28 tile1=29 tile2=30 tile3=31' in text and 'ARCHITECTURE_BLOCKER_CONFIRMED' not in text and not re.search(r'Fatal:|FATAL|TEST_FAIL|ERROR:',text)
                specific=dict(pass_=passed,required_markers=markers,capture_cycles=[28,29,30,31],
                    reason='TB errors==0 branch and exact named checks; generic TEST_PASS marker does not exist',
                    source_sha256=prep.sha((a.BASE/'baseline_source' if version['version']=='old' else a.ROOT)/'sim/tb/lpu_mem_srf_multigroup_align_tb.sv'))
            passed=specific['pass_'] if specific else r['pass_']
            item['versions'].append(dict(version=version['version'],pass_=passed,raw_result=r,specific_marker_accounting=specific))
            if r.get('log'):
                text=Path(r['log']).read_text(encoding='utf-8',errors='replace')
                observations.append([s.strip() for s in text.splitlines() if ('PASS' in s and not s.startswith('COMMAND')) or 'TEST_FAIL' in s or s.startswith(('ERROR','CAPTURE_CYCLES','CYCLE L=','PHASE4A_'))])
            else:observations.append([])
        passes=[v['pass_'] for v in item['versions']]
        item['classification']='PASS_BOTH' if all(passes) else 'NEW_REGRESSION' if passes[0] else 'BASELINE_OR_SHARED_FAILURE'
        item['named_observations_equal']=observations[0]==observations[1]
        if item['classification']=='BASELINE_OR_SHARED_FAILURE' and item['named_observations_equal']:
            item['classification']='REPRODUCED_PREEXISTING_FAILURE_NOT_PASS'
        result.append(item)
    prep.save(out/'caller_accounting.json',dict(source_sha256=prep.sha(Path(__file__)),entries=result,
        pass_pairs=sum(r['classification']=='PASS_BOTH' for r in result),total=len(result),
        note='Original generic-marker results retained. Explicit source-specific classification is not a rewrite of TB checks or golden. Default xelab timescale 1ns/1ps used for both old and new.'))
    return result

def main(out):
    a.check_identity(out)
    lanes=prep.read(out/'lane_results.json');diag=prep.read(out/'diagnostic_results.json');legacy=prep.read(out/'legacy_results.json')
    source_map=prep.read(out/'provenance_results.json');extra=prep.read(out/'supplemental_lane.json');z=prep.read(out/'z_results.json');mutation=prep.read(out/'checker_mutation.json')
    compiler=prep.read(out/'compiler_boundary_audit.json');callers=caller_accounting(out)
    masks=lanes[0]['coverage']['masks'];fullcoords=lanes[0]['coverage']['injected_coordinates']
    random=[r for r in lanes if r['coverage']['seed'] is not None]
    lane_ok=len(lanes)==17 and all(r['result']['pass_'] for r in lanes) and len(random)==16 and all(r['coverage']['cycles']>=1000 and r['coverage']['negative']==0 for r in random)
    diag_ok=len(diag)==18 and all(r['pass_'] for r in diag) and all(r['pass_'] for r in z)
    legacy_ok=legacy['raw_traces_identical'] and all(r['result']['pass_'] and r['comparison']['pass_'] for r in legacy['results'])
    extra_ok=extra['pass_'] and mutation['result']['pass_'] and source_map['pass_'] and len(source_map['suites'])==17
    compiler_ok=compiler['sha']=='7219b674eb482110a5f582735c0c6c7d2c6b63e6' and compiler['status']==''
    identity_ok=[]
    for p in prep.SRF:
        old=(a.BASE/'baseline_source'/p).read_text();new=(a.ROOT/p).read_text();name=Path(p).stem
        pattern=r'module '+name+r'\s*#\([\s\S]*?\);'
        identity_ok.append(re.search(pattern,old)[0]==re.search(pattern,new)[0])
    matrix={}
    for n in range(1,34):
        test=f'A{n:02d}'
        if n in [18,19,21,28]:ok=diag_ok and lane_ok and (masks==list(range(256)))
        elif n in [26,30]:ok=legacy_ok and all(identity_ok)
        elif n==31:ok=compiler_ok
        elif n==33:ok=lane_ok and extra_ok and fullcoords==65536
        elif n==29:ok=lane_ok and extra_ok
        else:ok=lane_ok
        matrix[test]=dict(status='PASS_BOUNDED' if ok else 'INCOMPLETE',
            evidence=['lane_results.json','diagnostic_results.json','z_results.json'] if n in [18,19,21,28] else ['legacy_results.json'] if n in [26,30] else ['compiler_boundary_audit.json'] if n==31 else ['lane_results.json','provenance_results.json','supplemental_lane.json'] if n in [29,33] else ['lane_results.json'])
    all_required=all(x['status']=='PASS_BOUNDED' for x in matrix.values())
    report=dict(matrix=matrix,all_required_bounded_tests_pass=all_required,
        lane_cycles=sum(r['coverage']['cycles'] for r in lanes),lane_negative=sum(r['coverage']['negative'] for r in lanes),
        random_seeds=[r['coverage']['seed'] for r in random],random_cycles=sum(r['coverage']['cycles'] for r in random),
        state_bytes=sum(r['result']['counts'][2] for r in lanes),boundary_bytes=sum(r['result']['counts'][3] for r in lanes),
        directed_injected_coordinates=fullcoords,directed_masks=len(masks),diagnostic_runs=len(diag),z_runs=len(z),
        supplemental_pass=extra_ok,legacy_pass=legacy_ok,caller_pass_pairs=sum(r['classification']=='PASS_BOTH' for r in callers),caller_total=len(callers),
        caller_preexisting_failures=[r['filelist'] for r in callers if r['classification']=='REPRODUCED_PREEXISTING_FAILURE_NOT_PASS'],
        caller_new_regressions=[r['filelist'] for r in callers if r['classification']=='NEW_REGRESSION'],
        rtl=prep.read(out/'manifest.json')['rtl'],source_identity={p.relative_to(a.ROOT).as_posix():prep.sha(p) for p in a.HERE.iterdir() if p.is_file()},
        powershell_entry_sha256=prep.sha(a.ROOT/'scripts/run_srf_acceptance.ps1'),
        source_revision=prep.git(a.ROOT,'rev-parse','HEAD'),source_diff=prep.git(a.ROOT,'diff','--','rtl/srf'),
        contract_sha256=prep.sha(a.ROOT/'spec_new_c7ae225/srf改造契约.md'),
        limitation='Fixed adjacent topology, payload/lane-valid projection and recorded input/tool domain only. Not exhaustive proof, all software APIs, physical timing or full-system equivalence.',
        formal='NOT_RUN_OPTIONAL',cross_simulator='NOT_VERIFIED_SECOND_TOOL_UNAVAILABLE',
        optimized_results=prep.read(out/'optimization_results.json'),startup_checker_fix='Simulation-only assertions arm after observing reset; datapath/latency unchanged.',
        optimization_variants=prep.read(out/'optimization_variants.json') if (out/'optimization_variants.json').exists() else None,
        adapter_isolation=prep.read(out/'adapter_isolation.json') if (out/'adapter_isolation.json').exists() else None,
        overall_signoff='BOUNDED_O0_RESULTS_ONLY; optimization discrepancies and preexisting caller failures remain open; no unqualified sign-off',
        primary_configuration='XSim 2023.2 --O0; caller pairs additionally use default timescale 1ns/1ps',
        unqualified_acceptance_pass=False,
        earlier_failure_evidence=str(a.ROOT/'build/srf_p1/srf_20261018_full_r1'))
    prep.save(out/'acceptance_matrix.json',report)
    print('SRF_REQUIRED_BOUNDED_TESTS',all_required,'CALLERS',report['caller_pass_pairs'],'/',len(callers),flush=True)
    if not all_required or any(r['classification'] not in ['PASS_BOTH','REPRODUCED_PREEXISTING_FAILURE_NOT_PASS'] for r in callers):
        raise RuntimeError('incomplete or new regression; do not claim all pass')
    if report['caller_preexisting_failures']:
        print('CALLER_CHECK_COMPLETE_WITH_PREEXISTING_FAILURES_NOT_ALL_PASS',report['caller_preexisting_failures'],flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-id',required=True);args=p.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+',args.run_id):raise SystemExit('unsafe run-id')
    main(a.ROOT/'build/srf_p1'/args.run_id)
