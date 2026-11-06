"""Recover reports/simulation from an already exported synthesis checkpoint.

Original failed runs remain immutable; the recovery receives a new run ID.
"""
import argparse
import hashlib
import json
import shutil
from run import EXP, FPGA, VIVADO, definition, execute, simulate

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--source-run',required=True)
    ap.add_argument('--run',required=True)
    ap.add_argument('--cases',nargs='+',required=True)
    a=ap.parse_args()
    for name in [a.source_run,a.run]+a.cases:
        if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in name):ap.error('invalid name')
    original=EXP/'results'/a.source_run
    src=FPGA/'tmp'/('mapping_'+a.source_run)/'src'
    out=EXP/'results'/a.run;out.mkdir()
    work=FPGA/'tmp'/('mapping_'+a.run);work.mkdir()
    (out/'provenance.json').write_text(json.dumps(dict(source_run=a.source_run,
        source_manifest_sha256=hashlib.sha256((original/'source_manifest.json').read_bytes()).hexdigest(),
        reason='Original synthesis/checkpoint/netlist succeeded; post-export primitive-report Tcl quoting failed.'),indent=2))
    records=[]
    for case in a.cases:
        od=out/case;od.mkdir();wd=work/case;wd.mkdir()
        cfg=definition(case,src)
        for f in ['netlist.v','utilization.rpt','utilization_hier.rpt','configuration.json','timing.xdc']:
            shutil.copy2(original/case/f,od/f)
        dcp=original/case/'synthesized.dcp'
        script=od/'recover.tcl'
        script.write_text('open_checkpoint {'+dcp.as_posix()+'}\n'+
            'set fd [open {'+(od/'primitives.txt').as_posix()+'} w]\n'+
            'foreach pattern {LUT* FD* RAMB18E2 RAMB36E2 URAM288 DSP48E2 SRL* MUXF* CARRY* LD*} {\n'+
            ' set selector [format {REF_NAME =~ %s} $pattern]\n'+
            ' puts $fd "$pattern=[llength [get_cells -hier -quiet -filter $selector]]"\n}\n'+
            'puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]"\nclose $fd\n'+
            'report_timing_summary -max_paths 3 -report_unconstrained -file {'+(od/'timing_summary.rpt').as_posix()+'}\n'+
            'report_drc -file {'+(od/'drc.rpt').as_posix()+'}\nputs RECOVERY_COMPLETED\nexit\n')
        cmd=[str(VIVADO/'vivado.bat'),'-mode','batch','-source',script.as_posix(),'-log',(od/'vivado.log').as_posix(),'-journal',(wd/'vivado.jou').as_posix()]
        print('RECOVER',case,flush=True)
        rec=execute(cmd,wd,od/'console.log',600);rec['case']=case
        rec['complete']=rec['returncode']==0 and 'RECOVERY_COMPLETED' in (od/'console.log').read_text(errors='replace')
        if rec['complete']:rec['simulation']=simulate(cfg,src,od,wd)
        records.append(rec);(out/'summary.json').write_text(json.dumps(records,indent=2))
    raise SystemExit(0 if all(r['complete'] and all(s['passed'] for s in r.get('simulation',[])) for r in records) else 1)

if __name__=='__main__':main()
