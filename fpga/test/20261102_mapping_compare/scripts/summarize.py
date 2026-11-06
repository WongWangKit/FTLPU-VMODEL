"""Keep measured resource reports separate from linear system projections."""
import argparse
import csv
import hashlib
import json
import math
import re
from run import EXP,FPGA

def number(s,label):
    m=re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([\d.,]+)\s*\|',s,re.M)
    return float(m.group(1).replace(',','')) if m else None

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--run',required=True);a=ap.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+',a.run):ap.error('invalid run')
    out=EXP/'results'/a.run;out.mkdir()
    verified={}
    for simulation in sorted((EXP/'results').glob('*/*/simulation.json'),key=lambda p:p.stat().st_mtime):
        netlist=simulation.parent/'netlist.v'
        if not netlist.exists():continue
        checks=json.loads(simulation.read_text())
        if len(checks)==2 and all(s['passed'] for s in checks):
            verified[hashlib.sha256(netlist.read_bytes()).hexdigest()]=simulation.relative_to(FPGA).as_posix()
    rows=[]
    for p in sorted((EXP/'results').glob('*/*/utilization.rpt')):
        text=p.read_text(errors='replace');root=p.parent;run=root.parent.name
        cfg=json.loads((root/'configuration.json').read_text())
        summary=root.parent/'summary.json'
        rec=next((r for r in json.loads(summary.read_text()) if r['case']==root.name),{}) if summary.exists() else {}
        timing=root/'timing_summary.rpt'
        wns=None
        if timing.exists():
            m=re.search(r'WNS\(ns\)[^\n]*\n[ \t]*-{3,}[^\n]*\n[ \t]*(\S+)',timing.read_text(errors='replace'))
            if m:
                value=float(m.group(1))
                if math.isfinite(value):wns=value
        primitive=root/'primitives.txt'
        primitive_text=primitive.read_text() if primitive.exists() else ''
        drc=root/'drc.rpt'
        drc_match=re.search(r'Violations found:\s+(\d+)',drc.read_text(errors='replace')) if drc.exists() else None
        rows.append(dict(run=run,case=root.name,complete=rec.get('complete',False),
            LUT=number(text,'CLB LUTs*'),FF=number(text,'CLB Registers'),
            BRAM36=number(text,'Block RAM Tile'),URAM=number(text,'URAM'),DSP=number(text,'DSPs'),
            WNS_ns=wns,period_ns=cfg['period_ns'],no_timing_driven=cfg.get('no_timing_driven',False),
            RTL_pass=next((s['passed'] for s in rec.get('simulation',[]) if s['mode']=='rtl'),None),
            gate_pass=next((s['passed'] for s in rec.get('simulation',[]) if s['mode']=='gate'),None),
            zero_blackbox='blackbox_count=0' in primitive_text,zero_latch='LD*=0' in primitive_text,
            DRC_violations=int(drc_match.group(1)) if drc_match else None,
            DRC_errors=len(re.findall(r'^\|\s*\S+\s*\|\s*(?:Error|Critical Warning)\s*\|',drc.read_text(errors='replace'),re.M)) if drc.exists() else None,
            verified_simulation=verified.get(hashlib.sha256((root/'netlist.v').read_bytes()).hexdigest()) if (root/'netlist.v').exists() else None,
            report_path=p.relative_to(FPGA).as_posix(),report_sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
    (out/'measured_resources.json').write_text(json.dumps(rows,indent=2))
    with (out/'measured_resources.csv').open('w',newline='',encoding='utf-8-sig') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    print(json.dumps(rows,indent=2))

if __name__=='__main__':main()
