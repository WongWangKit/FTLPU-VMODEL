"""Second integration pass. Existing interfaces only; no MEM+C2C storage ABI.

Use run.py prepare with a new RunId before editing. Each compile/run retains
source identities and logs. This runner never overwrites r1 evidence.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys
import zipfile

sys.dont_write_bytecode = True
import run as base

ROOT, HERE, common = base.ROOT, base.HERE, base.common


def attempt(out, name):
    n = 1
    while (out / f'{name}_attempt{n}').exists():
        n += 1
    return f'{name}_attempt{n}'


def combinations(out):
    """Same workload/latency checks, formal F52/T4/P2048, low and high rows.

    Remaining leaves are present, not claimed to receive SXM traffic. Profile0
    compatibility is rerun separately by run.py legacy. No 16/64B truncation.
    """
    results = []
    entries = [
        ('mem_srf_sxm_turnaround', 'lpu_mem_srf_sxm_turnaround_tb', 2047),
        ('mem_srf_sxm_roundtrip', 'lpu_mem_srf_sxm_roundtrip_tb', 2046),
        ('mem_srf_sxm_existing_workload', 'lpu_mem_srf_sxm_existing_workload_tb', 2015),
        ('dma_store_vector_sink', 'lpu_mem_srf_dma_store_vector_sink_tb', 2039),
    ]
    prefix = attempt(out, 'joint_combinations')
    for name, top, high_base in entries:
        for region, row_base in [('low', 0), ('high', high_base)]:
            result = dict(name=name, profile=32, region=region, row_base=row_base,
                          scope='existing T4 interface; F52/P2048; not all FU/ICU')
            try:
                sources = [ROOT / l.strip() for l in (ROOT/f'sim/filelist_{name}.f').read_text().splitlines()
                           if l.strip() and not l.strip().startswith('//')]
                work = common.compile_sim(out, f'{prefix}/{name}_{region}', sources, top,
                                          ['PROFILE=32', f'ROW_BASE={row_base}'])
                if name.endswith('existing_workload'):
                    shutil.copytree(ROOT/'sim/vectors', work/'sim/vectors')
                    common.save(work/'vector_identity.json', {str(p):common.sha(p)
                        for p in (ROOT/'sim/vectors').rglob('*') if p.is_file()})
                result.update(status='passed', result=common.simulate(out, work, 'run', timeout=1800))
            except Exception as e:
                result.update(status='failed', error=str(e))
                print('COMBINATION FAILED', result, flush=True)
            results.append(result)
            common.save(out/'joint_combinations_results.json', results)
    return results


def random_integration(out, selected, seeds, cycles):
    if cycles < 1000:
        raise RuntimeError('require at least 1000 randomized comparison cycles per seed')
    results = []
    # Fresh model/header/exe, directed run, full leaf bind, SRAM signature and
    # current-source RTL compile for each profile. No cached r1 PASS is reused.
    directed = base.integration(out, selected)
    if any(r['status'] != 'passed' for r in directed):
        return directed
    for profile in [16, 32, 64]:
        if selected and str(profile) not in selected:
            continue
        work = max((out/'integration').glob(f'{profile}_attempt*'),
                   key=lambda p:int(p.name.split('attempt')[-1]))
        for index in range(seeds):
            seed = 0x4a4f4900 + index
            name = f'joint_seed{index}'
            vector = work/f'{name}.txt'
            result = dict(profile=profile, seed=seed, name=name)
            try:
                if vector.exists():
                    raise RuntimeError('refuse to overwrite seed vectors')
                common.required([work/'reference.exe', vector, str(seed), str(cycles)],
                                work, work/f'{name}_reference.txt')
                coverage = common.read(str(vector)+'.coverage.json')
                if coverage['random_jobs'] == 0 or coverage['random_waves'] == 0:
                    raise RuntimeError('empty randomized schedule')
                sim = common.simulate(out, work/'rtl', name,
                                      ['VECTORS='+vector.as_posix()], timeout=1800)
                result.update(status='passed', result=sim, coverage=coverage,
                              vector_sha256=common.sha(vector))
            except Exception as e:
                result.update(status='failed', error=str(e))
                print('RANDOM INTEGRATION FAILED', result, flush=True)
            results.append(result)
            # Selected profiles can run in independent shells without sharing
            # output files. This is process concurrency, not agent delegation.
            common.save(out/f'joint_random_{profile}_results.json',
                        [r for r in results if r.get('profile') == profile])
    return results


def archive(out):
    """Record final identities; verify CModel and product RTL are unmodified.

    User declined new attachment ports; this pass may change tests/drivers/docs
    only. Check against this RunId's dirty snapshot, not against clean Git HEAD.
    """
    baseline = common.read(out/'baseline_manifest.json')
    final = {}
    with zipfile.ZipFile(out/'postimplementation_sources.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        for repo, folders in [(ROOT, ['rtl','sim','config','scripts','spec_new_c7ae225']),
                              (ROOT.parent/'FTLPU-CMODEL', ['include','src','cmake','tests','config'])]:
            files = [p for folder in folders for p in (repo/folder).rglob('*')
                     if p.is_file() and '__pycache__' not in p.parts]
            if (repo/'CMakeLists.txt').exists():
                files.append(repo/'CMakeLists.txt')
            for p in files:
                name = repo.name+'/'+p.relative_to(repo).as_posix()
                final[name] = common.sha(p)
                z.writestr(name, p.read_bytes())
    changed = [name for name in baseline if final.get(name) != baseline[name]]
    unexpected = [name for name in changed if name.startswith(('FTLPU-CMODEL/', 'FTLPU-VMODEL/rtl/'))]
    added_protected = [name for name in final if name not in baseline and
                       name.startswith(('FTLPU-CMODEL/', 'FTLPU-VMODEL/rtl/'))]
    common.save(out/'joint_final_manifest.json', dict(files=final, changed=changed,
                added=sorted(set(final)-set(baseline)), removed=sorted(set(baseline)-set(final))))
    if unexpected or added_protected:
        raise RuntimeError('unexpected product/CModel changes: '+str(unexpected+added_protected))
    common.save(out/'joint_archives.sha256.json', {p.name:common.sha(p) for p in
        [out/'preimplementation_sources.zip', out/'postimplementation_sources.zip']})
    return [dict(name='identity_archive', status='passed', product_rtl_changed=False,
                 cmodel_changed=False)]


def limits(out):
    results = []
    prefix = attempt(out, 'attachment_limits')
    for kind, name, error in [(0, 'dma_store_vector_sink', 'DMA Store vector-sink parameter contract violation'),
                              (1, 'mem_srf_sxm_turnaround', 'SXM compatibility integration requires T4')]:
        for profile in [16, 64]:
            result = dict(name=name, profile=profile, expected_rejection=True)
            try:
                sources = [ROOT/l.strip() for l in (ROOT/f'sim/filelist_{name}.f').read_text().splitlines()
                           if l.strip() and not l.strip().startswith('//') and not l.strip().startswith('sim/tb/lpu_')]
                sources += [HERE/'attachment_limits_tb.sv']
                work = common.compile_sim(out, f'{prefix}/{name}_{profile}', sources,
                    'mem_profiles_attachment_limits_tb', [f'PROFILE={profile}', f'KIND={kind}'])
                result.update(status='passed', result=common.simulate(out, work, 'reject', failure=error))
            except Exception as e:
                result.update(status='failed', error=str(e))
            results.append(result)
            common.save(out/'joint_limits_results.json', results)
    return results


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('stage', choices=['combinations', 'random', 'limits', 'archive'])
    p.add_argument('--run-id', required=True)
    p.add_argument('--select', nargs='*')
    p.add_argument('--seeds', type=int, default=16)
    p.add_argument('--cycles', type=int, default=1000)
    args = p.parse_args()
    if not common.re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
        p.error('invalid RunId')
    out = ROOT/'build/mem_profiles'/args.run_id
    if not (out/'baseline_manifest.json').is_file():
        p.error('run run.py prepare with a new RunId first')
    base.tools(out)
    if args.stage == 'combinations':
        results = combinations(out)
    elif args.stage == 'random':
        results = random_integration(out, args.select, args.seeds, args.cycles)
    elif args.stage == 'limits':
        results = limits(out)
    else:
        results = archive(out)
        common.save(out/'joint_archive_results.json', results)
    sys.exit(1 if any(r['status'] != 'passed' for r in results) else 0)
