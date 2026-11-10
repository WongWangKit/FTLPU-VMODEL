"""Export selected, de-identified SXM evidence. No Git/index/tool-run mutation.

Original files, including DCP/netlists and raw logs, remain at the source paths.
The source workspace is supplied explicitly; no host path is embedded here.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re

REPO = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--workspace', required=True, type=Path)
ap.add_argument('--snapshot', default='20261110_pause')
a = ap.parse_args()
workspace = a.workspace.resolve()
experiment = workspace / 'learn/sxm_writetap_implementation_20261109'
assert re.fullmatch(r'[A-Za-z0-9_-]+', a.snapshot), 'simple snapshot name required'
out = REPO / 'sim/sxm_writetap/results' / a.snapshot
out.mkdir(parents=True, exist_ok=False)
manifest = []


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def scrub(s):
    # JSON is parsed before scrubbing, so escaped Windows paths are also covered.
    for path, label in [(REPO, '<VMODEL>'), (workspace, '<LPU_WORKSPACE>'),
                        (Path.home(), '<USER_HOME>')]:
        variants = [str(path), path.as_posix()]
        if path.drive:
            variants.append('/mnt/' + path.drive[0].lower() + path.as_posix()[2:])
        for value in variants:
            s = re.sub(re.escape(value), lambda m: label, s, flags=re.I)
    host = os.environ.get('COMPUTERNAME')
    if host:
        s = re.sub(r'(?<![\w])' + re.escape(host) + r'(?![\w])', '<HOST>', s, flags=re.I)
    return s


def scrub_json(obj):
    if isinstance(obj, str):
        return scrub(obj)
    if isinstance(obj, list):
        return [scrub_json(x) for x in obj]
    if isinstance(obj, dict):
        return {scrub(str(k)): scrub_json(v) for k, v in obj.items()}
    return obj


def export(source, destination):
    raw = source.read_bytes()
    text = raw.decode('utf-8-sig')
    if source.suffix == '.json':
        clean = json.dumps(scrub_json(json.loads(text)), ensure_ascii=False, indent=2) + '\n'
    else:
        clean = scrub(text)
    published = clean.encode('utf-8')
    destination.parent.mkdir(parents=True, exist_ok=True)
    assert not destination.exists(), f'refusing overwrite: {destination}'
    destination.write_bytes(published)
    manifest.append(dict(source=source.relative_to(workspace).as_posix(),
                         published=destination.relative_to(REPO).as_posix(),
                         source_sha256=digest(raw), published_sha256=digest(published),
                         source_bytes=len(raw), published_bytes=len(published),
                         transformed=raw != published))


functional = ['model01', 'full07', 'c814_04', 'wide04', 'core_reg03', 'switch03',
              'bounds01', 'diff03', 'cmodel01', 'admission01', 'sim_final02',
              'full_geometry01', 'sim02', 'latest_chain05', 'pack_eq04',
              'count_eq02', 'sim_smoke01', 'sim_smoke02', 'closure05', 'gate_probe04']
for run in functional:
    directory = experiment / 'results' / run
    for name in ['summary.json', 'manifest.json']:
        source = directory / name
        if source.exists():
            export(source, out / 'functional' / run / name)
    # Retain small assertion/result logs, not compiler output or executables.
    for source in directory.glob('*.log'):
        if source.name not in ['build.log', 'compile.log'] and source.stat().st_size < 1024**2:
            export(source, out / 'functional' / run / source.name)

for run in ['migration03', 'evidence03']:
    for source in (experiment / 'results' / run).iterdir():
        if source.is_file() and source.suffix in ['.json', '.csv']:
            export(source, out / run / source.name)

artifacts = []
for component in ['core', 'adapter', 'combined']:
    for t in [2, 4, 8]:
        run = f'l5_queue05_{component}_t{t}_synth'
        directory = experiment / 'results' / run
        if not directory.exists():
            continue
        for rel in ['manifest.json', 'summary.json', 'reused_from.json', 'user_pause.json',
                    'synthesized/checks.txt', 'synthesized/runtime.json',
                    'synthesized/synth_utilization.rpt', 'synthesized/synth_hierarchical.rpt',
                    'synthesized/synth_timing.rpt', 'synthesized/vivado.log']:
            source = directory / rel
            if source.exists():
                export(source, out / 'physical' / run / rel)
        for name in ['synthesized.dcp', 'synthesized.v']:
            source = directory / 'synthesized' / name
            if source.exists():
                artifacts.append(dict(source=source.relative_to(workspace).as_posix(),
                                      bytes=source.stat().st_size,
                                      sha256=digest(source.read_bytes()),
                                      publication='local_only; not deleted'))

for rel in ['l5_queue05/summary.json', 'l5_queue05/user_pause.json',
            'task_awake02/finished.json', 'parser_reg01/summary.json']:
    export(experiment / 'results' / rel, out / 'execution' / rel)

# Exact constraints and script logic for audit; these historical runners depend
# on external workspace fixtures and are not advertised as portable launchers.
refs = REPO / 'sim/sxm_writetap/reference_scripts' / a.snapshot
refs.mkdir(parents=True, exist_ok=False)
for source in sorted((experiment / 'scripts').iterdir()):
    if source.is_file() and source.suffix in ['.py', '.ps1', '.tcl', '.xdc', '.svh', '.vlt']:
        export(source, refs / source.name)
for name in ['host_runtime.py', 'sample_owned_process.ps1']:
    export(workspace / 'learn/sxm_gap10_20261104/scripts' / name, refs / name)

# Include the declaration-to-physical RTL fingerprint, not a second payload copy.
source_files = sorted(set(list((REPO / 'rtl/sxm_native').glob('*.sv')) +
                          list((REPO / 'rtl/integration').glob('*sxm*.sv'))))
rtl = {p.relative_to(REPO).as_posix(): digest(p.read_bytes()) for p in source_files}
rtl_lf = {p.relative_to(REPO).as_posix(): digest(p.read_bytes().replace(b'\r\n', b'\n')) for p in source_files}
record = dict(snapshot=a.snapshot, status='paused; L5 incomplete',
              tested_vmodel_main='f4dd088f8ee62e4349bc0ec7d09e38cbc9507f99',
              observed_develop='a39c5d0946a8ed7c2bda0508c23957dbd701149e',
              develop_merge_regression='not executed', source_rtl_sha256=rtl,
              source_rtl_lf_sha256=rtl_lf,
              completed_syntheses=5, planned_syntheses=9, routed_checkpoints=0,
              local_only_artifacts=artifacts, files=manifest,
              caveats=['Personal paths/host labels redacted in published copies only.',
                       'Historical hashes remain original; use published_sha256 for exported files.',
                       'DCP/netlists, raw logs, external fixtures and vendor tools remain local.',
                       'Reference scripts require external workspace fixtures and path configuration.',
                       'No RTL/EDA/regression rerun and no push performed by this exporter.'])
(out / 'publication_manifest.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(dict(files=len(manifest), bytes=sum(x['published_bytes'] for x in manifest),
                      local_only_artifacts=len(artifacts), out=str(out)), indent=2))
