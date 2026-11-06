"""Check the selected evidence and local documentation links; never run Vivado."""
import hashlib
import json
from pathlib import Path
import py_compile
import re
from run import EXPERIMENT, FPGA, REPO


def main():
    results = EXPERIMENT / 'results'
    output = results / 'analysis001'
    selected = {
        'run007': ['mem_leaf_bram', 'mem_slice_bram', 'srf_leaf'],
        'run010': ['alu_basic_pruned'],
        'run012': ['alu_basic_bf16'],
    }
    synthesis = []
    for run, cases in selected.items():
        summary = json.loads((results / run / 'summary.json').read_text())
        for case in cases:
            entry = next(r for r in summary if r['case'] == case)
            assert entry['returncode'] == 0 and entry['synthesis_completed'], (run, case)
            folder = results / run / case
            checks = (folder / 'checks.txt').read_text()
            assert 'blackbox_count=0' in checks and 'latch_count=0' in checks
            assert re.search(r'Violations found:\s+0\b', (folder / 'drc.rpt').read_text())
            for filename in ['netlist.v', 'synthesized.dcp', 'utilization.rpt', 'timing_summary.rpt']:
                assert (folder / filename).stat().st_size > 0
            synthesis.append({'run': run, 'case': case, 'passed': True})
    simulation = []
    for run in ['sim001', 'sim002', 'sim003', 'sim004', 'sim005', 'sim006']:
        for record in json.loads((results / run / 'summary.json').read_text()):
            # Retain the known initial failure; sim003 contains its corrected run.
            known_failure = run == 'sim001' and record['case'] == 'alu_basic'
            assert record['passed'] or known_failure, (run, record['case'])
            simulation.append({'run': run, 'case': record['case'], 'mode': record['mode'],
                               'passed': record['passed'], 'known_initial_failure': known_failure})
    profile = json.loads((output / 'projection.json').read_text())
    assert profile['subtotal_full_basic_LUT'] == 1504936
    assert profile['subtotal_bf16_basic_LUT'] == 1042856
    assert profile['compact16_slices_per_hemi_subtotal_bf16_LUT'] == 474056
    docs = sorted((FPGA / 'docs').glob('*.md')) + [FPGA / 'README.md', EXPERIMENT / 'README.md']
    links = []
    for doc in docs:
        for target in re.findall(r'\]\((C:/[^)]+)\)', doc.read_text(encoding='utf-8-sig')):
            assert Path(target).exists(), (doc, target)
            links.append(target)
    for script in (EXPERIMENT / 'scripts').glob('*.py'):
        py_compile.compile(str(script), doraise=True)
    originals = []
    changed_originals = []
    manifest = json.loads((results / 'run012' / 'source_manifest.json').read_text())
    for entry in manifest:
        if entry['path'].startswith('fpga_experiment/'):
            continue
        f = REPO / entry['path']
        originals.append(entry['path'])
        if not f.exists() or hashlib.sha256(f.read_bytes()).hexdigest() != entry['sha256']:
            changed_originals.append(entry['path'])
    report = {'status': 'PASS', 'selected_synthesis': synthesis, 'simulation': simulation,
              'local_links_checked': len(links), 'original_files_compared_to_run012': len(originals),
              'original_files_changed_since_run012': changed_originals,
              'scope': 'artifact consistency, selected local results and Python syntax; not new hardware verification'}
    (output / 'audit.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    files = docs + [f for sub in ['scripts', 'rtl', 'tb'] for f in (EXPERIMENT / sub).glob('*') if f.is_file()]
    hashes = [{'path': f.relative_to(FPGA).as_posix(), 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()} for f in sorted(files)]
    (output / 'final_artifact_manifest.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
