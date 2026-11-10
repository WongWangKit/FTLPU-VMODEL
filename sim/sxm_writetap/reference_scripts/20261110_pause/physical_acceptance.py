"""Read actual routed artifacts; never equate tool exit zero with timing PASS."""
from pathlib import Path
import re,json
def inspect(run,source_run=None):
 run=Path(run);r=run/'routed';s=(Path(source_run) if source_run else run)/'synthesized'
 def read(p):return p.read_text(encoding='utf-8',errors='replace')
 timing=read(r/'clock_and_internal_sta.txt');checks=read(s/'checks.txt');ct=read(r/'check_timing.rpt')
 slack={k:float(re.search(rf'{k}\.slack_ns=([-\d.]+)',timing).group(1)) for k in ['max','min']}
 counts={k:int(re.search(rf'{k}=(\d+)',checks).group(1)) for k in ['blackbox_count','latch_count']}
 for k in ['no_clock','constant_clock','multiple_clock','unconstrained_internal_endpoints','loops','latch_loops']:
  counts[k]=int(re.search(rf'checking {k} \((\d+)\)',ct).group(1))
 counts['unexpected_clock_set']=int(re.search(r'^clocks=(.*)$',checks,re.M).group(1).strip()!='clk')
 counts['drc']=int(re.search(r'Violations found:\s*(\d+)',read(r/'drc.rpt')).group(1))
 gaps=[]
 for line in read(r/'route_gap_nets.txt').splitlines():
  fields=line.split()
  if fields and fields[0] in ['GAP_NETS','PARTIAL_NETS']:gaps.extend(fields[1:])
 # OOC has no physical package/parent clock driver. HD.CLK_SRC anchors its
 # distribution; the exact clk_i boundary stub is separate from internal gaps.
 # Do not waive any other data/clock net or a clock without the recorded anchor.
 boundary=[n for n in gaps if n=='clk_i' and 'HD.CLK_SRC=BUFGCE_X0Y120' in timing]
 internal=[n for n in gaps if n not in boundary]
 counts['unrouted_internal_nets']=len(internal)
 result=dict(setup_ns=slack['max'],hold_ns=slack['min'],counts=counts,
  pass_=min(slack.values())>=0 and not any(counts.values()),scope='10ns internal reg-reg, IO separately budgeted',io_report=str(r/'io_budget_timing.rpt'),ooc_clock_boundary_gaps=boundary,internal_route_gaps=internal)
 (run/'acceptance.json').write_text(json.dumps(result,indent=2));return result
