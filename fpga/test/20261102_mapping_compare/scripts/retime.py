"""Repair I/O constraints on a read-only no-timing-driven DCP; preserve the failed report."""
import argparse
import hashlib
import json
import re
import shutil
from run import EXP, FPGA, VIVADO, execute

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--source-run',required=True)
    ap.add_argument('--run',required=True)
    ap.add_argument('--case',required=True)
    a=ap.parse_args()
    if not all(re.fullmatch('[A-Za-z0-9_-]+',x) for x in [a.source_run,a.run,a.case]):ap.error('invalid name')
    original=EXP/'results'/a.source_run/a.case
    cfg=json.loads((original/'configuration.json').read_text())
    assert cfg['no_timing_driven'], 'Only area-only results may use this recovery without a new synthesis'
    root=EXP/'results'/a.run;root.mkdir()
    out=root/a.case;out.mkdir()
    work=FPGA/'tmp'/('mapping_'+a.run);work.mkdir()
    for name in ['configuration.json','utilization.rpt','utilization_hier.rpt','netlist.v','primitives.txt']:
        shutil.copy2(original/name,out/name)
    (out/'provenance.json').write_text(json.dumps(dict(source_run=a.source_run,
        reason='Managed XDC rejected for loops; original WNS=inf invalid. Restore 1 ns I/O delays for STA only. No RTL or netlist change.',
        dcp_sha256=hashlib.sha256((original/'synthesized.dcp').read_bytes()).hexdigest(),
        netlist_sha256=hashlib.sha256((out/'netlist.v').read_bytes()).hexdigest()),indent=2))
    q=lambda p:'{'+p.as_posix()+'}'
    script=out/'retime.tcl'
    script.write_text(f'''set_param general.maxThreads 1
open_checkpoint {q(original/'synthesized.dcp')}
set data_inputs [get_ports -filter {{DIRECTION == IN && NAME != clk_i && NAME != rst_ni}}]
for {{set i 0}} {{$i < [llength $data_inputs]}} {{incr i 512}} {{set_input_delay 1.0 -clock clk [lrange $data_inputs $i [expr {{$i+511}}]]}}
set data_outputs [all_outputs]
for {{set i 0}} {{$i < [llength $data_outputs]}} {{incr i 512}} {{set_output_delay 1.0 -clock clk [lrange $data_outputs $i [expr {{$i+511}}]]}}
report_timing_summary -max_paths 3 -report_unconstrained -file {q(out/'timing_summary.rpt')}
report_drc -file {q(out/'drc.rpt')}
write_xdc -force {q(out/'resolved_timing.xdc')}
puts "RETIME_COMPLETED"
exit
''')
    rec=execute([str(VIVADO/'vivado.bat'),'-mode','batch','-source',script.as_posix(),'-log',(out/'vivado.log').as_posix(),'-journal',(work/'vivado.jou').as_posix()],work,out/'console.log',600)
    rec.update(case=a.case,complete=rec['returncode']==0 and 'RETIME_COMPLETED' in (out/'console.log').read_text(errors='replace'))
    (root/'summary.json').write_text(json.dumps([rec],indent=2))
    print(json.dumps(rec,indent=2))
    raise SystemExit(0 if rec['complete'] else 1)

if __name__=='__main__':main()
