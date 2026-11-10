"""Sample regression after removing MEM native ZeroFill (not full sign-off).

Uses frozen c7 functional vectors and the previously adapted synchronous-read
reference. CModel sources and cross-module interfaces are not modified.
"""
import argparse
import json
import re
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
import run
import verify
import sync_run

PRIOR_SYNC = run.ROOT / 'build/mem_p1/mem_20261019_s06_s07_r1'


def regression(out):
    assert (out / 'manifest_before.json').is_file(), 'snapshot before editing first'
    for depth in [64, 8192]:
        shutil.copytree(PRIOR_SYNC / 'reference' / str(depth), out / 'reference' / str(depth))
    results = []
    # Compare identical Error-mode stimuli before and after policy removal.
    run.baseline(out)
    run.baseline(out, True)
    verify.legacy_default(out, 'sample')

    work = run.compile_sim(out, 'sample/unit', verify.SOURCES + verify.CHECKERS +
                           [run.HERE / 'unit_tb.sv'], 'mem_p1_unit_tb')
    masks = sync_run.PRIOR / 'reference/64/masks.txt'
    results.append(run.simulate(out, work, 'functional', ['CASE=0', 'MASKS=' + masks.as_posix()],
                                'MEM_UNIT TEST_PASS'))
    for case, message in [(4, 'unknown MEM segment valid'), (5, 'unknown valid MEM write payload')]:
        results.append(run.simulate(out, work, 'unknown_' + str(case), ['CASE=' + str(case)], failure=message))
    for name, top, tb in [('safety', 'mem_p1_fault_tb', 'fault_tb.sv'),
                          ('group', 'mem_p1_group_collision_tb', 'fault_tb.sv'),
                          ('active', 'mem_p1_active_depth_tb', 'active_depth_tb.sv')]:
        work = run.compile_sim(out, 'sample/' + name, verify.SOURCES + verify.CHECKERS +
                               [run.HERE / tb], top)
        results.append(run.simulate(out, work, 'functional'))
    # Representative illegal configuration; parameter policy is no longer an API.
    work = run.compile_sim(out, 'sample/bad_active', verify.SOURCES + verify.CHECKERS +
                           [run.HERE / 'parameter_tops.sv'], 'mem_bad_active_nonpower')
    results.append(run.simulate(out, work, 'reject', failure='illegal MEM physical/active depth'))
    run.save(out / 'sample_local_results.json', results)

    case = next(c for c in run.read(sync_run.PRIOR / 'rtl_v1_full_results.json')
                if c['name'] == 'rtl_v1_p64_e64_z0_directed')
    vector = next(Path(a[8:]) for a in case['result']['command'] if a.startswith('VECTORS='))
    assert run.sha(vector) == case['vector_sha256']
    work = run.compile_sim(out, 'sample_l1/p64_e64_error', verify.SOURCES + verify.CHECKERS +
                           [run.HERE / 'full_tb.sv'], 'mem_p1_full_64_tb')
    result = run.simulate(out, work, 'directed', ['VECTORS=' + vector.as_posix()], 'MEM_FULL TEST_PASS')
    run.save(out / 'sample_l1_result.json', dict(result=result, vector_sha256=run.sha(vector),
             coverage=case['coverage'], reference='frozen original c7; L1 only'))

    sync_run.rtl(out, 'sample_l2', sample=True)
    cases = run.read(out / 'sample_l2_results.json')
    case = next(c for c in cases if c['name'] == 'rtl_v1_p64_e64_z0_directed')
    source = next(Path(a[8:]) for a in case['result']['command'] if a.startswith('VECTORS='))
    lines = source.read_text().splitlines()
    header = lines[0].split()
    assert header[0] == 'MEM_SYNC' and header[4] == '0'
    header[4] = '1'
    lines[0] = ' '.join(header)
    target = out / 'rejected_zero_policy.txt'
    target.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    work = out / 'sample_l2/p64_e64_z0'
    rejection = run.simulate(out, work, 'reject_zero_reference', ['VECTORS=' + target.as_posix()],
                             failure='MEM vector/config identity mismatch')
    run.save(out / 'sample_reference_rejection.json', rejection)
    finish(out)


def finish(out):
    before = run.read(out / 'manifest_before.json')
    changed = {rel: dict(before=digest, after=run.sha(run.ROOT / rel))
               for rel, digest in before['vm'].items() if run.sha(run.ROOT / rel) != digest}
    for rel, digest in before['cm'].items():
        assert run.sha(run.CM / rel) == digest, 'CModel changed: ' + rel
    allowed = {'rtl/mem_native/' + name + '.sv' for name in [
        'mem_bank_superlane_leaf', 'mem_logical_bank_column', 'mem_slice', 'mem_group', 'mem_hemisphere']}
    assert all(rel in allowed or rel.startswith(('sim/mem_p1/', 'spec_new_c7ae225/')) for rel in changed), changed
    for p in (run.ROOT / 'rtl').rglob('*.sv'):
        assert 'P_MEM_ZERO_FILL' not in p.read_text(encoding='utf-8'), str(p)
    # All compiled identities must still describe the current files or immutable baseline.
    identities = list(out.rglob('source_identity.json'))
    for identity in identities:
        for path, digest in run.read(identity).items():
            assert run.sha(path) == digest, 'compiled source changed: ' + path
    for depth in [64, 8192]:
        ref = out / 'reference' / str(depth)
        identity = run.read(ref / 'identity.json')
        for key, path in [('exe_sha256', ref / 'sync_reference.exe'),
                          ('config_sha256', ref / 'target.json'),
                          ('header_sha256', ref / 'include/ftlpu/core/hardware_config.hpp'),
                          ('driver_sha256', run.HERE / 'sync_reference.cpp'),
                          ('model_sha256', run.CM / 'include/ftlpu/mem/mem_array.hpp')]:
            assert run.sha(path) == identity[key], 'reference changed: ' + str(path)
    cycles = sum(c['coverage']['cycles'] for c in run.read(out / 'sample_l2_results.json'))
    local = run.read(out / 'sample_local_results.json')
    l2 = run.read(out / 'sample_l2_results.json')
    assert len(l2) == 3 and all(c['result']['pass_'] for c in l2)
    assert all(c['pass_'] for c in local)
    assert run.read(out / 'sample_l1_result.json')['result']['pass_']
    assert run.read(out / 'sample_reference_rejection.json')['pass_']
    added = {p.relative_to(run.ROOT).as_posix(): run.sha(p)
             for directory in ['rtl', 'sim/mem_p1', 'spec_new_c7ae225', 'scripts']
             for p in (run.ROOT / directory).rglob('*')
             if p.is_file() and p.relative_to(run.ROOT).as_posix() not in before['vm']}
    assert all(rel.startswith('sim/mem_p1/') for rel in added), added
    run.save(out / 'summary.json', dict(
        status='PASS', scope='sample regression only; not complete S07 or integration acceptance',
        policy='Error only; no RTL policy parameter', cmodel_unchanged=True,
        rtl_changed=sorted(rel for rel in changed if rel.startswith('rtl/')),
        protected_srf_integration_unchanged=True, l2_suites=3, l2_frames=cycles,
        compiled_source_identities=len(identities), baseline_16_32=run.read(out / 'baseline_compatibility.json'),
        baseline_32768=run.read(out / 'sample_legacy_default_results.json'),
        mask_reference_sha256=run.sha(sync_run.PRIOR / 'reference/64/masks.txt'),
        l1_result=run.read(out / 'sample_l1_result.json'),
        local_results=local, l2_results=l2,
        negative_reference=run.read(out / 'sample_reference_rejection.json'), changed=changed, added=added))
    print('MEM_ERROR_ONLY_SAMPLE TEST_PASS frames=' + str(cycles), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--finish', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
        parser.error('invalid RunId')
    out = run.ROOT / 'build/mem_p1' / args.run_id
    (finish if args.finish else regression)(out)
