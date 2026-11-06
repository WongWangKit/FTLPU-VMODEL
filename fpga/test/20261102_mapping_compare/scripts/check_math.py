"""Freeze and run the focused normalization equivalence test."""
import argparse
import hashlib
import json
import shutil
from run import EXP,FPGA,VIVADO,execute

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--run',required=True);a=ap.parse_args()
    if not a.run or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in a.run):ap.error('invalid name')
    out=EXP/'results'/a.run;out.mkdir()
    work=FPGA/'tmp'/('mapping_'+a.run);work.mkdir()
    src=out/'src';src.mkdir()
    files=[]
    for f in [EXP/'rtl/math_reference_pkg.sv',EXP/'rtl/math_mxm_compact_pkg.sv',EXP/'tb/mxm_add_equiv_tb.sv']:
        target=src/f.name;shutil.copy2(f,target);files.append(target)
    (out/'source_manifest.json').write_text(json.dumps([dict(path=p.name,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in files],indent=2))
    commands=[
        [str(VIVADO/'xvlog.bat'),'--sv']+[f.as_posix() for f in files],
        [str(VIVADO/'xelab.bat'),'mxm_add_equiv_tb','-s','snapshot','--timescale','1ns/1ps','--mt','2'],
        [str(VIVADO/'xsim.bat'),'snapshot','-runall']]
    records=[]
    for name,cmd in zip(['compile','elaborate','simulate'],commands):
        rec=execute(cmd,work,out/(name+'.log'),180);records.append(rec)
        if rec['returncode']!=0:break
    log=(out/'simulate.log').read_text(errors='replace') if (out/'simulate.log').exists() else ''
    passed=len(records)==3 and all(r['returncode']==0 for r in records) and 'PASS mxm_add_equiv' in log and 'Fatal:' not in log
    (out/'summary.json').write_text(json.dumps(dict(passed=passed,steps=records),indent=2))
    print('normalization_equivalence',passed)
    raise SystemExit(0 if passed else 1)

if __name__=='__main__':main()
