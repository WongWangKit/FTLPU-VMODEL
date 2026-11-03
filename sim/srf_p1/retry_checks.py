"""Canonical supplemental entry; preserves original failed Z fixture evidence.

XSim rejects force on a variable part-select. Force the whole variable instead;
this changes only the generated Z stimulus fixture, not RTL/reference/checkers.
"""
import argparse
from pathlib import Path
import re
import sys
sys.dont_write_bytecode=True
import accept as a
import run as prep
import finish_checks as original

def z_fixed(out):
    source=out/'z_wrapper_whole_variable.sv'
    source.write_text('''`timescale 1ns/1ps
module srf_z_whole_wrapper;
 srf_p1_diagnostic_tb sub();integer c;
 initial begin
  if(!$value$plusargs("CASE=%d",c))$fatal(1,"CASE missing");
  #31;
  case(c)
   3:force sub.up='z;
   4:force sub.inject='z;
   5:force sub.consume='z;
   6:force sub.ud='z;
   7:force sub.data_in='z;
   8:force sub.rst_n=1'bz;
  endcase
  $display("Z_DIAGNOSTIC_ARMED case=%0d",c);
 end
endmodule
''',encoding='utf-8')
    work,ok=a.compile_sim(out,'z_whole_sim',[a.ROOT/p for p in prep.SRF]+[a.HERE/'diagnostic_tb.sv',source],'srf_z_whole_wrapper')
    if not ok:raise RuntimeError('whole-variable Z fixture compile failed')
    results=[]
    for case in range(3,9):
        msg='unknown valid/consume control' if case<6 else 'unknown valid upstream payload' if case==6 else 'unknown valid injection payload' if case==7 else 'unknown reset'
        r=a.simulate(out,work,'z_'+str(case),['CASE='+str(case)],'',msg)
        if 'Z_DIAGNOSTIC_ARMED' not in Path(r['log']).read_text():r['pass_']=False
        results.append(r)
    prep.save(out/'z_results.json',results)
    prep.save(out/'supplemental_fixture_revision.json',dict(driver_sha256=prep.sha(Path(__file__)),generated_source_sha256=prep.sha(source),
        original_helper_sha256=prep.sha(a.HERE/'finish_checks.py'),reason='XSim VRFC 10-3149 on force variable part-select; use whole-variable force; no RTL/reference/scoreboard change',
        original_failure_log=str(out/'z_sim/elaborate.txt'),source_identity_checked_against_original_manifest=True))
    if not all(r['pass_'] for r in results):raise RuntimeError('Z rejection checks failed')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-id',required=True);args=p.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+',args.run_id):raise SystemExit('unsafe run-id')
    out=a.ROOT/'build/srf_p1'/args.run_id;a.check_identity(out)
    if not (out/'supplemental_lane.json').exists():original.extra_lane(out)
    elif not prep.read(out/'supplemental_lane.json')['pass_']:raise RuntimeError('prior helper run failed')
    z_fixed(out);original.mutation(out);original.optimized(out);original.provenance(out)
