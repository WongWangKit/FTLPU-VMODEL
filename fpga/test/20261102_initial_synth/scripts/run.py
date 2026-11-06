"""Bounded, source-snapshotted Vivado OOC experiments; all writes under fpga/."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

EXPERIMENT = Path(__file__).resolve().parents[1]
FPGA = EXPERIMENT.parents[1]
REPO = FPGA.parent
VIVADO = Path(os.environ.get('VIVADO_BIN', r'C:\Users\huazh\Desktop\Vivado2023\Vivado\2023.2\bin'))

def execute(cmd, cwd, log, timeout):
    start = time.monotonic()
    with log.open('w', encoding='utf-8') as f:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
        try:
            rc = p.wait(timeout=timeout)
            state = 'completed' if rc == 0 else 'failed'
        except subprocess.TimeoutExpired:
            # Kill only the process tree launched by this experiment.
            subprocess.run(['taskkill', '/PID', str(p.pid), '/T', '/F'], stdout=f, stderr=f)
            p.wait()
            rc, state = None, 'timeout'
    return {'command': cmd, 'returncode': rc, 'status': state, 'elapsed_s': round(time.monotonic()-start, 1)}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', required=True)
    ap.add_argument('--cases', nargs='+', default=['mem_leaf','mem_slice','srf_leaf','old_mem','alu_basic','old_dot','old_top'])
    ap.add_argument('--part', default='xcvu9p-flga2104-2L-e')
    ap.add_argument('--timeout', type=int, default=900)
    a = ap.parse_args()
    # Run names are a single directory, never a filesystem path.
    if not a.run or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in a.run):
        ap.error('invalid run name')
    results = EXPERIMENT/'results'/a.run
    work = FPGA/'tmp'/a.run
    results.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    src = work/'src'
    if src.exists():
        raise SystemExit('Run already has a source snapshot; use a new --run name')
    manifest = []
    files = list((REPO/'rtl').rglob('*.sv')) + [REPO/'sim/filelist.f', REPO/'config/native_profiles.json', REPO/'rtl/core/lpu_native_config_pkg.sv']
    for f in sorted(set(files)):
        rel = f.relative_to(REPO)
        dest = src/rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, dest)
        manifest.append({'path': rel.as_posix(), 'sha256': hashlib.sha256(dest.read_bytes()).hexdigest()})
    (results/'source_manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    for subdir in ['rtl','scripts','tb']:
        for f in (EXPERIMENT/subdir).glob('*'):
            if f.is_file():
                dest=src/'fpga_experiment'/subdir/f.name
                dest.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(f,dest)
                manifest.append({'path':dest.relative_to(src).as_posix(),'sha256':hashlib.sha256(dest.read_bytes()).hexdigest()})
    (results/'source_manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    git = ['git', '-c', f'safe.directory={REPO.as_posix()}', '-C', str(REPO)]
    baseline = subprocess.run(git+['rev-parse','HEAD'], capture_output=True, text=True).stdout
    status = subprocess.run(git+['status','--short'], capture_output=True, text=True).stdout
    (results/'baseline.txt').write_text(baseline+status, encoding='utf-8')
    records=[]
    for case in a.cases:
        out = results/case
        wd = work/case
        out.mkdir(); wd.mkdir()
        cmd = [str(VIVADO/'vivado.bat'), '-mode','batch','-source',(src/'fpga_experiment/scripts/synth.tcl').as_posix(),'-log',(out/'vivado.log').as_posix(),'-journal',(wd/'vivado.jou').as_posix(),'-tclargs',src.as_posix(),out.as_posix(),case,a.part]
        print('START', case, flush=True)
        record = execute(cmd, wd, out/'console.log', a.timeout)
        record.update(case=case, part=a.part)
        # Vivado status must also include the completion sentinel and netlist.
        log = (out/'console.log').read_text(encoding='utf-8', errors='replace')
        record['synthesis_completed'] = 'SYNTHESIS_COMPLETED case='+case in log and (out/'netlist.v').exists()
        records.append(record)
        (results/'summary.json').write_text(json.dumps(records, indent=2), encoding='utf-8')
        print(json.dumps(record), flush=True)

if __name__ == '__main__':
    main()
