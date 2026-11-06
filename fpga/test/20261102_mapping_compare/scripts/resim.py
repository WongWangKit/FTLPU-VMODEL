"""Run a new, snapshotted TB against a preserved synthesis source/netlist."""
import argparse
import hashlib
import json
import shutil
from run import EXP,FPGA,definition,simulate

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--source-run',required=True)
    ap.add_argument('--run',required=True)
    ap.add_argument('--cases',nargs='+',required=True)
    ap.add_argument('--bench',required=True)
    ap.add_argument('--rtl-only',action='store_true')
    a=ap.parse_args()
    for n in [a.run,a.source_run,a.bench]+a.cases:
        if not n or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in n):ap.error('invalid name')
    out=EXP/'results'/a.run;out.mkdir()
    work=FPGA/'tmp'/('mapping_'+a.run);work.mkdir()
    src=FPGA/'tmp'/('mapping_'+a.source_run)/'src'
    records=[]
    for case in a.cases:
        od=out/case;od.mkdir();wd=work/case;wd.mkdir()
        cfg=definition(case,src);cfg['tb']=a.bench
        original=EXP/'results'/a.source_run/case
        if not a.rtl_only:shutil.copy2(original/'netlist.v',od/'netlist.v')
        tb=od/(a.bench+'_tb.sv');shutil.copy2(EXP/'tb'/tb.name,tb)
        (od/'provenance.json').write_text(json.dumps(dict(source_run=a.source_run,
            tb_sha256=hashlib.sha256(tb.read_bytes()).hexdigest(),
            netlist_sha256=None if a.rtl_only else hashlib.sha256((od/'netlist.v').read_bytes()).hexdigest()),indent=2))
        rec=dict(case=case,simulation=simulate(cfg,src,od,wd,tb,('rtl',) if a.rtl_only else ('rtl','gate')))
        records.append(rec);(out/'summary.json').write_text(json.dumps(records,indent=2))
    raise SystemExit(0 if all(s['passed'] for r in records for s in r['simulation']) else 1)

if __name__=='__main__':main()
