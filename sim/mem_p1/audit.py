"""Audit an S01-S05 evidence set without rerunning or relabelling old tests."""
import argparse
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
import run


def audit(out):
    root = run.ROOT
    before = run.read(out / 'manifest_before.json')
    assert run.git(run.CM, 'rev-parse', 'HEAD') == run.CM_SHA
    assert not run.git(run.CM, 'status', '--porcelain', '--untracked-files=no')
    for rel, digest in before['reference_files'].items():
        assert run.sha(out / rel) == digest, 'original c7 snapshot changed: ' + rel
    for directory in ['include', 'src', 'config', 'cmake']:
        for p in (run.CM / directory).rglob('*'):
            if p.is_file():
                assert p.read_bytes() == (out / 'reference_source' / p.relative_to(run.CM)).read_bytes()

    contract = 'spec_new_c7ae225/mem修改契约.md'
    contract_before = out / 'before' / contract
    assert run.sha(contract_before) == before['protected'][contract]
    assert (root / contract).read_bytes().startswith(contract_before.read_bytes()), 'contract history rewritten'
    changed = [rel for rel, digest in before['protected'].items()
               if not (root / rel).is_file() or run.sha(root / rel) != digest]
    assert set(changed) == set(run.CORE + [contract]), 'unexpected edits: ' + repr(changed)
    additions = sorted(set(run.protected()) - set(before['protected']))
    assert additions == ['rtl/mem_native/mem_c7_primitive_adapter.sv', 'scripts/run_mem_p1.ps1'], additions

    interfaces = {}
    for rel in run.CORE:
        old = (out / 'before' / rel).read_text(encoding='utf-8')
        new = (root / rel).read_text(encoding='utf-8')
        pattern = r'module\s+(\w+)\s*#\((.*?)\)\s*\((.*?)\);'
        a, b = re.search(pattern, old, re.S), re.search(pattern, new, re.S)
        assert a and b and a[1] == b[1] and a[3] == b[3], 'MEM ports changed: ' + rel
        params = lambda s: re.findall(r'parameter\s+(\w+)\s*=\s*([^,\n]+)', s)
        op, np = params(a[2]), params(b[2])
        op = [(k, v.strip()) for k, v in op]
        np = [(k, v.strip()) for k, v in np]
        assert np[:len(op)] == op, 'original parameter order/default changed: ' + rel
        interfaces[rel] = dict(ports_unchanged=True, original_parameters_unchanged=True,
                              appended_parameters=np[len(op):])
    control = run.CORE[1]
    remove_checks = lambda s: re.sub(r'`ifndef SYNTHESIS.*?`endif', '', s, flags=re.S)
    assert remove_checks((out / 'before' / control).read_text()) == remove_checks((root / control).read_text())

    result_names = ['rtl_v1_full_results.json', 'unit_v2_unit_results.json',
                    'safety_v2_safety_results.json', 'safety_v2_parameter_results.json',
                    'filelists_v1_filelist_results.json']
    counts = [37, 14, 12, 14, 3]
    for name, count in zip(result_names, counts):
        results = run.read(out / name)
        assert len(results) == count
        for record in results:
            result = record.get('result', record)
            assert result['pass_'] and not result['timeout'], (name, record)
            assert Path(result['log']).is_file()
            log = Path(result['log']).read_text(encoding='utf-8', errors='replace')
            expected = result.get('failure') or result.get('expected_failure')
            if expected:
                assert expected in log and 'Fatal:' in log and 'UNEXPECTED_' not in log
            else:
                assert result['exit'] == 0 and 'TEST_PASS' in log
                assert not re.search(r'Fatal:|FATAL|TEST_FAIL|ERROR:', log)
    full = run.read(out / result_names[0])
    for record in full:
        vector = next(x[8:] for x in record['result']['command'] if x.startswith('VECTORS='))
        assert run.sha(vector) == record['vector_sha256']
        assert not record['coverage']['l2']
    for mode in [0, 1]:
        random = [r for r in full if f'p8192_e8192_z{mode}_seed_' in r['name']]
        assert len(random) == 16
        assert sorted(int(r['name'].split('_seed_')[1]) for r in random) == list(range(0x4d454d00, 0x4d454d10))
        assert all(r['coverage']['main_random_cycles'] == 1000 for r in random)
        assert all(sum(r['coverage'][k] for k in ['reads', 'writes', 'taps']) >= 1000 for r in random)
    totals = {k: sum(r['coverage'][k] for r in full) for k in
              ['cycles', 'main_random_cycles', 'reads', 'writes', 'taps', 'zero_fills', 'full_storage_signatures']}

    selected = [out / p for p in ['baseline_old', 'baseline_new', 'legacy_v1', 'unit_v2',
                'safety_v2', 'filelists_v1']]
    selected += [out / 'rtl_v1' / c for c in ['p8192_e8192_z0', 'p8192_e8192_z1',
                 'p64_e64_z0', 'p32768_e32768_z0', 'p8192_e64_z0']]
    identities = {}
    for directory in selected:
        for manifest in directory.rglob('source_identity.json'):
            values = run.read(manifest)
            for name, digest in values.items():
                assert run.sha(name) == digest, 'tested source changed: ' + name
            identities[manifest.relative_to(out).as_posix()] = run.sha(manifest)
    assert len(identities) >= 18
    full_list = [(root / p).resolve().as_posix() for p in
                 (run.HERE / 'filelist_full.f').read_text().splitlines() if p.strip()]
    assert full_list == (out / 'rtl_v1/p8192_e8192_z0/sources.f').read_text().splitlines()

    references = {}
    for depth in [64, 8192, 32768]:
        ref = out / 'reference' / str(depth)
        identity = run.read(ref / 'identity.json')
        assert identity['reference_sha'] == run.CM_SHA and not identity['cmodel_modified']
        for key, p in [('source_sha256', run.HERE / 'reference.cpp'), ('config_sha256', ref / 'target.json'),
                       ('generated_sha256', ref / 'include/ftlpu/core/hardware_config.hpp'), ('exe_sha256', ref / 'reference.exe')]:
            assert run.sha(p) == identity[key]
        config = run.read(ref / 'target.json')
        original = run.read(out / 'reference_source/config/ftlpu-lpu32.json')
        original['mem']['rows_per_bank'] = depth
        assert config == original, 'configuration changes exceed MEM physical depth'
        references[str(depth)] = identity
    assert run.read(out / 'baseline_compatibility.json')['pass_']
    assert (out / 'baseline_old/trace.txt').read_bytes() == (out / 'baseline_new/trace.txt').read_bytes()
    assert run.read(out / 'legacy_v1_legacy_default_results.json')['pass_']
    assert (out / 'legacy_v1/legacy_default_old/trace.txt').read_bytes() == (out / 'legacy_v1/legacy_default_new/trace.txt').read_bytes()
    mutation = run.read(out / 'safety_v2_mutation_result.json')
    assert mutation['result']['pass_'] and mutation['original_unchanged']
    assert run.sha(out / 'vectors/smoke_v1_p64_e64_z0_directed.txt') == mutation['original_sha256']
    assert run.sha(out / 'safety_v2_mutated_read.txt') == mutation['mutated_sha256']
    for entry in run.read(out / 'filelists_v1_filelist_results.json'):
        assert run.sha(root / entry['filelist']) == entry['filelist_sha256']

    callers = []
    for directory in ['rtl', 'sim']:
        for p in (root / directory).rglob('*.sv'):
            if run.HERE in p.parents or p.relative_to(root).as_posix() in run.CORE:
                continue
            hits = [dict(line=i, text=line.strip()) for i, line in enumerate(p.read_text(encoding='utf-8-sig').splitlines(), 1)
                    if re.search(r'\b(?:mem_hemisphere|mem_group|mem_slice|mem_logical_bank_column|mem_bank_control_column|mem_bank_superlane_leaf)\b', line)]
            if hits:
                callers.append(dict(path=p.relative_to(root).as_posix(), sha256=run.sha(p), hits=hits,
                                    integration_executed=False))
    run.save(out / 'caller_inventory.json', callers)
    manifest = dict(source_revision=run.git(root, 'rev-parse', 'HEAD'),
        changed_existing=changed, new_outside_test_files=additions, interfaces=interfaces,
        actual_compilation_manifests=identities, reference_identities=references,
        files={p.relative_to(root).as_posix(): run.sha(p) for p in
               [*[root / p for p in run.CORE], root / additions[0], root / additions[1], root / contract,
                *[p for p in run.HERE.rglob('*') if p.is_file()]]},
        result_files={name: run.sha(out / name) for name in result_names})
    run.save(out / 'manifest_after.json', manifest)
    summary = dict(pass_=True, scope='S01-S05 standalone MEM RTL / original c7 L1 / independent safety oracle',
        user_choice='E is power-of-two; retain legacy16/32; E defaults to P; default policy Error',
        full_suites=37, totals=totals, random_seeds=list(range(0x4d454d00, 0x4d454d10)),
        codec_profiles=4, codec_cases_per_profile=393251, partial_mask_cases=1024,
        xz_negative_cases=17, illegal_parameter_cases=14, deliberate_golden_mutation_caught=True,
        legacy_16_32_32768_legal_traces_identical=True, intentional_cold_change='X to zero; not part of legacy trace equivalence',
        filelist_smoke_runs=3, tool='XSim 2023.2 --O0', cmodel_source_unchanged=True,
        protected_prior_work_unchanged=True, source_identity_sets_checked=len(identities),
        not_done=['S06 CModel synchronous-read adaptation', 'S07 L2 cycle equivalence to adapted CModel',
                  'RTL SRF/ICU/SXM/DMA/C2C/system integration and original integrated TBs',
                  'real lane adapter / partial-lane propagation', 'FPGA/ASIC macro initialization, synthesis and PPA',
                  'XSim O1/O2, second simulator (WSL enumeration E_ACCESSDENIED; no native Icarus on PATH)'],
        preserved_intermediate_failure='unit_v1 compile: testbench hex literal required whitespace before ternary; fixed test only, unit_v2 fully rerun',
        user_acceptance=False)
    run.save(out / 'summary.json', summary)
    print('MEM_AUDIT TEST_PASS', totals, 'source_identity_sets=' + str(len(identities)), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
        parser.error('invalid run ID')
    audit(run.ROOT / 'build/mem_p1' / args.run_id)
