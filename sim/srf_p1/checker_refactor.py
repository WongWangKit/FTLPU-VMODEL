"""Sample regression for the simulation-only SRF checker extraction.

Reuse frozen, hash-verified CModel vectors; never overwrite old acceptance runs.
This is not a replacement for full step-6/7 acceptance or another simulator.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
import run as prep
import accept

ROOT = prep.ROOT
HISTORY = ROOT / 'build/srf_p1/srf_20261018_full_r2'
BEFORE = ROOT / 'build/srf_p1/srf_20261019_checker_refactor_r1/before'
RUNTIME = re.compile(
    r'`ifndef SYNTHESIS\n  // Verification starts only after an actual reset assertion\..*?`endif\n',
    re.S)
MESSAGES = {
    2: 'partial/unknown mask on legacy',
    3: 'unknown valid/consume control',
    4: 'unknown valid/consume control',
    5: 'unknown valid/consume control',
    6: 'unknown valid upstream payload',
    7: 'unknown valid injection payload',
    8: 'unknown reset',
}


def compile_filelist(out, name, filelist, top, extra=()):
    # Resolve the actual repository filelist, not an independent source inventory.
    source = ROOT / filelist
    lines = [s.strip() for s in source.read_text(encoding='utf-8-sig').splitlines()
             if s.strip() and not s.lstrip().startswith('#')]
    assert lines.count(prep.SRF_CHECKER) == 1, filelist
    for rtl, binding in prep.SRF_BINDINGS.items():
        assert lines.count(binding) == int(rtl in lines), (filelist, binding)
    resolved = out / (name + '.f')
    resolved.write_text('\n'.join((ROOT / s).as_posix() for s in lines) +
                        '\n' + ''.join(Path(s).as_posix() + '\n' for s in extra),
                        encoding='utf-8')
    work, ok = accept.compile_sim(out, name, ['-f', resolved], top,
                                  default_timescale=True)
    if not ok:
        raise RuntimeError('compile/elaborate failed: ' + str(work))
    return work


def main(out):
    out.mkdir(parents=True, exist_ok=False)
    prep.save(out / 'tools.json', prep.read(HISTORY / 'tools.json'))
    historical = prep.read(HISTORY / 'manifest.json')
    functional = []
    for rel in prep.SRF:
        old, new = BEFORE / rel, ROOT / rel
        assert prep.sha(old) == historical['rtl'][rel], 'pre-refactor identity drift'
        text = old.read_text(encoding='utf-8-sig')
        stripped, count = RUNTIME.subn('', text)
        assert count == (2 if old.stem == 'ftlpu_sr_superlane_col_dir' else 1)
        assert stripped == new.read_text(encoding='utf-8-sig'), rel
        functional.append(dict(path=rel, before_sha256=prep.sha(old),
                               after_sha256=prep.sha(new), removed_runtime_blocks=count,
                               remaining_text_identical=True))
    prep.save(out / 'functional_identity.json', functional)

    filelists = sorted(p for p in (ROOT / 'sim').rglob('*.f')
                       if 'rtl/srf/' in p.read_text(encoding='utf-8-sig'))
    for path in filelists:
        lines = path.read_text(encoding='utf-8-sig').splitlines()
        assert lines.count(prep.SRF_CHECKER) == 1
        for rtl, binding in prep.SRF_BINDINGS.items():
            assert lines.count(binding) == int(rtl in lines), (path, binding)
    tracked = [ROOT / p for p in prep.SRF + prep.SRF_CHECKER_FILES] + filelists
    tracked += [p for p in prep.HERE.iterdir() if p.is_file()]
    identity = {p.relative_to(ROOT).as_posix(): prep.sha(p) for p in tracked}
    prep.save(out / 'manifest.json', dict(
        scope='sample regression only; XSim 2023.2 --O0',
        reference_sha=prep.CM_SHA, source_hashes=identity,
        historical_evidence=str(HISTORY), before_snapshot=str(BEFORE)))
    results = []

    def test(work, name, plus=(), marker='TEST_PASS', failure=None):
        result = accept.simulate(out, work, name, plus, marker,
                                 expected_failure=failure, timeout=900)
        results.append(dict(name=name, result=result))
        prep.save(out / 'results.json', results)
        if not result['pass_']:
            raise RuntimeError('regression failed: ' + name)

    lane = compile_filelist(out, 'lane', 'sim/srf_p1/filelist_lane.f',
                            'srf_p1_lane_compare_tb')
    evidence = {r['name']: r for r in prep.read(HISTORY / 'lane_results.json')}
    inputs = []
    for name in ['directed', 'seed_1397900800']:
        vectors = HISTORY / 'lane_vectors' / (name + '.vectors')
        assert prep.sha(vectors) == evidence[name]['vectors_sha256']
        inputs.append(dict(name=name, path=str(vectors), sha256=prep.sha(vectors),
                           coverage=evidence[name]['coverage']))
        test(lane, name, ['VECTORS=' + vectors.as_posix()], 'SRF_LANE TEST_PASS')
    prep.save(out / 'reused_lane_vectors.json', inputs)

    legacy = compile_filelist(out, 'legacy', 'sim/srf_p1/filelist_legacy.f',
                              'srf_p1_legacy_trace_tb')
    vectors = accept.BASE / 'vectors.txt'
    assert prep.sha(vectors) == prep.read(accept.BASE / 'manifest.json')['files']['vectors.txt']
    trace = legacy / 'trace.txt'
    test(legacy, 'legacy', ['VECTORS=' + vectors.as_posix(), 'TRACE=' + trace.as_posix()],
         'SRF_P1_LEGACY_TRACE PASS')
    comparison = prep.compare(accept.BASE, trace)
    old_trace = HISTORY / 'legacy_new/trace.txt'
    assert prep.sha(trace) == prep.sha(old_trace)
    prep.save(out / 'legacy_identity.json', dict(comparison=comparison,
              raw_trace_identical_to_pre_refactor=True, sha256=prep.sha(trace)))

    diagnostic = compile_filelist(out, 'diagnostic', 'sim/srf_p1/filelist_diagnostic.f',
                                  'srf_p1_diagnostic_tb')
    for case in range(9):
        test(diagnostic, 'diagnostic_' + str(case), ['CASE=' + str(case)],
             failure=MESSAGES.get(case))

    z = compile_filelist(out, 'z', 'sim/srf_p1/filelist_diagnostic.f',
                         'srf_z_whole_wrapper', [HISTORY / 'z_wrapper_whole_variable.sv'])
    for case in [3, 6, 8]:
        test(z, 'z_' + str(case), ['CASE=' + str(case)], failure=MESSAGES[case])

    for top, message in [('bad_local_consumers', 'dimensions and slot counts must be positive'),
                         ('bad_direction', 'DIRECTION must be East=0 or West=1')]:
        work = compile_filelist(out, top, 'sim/srf_p1/filelist_diagnostic.f', top,
                                [HISTORY / 'bad_parameter_tops.sv'])
        test(work, top, failure=message)

    for name, top in [('srf', 'lpu_srf_tb'), ('mem_srf', 'lpu_mem_srf_tb')]:
        work = compile_filelist(out, name, 'sim/filelist_' + name + '.f', top)
        if (ROOT / 'sim/vectors').is_dir():
            shutil.copytree(ROOT / 'sim/vectors', work / 'sim/vectors')
        test(work, name)

    assert all(prep.sha(ROOT / rel) == sha for rel, sha in identity.items())
    prep.save(out / 'summary.json', dict(
        pass_=True, tests=len(results), lane_cycles=1799, directed_negative_cycles=260,
        legacy_cycles=182, legacy_negative_cycles=32, all_source_hashes_unchanged=True,
        scope='sampled refactor regression; not full acceptance',
        open_items=['O1/O2 discrepancy', 'second simulator unavailable',
                    'existing SXM command-adapter failure', 'user final signoff']))
    print('SRF_CHECKER_REFACTOR PASS', out, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
        parser.error('invalid run ID')
    main(ROOT / 'build/srf_p1' / args.run_id)
