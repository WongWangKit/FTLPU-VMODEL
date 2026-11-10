"""Parser regression only. Historical report fixtures are not current L5 evidence."""
from pathlib import Path
import json
import re
import shutil
import sys

from physical_acceptance import inspect

E = Path(__file__).resolve().parents[1]
out = E / 'results' / sys.argv[1]
out.mkdir(exist_ok=False)
fixture = E / 'results/parser_test01'
rows = []


def case(name, file=None, mutate=None, expect_pass=False, expect_error=False):
    run = out / name
    for sub in ['routed', 'synthesized']:
        shutil.copytree(fixture / sub, run / sub)
    if file:
        p = run / file
        before = p.read_text(encoding='utf-8')
        after = mutate(before)
        assert before != after, f'{name}: ineffective test mutation'
        p.write_text(after, encoding='utf-8')
    try:
        result = inspect(run)
        passed = not expect_error and result['pass_'] == expect_pass
        observed = result
    except (AttributeError, ValueError, FileNotFoundError) as exc:
        passed, observed = expect_error, repr(exc)
    rows.append(dict(name=name, pass_=passed, observed=observed))


case('anchored_clock_stub', expect_pass=True)
case('internal_data_gap', 'routed/route_gap_nets.txt', lambda s: s + '\nGAP_NETS u_core/data\n')
case('internal_partial_clock', 'routed/route_gap_nets.txt', lambda s: s + '\nPARTIAL_NETS u_core/clk\n')
case('unanchored_stub', 'routed/clock_and_internal_sta.txt', lambda s: s.replace('BUFGCE_X0Y120', 'unknown'))
for kind in ['max', 'min']:
    case('negative_' + kind, 'routed/clock_and_internal_sta.txt',
         lambda s, k=kind: re.sub(rf'{k}\.slack_ns=[-\d.]+', f'{k}.slack_ns=-0.001', s))
for key in ['blackbox_count', 'latch_count']:
    case(key, 'synthesized/checks.txt', lambda s, k=key: s.replace(k + '=0', k + '=1'))
case('extra_clock', 'synthesized/checks.txt', lambda s: s.replace('clocks=clk', 'clocks=clk other'))
for key in ['no_clock', 'constant_clock', 'multiple_clock', 'unconstrained_internal_endpoints', 'loops', 'latch_loops']:
    case(key, 'routed/check_timing.rpt',
         lambda s, k=key: s.replace(f'checking {k} (0)', f'checking {k} (1)'))
case('drc_violation', 'routed/drc.rpt', lambda s: re.sub(r'Violations found:\s*0', 'Violations found: 1', s))
case('missing_slack_field', 'routed/clock_and_internal_sta.txt',
     lambda s: re.sub(r'max\.slack_ns=[-\d.]+', 'missing', s), expect_error=True)
(out / 'scope.txt').write_text('Acceptance-parser regression only; mutated historical fixtures, not current RTL/STA verification.\n')
summary = dict(total=len(rows), passed=sum(r['pass_'] for r in rows), cases=rows)
(out / 'summary.json').write_text(json.dumps(summary, indent=2))
print(f"parser: {summary['passed']}/{summary['total']}")
raise SystemExit(0 if summary['passed'] == summary['total'] else 1)
