"""Final S06/S07 identity, scope and regression classification (no signoff)."""
import argparse
import collections
import difflib
import re
import shutil
import sys
from pathlib import Path
sys.dont_write_bytecode=True
import run

CM_CHANGES=['CMakeLists.txt','include/ftlpu/mem/mem_array.hpp','tests/unit/mem/mem_array_test.cpp']
CM_NEW=['tests/unit/mem/mem_sync_read_test.cpp']


def audit(out):
    before=run.read(out/'manifest_before.json');root=run.ROOT;cm=run.CM
    assert run.git(cm,'rev-parse','HEAD')==before['cmodel_base']==run.CM_SHA
    for rel,digest in before['cmodel_files'].items():
        assert run.sha(out/'cmodel_before'/rel)==digest,'original c7 snapshot modified: '+rel
    changed=[rel for rel,digest in before['cmodel_files'].items() if run.sha(cm/rel)!=digest]
    assert sorted(changed)==sorted(CM_CHANGES),changed
    assert set(run.git(cm,'diff','--name-only').splitlines())==set(CM_CHANGES)
    assert set(run.git(cm,'ls-files','--others','--exclude-standard').splitlines())==set(CM_NEW)
    for rel,digest in before['vm_files'].items():
        if rel!=before['contract']:assert run.sha(root/rel)==digest,'unexpected VM product/integration edit: '+rel
    contract=root/before['contract']
    assert contract.read_bytes().startswith((out/'contract_before.md').read_bytes())
    for rel,digest in before['prior_test_files'].items():
        if Path(rel).name not in ['sync_run.py','README.md']:
            assert run.sha(root/rel)==digest,'old S05 test changed: '+rel

    diff=''
    for rel in CM_CHANGES+CM_NEW:
        old=(out/'cmodel_before'/rel).read_text(encoding='utf-8') if rel in CM_CHANGES else ''
        new=(cm/rel).read_text(encoding='utf-8')
        diff+=''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/'+rel,tofile='b/'+rel))
        target=out/'cmodel_after'/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(cm/rel,target)
    (out/'cmodel_sync_read.patch').write_text(diff,encoding='utf-8')
    identities={}
    for manifest in out.rglob('source_identity.json'):
        if manifest.parent.name in ['cmodel_baseline','cmodel_adapted']:
            base=out/'cmodel_before' if manifest.parent.name=='cmodel_baseline' else cm
        else:base=None
        for name,digest in run.read(manifest).items():
            p=(base/name) if base else Path(name)
            assert run.sha(p)==digest,'compiled source mismatch: '+str(p)
        identities[manifest.relative_to(out).as_posix()]=run.sha(manifest)
    for p in [64,8192,32768]:
        ref=out/'reference'/str(p);identity=run.read(ref/'identity.json')
        assert identity['model_sha256']==run.sha(cm/'include/ftlpu/mem/mem_array.hpp')
        assert identity['driver_sha256']==run.sha(run.HERE/'sync_reference.cpp')
        assert identity['exe_sha256']==run.sha(ref/'sync_reference.exe')
        assert identity['header_sha256']==run.sha(ref/'include/ftlpu/core/hardware_config.hpp')
        assert identity['config_sha256']==run.sha(ref/'target.json')

    full=run.read(out/'l2_v1_results.json');timing=run.read(out/'timing_v1_results.json')
    assert len(full)==37 and len(timing)==3
    for record in full+timing:
        result=record['result'];assert result['pass_'] and result['exit']==0
        vector=next(Path(x[8:]) for x in result['command'] if x.startswith('VECTORS='))
        assert run.sha(vector)==record['vector_sha256']
        assert record['coverage']['l2_mem_boundary'] and not record['coverage']['rtl_srf']
        text=Path(result['log']).read_text(encoding='utf-8')
        assert 'MEM_SYNC TEST_PASS' in text and 'Fatal:' not in text
    for mode in [0,1]:
        random=[r for r in full if f'_z{mode}_seed_' in r['name']]
        assert len(random)==16 and all(r['coverage']['nonreset_cycles']>=1000 for r in random)
        assert sorted(int(r['name'].split('_seed_')[1]) for r in random)==list(range(0x4d454d00,0x4d454d10))
    totals={k:sum(r['coverage'][k] for r in full) for k in ['cycles','nonreset_cycles','reads','released','reset_canceled','consumes']}
    targeted={k:sum(r['coverage'][k] for r in timing) for k in totals}
    for name,count in [('regression_v1_unit_results.json',14),('regression_v1_safety_results.json',12),
                       ('regression_v1_parameter_results.json',14),('regression_v1_filelist_results.json',3)]:
        records=run.read(out/name);assert len(records)==count
        assert all(r.get('result',r)['pass_'] for r in records)
    assert run.read(out/'baseline_compatibility.json')['pass_']
    assert run.read(out/'regression_v1_legacy_default_results.json')['pass_']
    assert (out/'baseline_old/trace.txt').read_bytes()==(out/'baseline_new/trace.txt').read_bytes()
    assert (out/'regression_v1/legacy_default_old/trace.txt').read_bytes()==(out/'regression_v1/legacy_default_new/trace.txt').read_bytes()
    mutation=run.read(out/'mutation_v1_result.json');assert mutation['result']['pass_']
    assert run.sha(out/'vectors/smoke_v1_rtl_v1_p64_e64_z0_directed.txt')==mutation['original_sha256']
    phases=run.read(out/'phase_negative_results.json')
    assert len(phases)==2 and all(r['result']['pass_'] for r in phases)
    dependency=run.read(out/'dependency_v1/identity.json')
    assert dependency['model_sha256']==run.sha(cm/'include/ftlpu/mem/mem_array.hpp') and dependency['result']['exit']==0

    old=run.read(out/'cmodel_baseline/individual_results.json');new=run.read(out/'cmodel_adapted/individual_results.json')
    assert len(old)==57 and len(new)==58
    old_map={r['test']:r for r in old}
    regressions=[];persistent=[];improved=[]
    def diagnostic(r):
        path=r['build']['log'] if r['status']=='build_failure' else r['result']['log']
        text=Path(path).read_text(encoding='utf-8',errors='replace')
        lines=[line for line in text.splitlines() if any(s in line for s in ['error:', 'Assertion failed:', 'test failed:', 'comparison failed:', 'FU 3-D decoder', 'what():'])]
        return '\n'.join(lines)[:1500]
    for r in new:
        if r['test'] not in old_map:assert r['test']=='unit.mem.sync_read' and r['status']=='pass';continue
        prior=old_map[r['test']]
        if prior['status']=='pass' and r['status']!='pass':regressions.append(dict(test=r['test'],diagnostic=diagnostic(r)))
        elif prior['status']!='pass' and r['status']!='pass':persistent.append(dict(test=r['test'],
            before=prior['status'],after=r['status'],before_diagnostic=diagnostic(prior),after_diagnostic=diagnostic(r)))
        elif prior['status']!='pass' and r['status']=='pass':improved.append(r['test'])
    report=dict(before_counts=dict(collections.Counter(r['status'] for r in old)),
                after_counts=dict(collections.Counter(r['status'] for r in new)),
                newly_failed=regressions,persistent_failures=persistent,newly_passing=improved,
                added_test='unit.mem.sync_read',system_compatibility_pass=False,
                untested='seven slow kernel/model tests and SOFTWARE scheduling regression')
    run.save(out/'cmodel_regression_comparison.json',report)
    resumed=run.read(out/'resume_20261020_v1_results.json')
    assert len(resumed)==3 and all(r['result']['pass_'] for r in resumed)
    for record in resumed:
        result=record['result']
        vector=next(Path(x[8:]) for x in result['command'] if x.startswith('VECTORS='))
        assert run.sha(vector)==record['vector_sha256']
        log=Path(result['log']).read_text(encoding='utf-8')
        assert 'MEM_SYNC TEST_PASS' in log and 'Fatal:' not in log
    # Test failures remain explicit; do not convert all-CModel status to PASS.
    summary=dict(mem_boundary_l2_pass=True,rtl_regression_pass=True,full_suites=37,targeted_suites=3,
        main_totals=totals,targeted_totals=targeted,cmodel_regression=report,
        response_phases='PRE old response vs staged_read_responses; POST_A new response vs read_responses; no trace shift',
        source_identity_sets=len(identities),cmodel_base=run.CM_SHA,cmodel_patch_sha256=run.sha(out/'cmodel_sync_read.patch'),
        rtl_product_unchanged=True,srf_integration_unchanged=True,tool='XSim 2023.2 --O0; MinGW g++ C++20 assertions enabled',
        resumed_current_source_suites=3,
        deferred_cross_module_tests=[r['test'] for r in regressions],
        deferral='User explicitly deferred cross-module adaptation/interconnect corrections until MXM is fixed, 2026-10-20; failures remain failures',
        user_acceptance=False,rtl_srf_integrated=False,software_rescheduled=False,
        limits=['CModel/reference SR commit is not real RTL SRF verification','No lane adapter or candidate projection integration',
                'Illegal-cycle behavior uses approved standalone safety oracle, not CModel exception trace equivalence',
                'Historical all-CModel regression failures remain; no system or SOFTWARE compatibility signoff',
                'No XSim O1/O2, second simulator, FPGA/ASIC synthesis or PPA'])
    run.save(out/'summary.json',summary)
    run.save(out/'manifest_after.json',dict(cmodel_files={rel:run.sha(cm/rel) for rel in CM_CHANGES+CM_NEW},
        vm_test_files={p.relative_to(root).as_posix():run.sha(p) for p in run.HERE.rglob('*') if p.is_file()},
        contract_sha256=run.sha(contract),compiled_source_identities=identities,
        patch_sha256=run.sha(out/'cmodel_sync_read.patch')))
    print('MEM_SYNC_AUDIT complete; local L2/RTL PASS; CModel regression counts',report['after_counts'],
          'newly_failed',len(regressions),flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--run-id',required=True);args=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+',args.run_id):p.error('invalid run ID')
    audit(run.ROOT/'build/mem_p1'/args.run_id)
