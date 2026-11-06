"""Audit remote snapshots against earlier synthesis inputs without touching the working repository."""
import hashlib,json,subprocess
from pathlib import Path
EXP=Path(__file__).resolve().parents[1]
FPGA=EXP.parents[1]
TMP=FPGA/'tmp/ip17_20261104'
OUT=EXP/'results/baseline001'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(TMP/'remote.git'),*args],text=True,encoding='utf-8').strip()
records=[]
for branch in ['main','develop']:
    root=TMP/branch
    records.append(dict(branch=branch,commit=git('rev-parse',branch),date=git('show','-s','--format=%cI',branch),subject=git('show','-s','--format=%s',branch),archive_sha256=sha(OUT/(branch+'.zip'))))
checks=[]
for run,paths in {
    'vxm001':['rtl/vxm/lpu_vxm_alu.sv','rtl/vxm/lpu_vxm_addsub.sv','rtl/vxm/lpu_vxm_significand_multiplier.sv','rtl/vxm/lpu_vxm_mul8x8.sv','rtl/vxm/lpu_vxm_math_pkg.sv'],
    'memory001':['rtl/mem_native/mem_bank_superlane_leaf.sv','rtl/mem_native/mem_slice.sv','rtl/srf/ftlpu_sr_superlane_col_dir.sv'],
    'mxm_area003':['rtl/mxm/lpu_mxm_compute.sv','rtl/mxm/lpu_mxm_dot_bank.sv','rtl/mxm/lpu_mxm_dequantizer.sv','rtl/mxm/lpu_mxm_weight_buffer.sv','rtl/vxm/lpu_vxm_math_pkg.sv']
}.items():
    for rel in paths:
        old=FPGA/'tmp'/('mapping_'+run)/'src'/rel
        if not old.exists():continue
        for branch in ['main','develop']:
            new=TMP/branch/rel
            checks.append(dict(previous_run=run,path=rel,branch=branch,old_sha256=sha(old),remote_sha256=sha(new) if new.exists() else None,byte_identical=new.exists() and sha(old)==sha(new)))
manifest=json.loads((TMP/'develop/config/native_profiles.manifest.json').read_text())
report=dict(as_of='2026-11-04 Asia/Shanghai',remote_url='https://github.com/WongWangKit/FTLPU-VMODEL.git',branches=records,source_comparisons=checks,
    lpu16_mem_profile=manifest['profiles'][0],scope_warning='native_profiles.json explicitly limits scope to MEM verification; lpu_top/lpu_pkg/MXM remain fixed 4-tile 32-lane. No whole-system LPU16 ABI is frozen in these branches.')
(OUT/'baseline_audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
(OUT/'main_develop_diff.txt').write_text(git('diff','--stat','main','develop','--','rtl','config','docs'),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2))
