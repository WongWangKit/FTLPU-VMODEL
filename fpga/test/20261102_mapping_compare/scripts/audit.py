"""Validate selected evidence, archive frozen sources, and hash the delivered artifacts."""
import argparse
import hashlib
import json
import py_compile
import re
import zipfile
from pathlib import Path
from run import EXP, FPGA, REPO

SELECTED={
    'vxm_recover001':['alu_default','alu_dsp','alu_wide_dsp'],
    'memory_recover001':['mem_bram','mem_uram','srf_default','srf_onehot'],
    'mxm001':['mxm_mul_default','mxm_mul_dsp'],
    'mxm_narrow001':['mxm_mul_narrow_dsp'],
    'mxm_area003_sta001':['mxm_column_default'],
    'mxm_area001':['mxm_column_narrow_dsp'],
    'mxm_compact001':['mxm_column_compact_dsp'],
}

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--analysis',required=True);a=ap.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+',a.analysis):ap.error('invalid run')
    out=EXP/'results'/a.analysis
    assert out.is_dir() and not (out/'audit.json').exists(), 'Use a new analysis run'
    rows=json.loads((out/'measured_resources.json').read_text())
    checked=[];failures=[];artifacts=set()
    for run,cases in SELECTED.items():
        for case in cases:
            row=next(r for r in rows if r['run']==run and r['case']==case)
            ok=all([row['complete'],row['zero_blackbox'],row['zero_latch'],row['DRC_errors']==0,row['verified_simulation'],row['WNS_ns'] is not None])
            simulation=FPGA/row['verified_simulation'] if row['verified_simulation'] else None
            root=EXP/'results'/run/case
            if simulation:
                ok=ok and sha(root/'netlist.v')==sha(simulation.parent/'netlist.v')
                for mode in ['rtl','gate']:
                    log=simulation.parent/mode/'simulate.log'
                    text=log.read_text(errors='replace')
                    markers=re.findall(r'^PASS .*$',text,re.M)
                    ok=ok and bool(markers) and 'Fatal:' not in text and 'ERROR:' not in text
                    artifacts.add(log)
                artifacts.add(simulation)
            if not ok:failures.append(run+'/'+case)
            checked.append(dict(run=run,case=case,passed=bool(ok),simulation=row['verified_simulation'],LUT=row['LUT'],DSP=row['DSP'],WNS_ns=row['WNS_ns'],DRC_warnings=row['DRC_violations']))
            for name in ['configuration.json','utilization.rpt','utilization_hier.rpt','timing_summary.rpt','drc.rpt','primitives.txt','netlist.v']:
                artifacts.add(root/name)
    math=EXP/'results/math_equiv001/summary.json'
    assert json.loads(math.read_text())['passed'];artifacts.add(math)
    full=EXP/'results/mxm_full_compact001/summary.json'
    assert json.loads(full.read_text())[0]['status']=='timeout';artifacts.add(full)
    full_rtl=EXP/'results/mxm_full_compact_rtl001/summary.json'
    assert all(s['passed'] for r in json.loads(full_rtl.read_text()) for s in r['simulation']);artifacts.add(full_rtl)
    archived=[]
    archive=out/'frozen_sources.zip'
    with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as z:
        for manifest in sorted((EXP/'results').glob('*/source_manifest.json')):
            run=manifest.parent.name;src=FPGA/'tmp'/('mapping_'+run)/'src'
            if not src.exists():src=manifest.parent/'src'
            records=json.loads(manifest.read_text())
            for rec in records:
                p=src/rec['path']
                assert sha(p)==rec['sha256'], 'Frozen source mismatch: '+str(p)
                z.write(p,('mapping_'+run+'/src/'+rec['path']))
            archived.append(dict(run=run,files=len(records),manifest_sha256=sha(manifest)))
            artifacts.add(manifest)
    current_diffs=[];compared=0
    for rec in json.loads((EXP/'results/mxm_area003/source_manifest.json').read_text()):
        if rec['path'].startswith('rtl/') or rec['path']=='filelist.f':
            current=REPO/('sim/filelist.f' if rec['path']=='filelist.f' else rec['path'])
            compared+=1
            if not current.exists() or sha(current)!=rec['sha256']:current_diffs.append(rec['path'])
    docs=[FPGA/'README.md',EXP/'README.md',FPGA/'docs/FPGA资源映射对照与MXM综合_20261102.md']
    missing_links=[]
    pending_outputs={out/'audit.json',out/'artifact_manifest.json'}
    for doc in docs:
        for target in re.findall(r'\]\(([^)]+)\)',doc.read_text(encoding='utf-8-sig')):
            local=Path(target.split('#')[0])
            if re.match('[A-Za-z]:/',target) and not local.exists() and local not in pending_outputs:missing_links.append(target)
    assert not missing_links,missing_links
    for p in (EXP/'scripts').glob('*.py'):py_compile.compile(str(p),doraise=True)
    for dirname in ['scripts','rtl','tb']:
        artifacts.update(p for p in (EXP/dirname).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    artifacts.update(docs);artifacts.add(archive)
    artifacts.update([out/'measured_resources.json',out/'measured_resources.csv'])
    audit=dict(passed=not failures,selected_count=len(checked),selected=checked,failures=failures,
        frozen_source_archive=dict(file=archive.name,sha256=sha(archive),runs=archived),
        current_product_sources_compared=compared,current_product_changes_since_area003=current_diffs,
        local_document_links_valid=True,python_compile_passed=True,
        limitations=['Functional post-synthesis simulation, no SDF or P&R','Full compute synthesis timed out; RTL only','Not formal equivalence or full IEEE conformance'])
    (out/'audit.json').write_text(json.dumps(audit,indent=2),encoding='utf-8')
    artifacts.add(out/'audit.json')
    (out/'artifact_manifest.json').write_text(json.dumps([dict(path=p.relative_to(FPGA).as_posix(),sha256=sha(p)) for p in sorted(artifacts)],indent=2),encoding='utf-8')
    assert all(p.exists() for p in pending_outputs)
    print(json.dumps(dict(passed=audit['passed'],selected_count=len(checked),archived_runs=len(archived),current_source_changes=current_diffs),indent=2))
    raise SystemExit(0 if audit['passed'] else 1)

if __name__=='__main__':main()
