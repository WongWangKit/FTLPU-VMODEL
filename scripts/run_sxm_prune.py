"""Small RTL-only pruning regression. Linux/WSL + Verilator; never runs synthesis.

Examples: python3 scripts/run_sxm_prune.py /path/to/new-run --tiles 2 4 8
Builds the current RTL and an immutable pre-pruning reference in the same TB.
Checks clock-edge traces plus the original, unchanged cycle/data goldens.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess

R = Path(__file__).resolve().parents[1]
P = R / 'sim/sxm_prune'
NAMES = ['sxm_triangle_core', 'sxm_triangle_row_frontend', 'sxm_compat_decode',
         'sxm_compat_engine', 'sxm_triangle_full_core']
# Published main ancestor; the five reference modules are identical to the
# local pre-pruning snapshot 9bd20a29 used in the recorded regression.
BASELINE = '468ad6b13e28141cc9b26160876209567bc67ad5'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('output', type=Path)
    ap.add_argument('--tiles', nargs='+', type=int, choices=[2, 4, 8], default=[2, 4, 8])
    ap.add_argument('--part', choices=['all', 'row', 'typed'], default='all')
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    # Project layout keeps reconstructible builds outside retained results.
    tmp = (out.parent.parent / 'tmp' / out.name
           if out.parent.name == 'results' else out / 'tmp')
    tmp.mkdir(parents=True, exist_ok=False)
    frozen_tests = tmp / 'tests'
    shutil.copytree(P, frozen_tests, ignore=shutil.ignore_patterns('results', '__pycache__'))
    src, refs, hashes = [], [], {}
    for n in NAMES:
        rel = f'rtl/sxm_native/{n}.sv'
        data = (R / rel).read_bytes()
        dest = tmp / (n + '.sv')
        dest.write_bytes(data)
        src.append(dest)
        hashes[rel] = hashlib.sha256(data).hexdigest()
        old = subprocess.check_output(['git', '-c', f'safe.directory={R}', '-C', str(R),
                                       'show', f'{BASELINE}:{rel}']).decode()
        for module in NAMES:
            old = re.sub(r'\b' + module + r'\b', 'baseline_' + module, old)
        dest = tmp / ('baseline_' + n + '.sv')
        dest.write_text(old)
        refs.append(dest)
    cases = json.loads((frozen_tests / 'cases.json').read_text())
    for p in frozen_tests.rglob('*'):
        if p.is_file() and (p.suffix in ['.sv', '.hex'] or p.name == 'cases.json'):
            hashes[str(Path('sim/sxm_prune') / p.relative_to(frozen_tests))] = hashlib.sha256(p.read_bytes()).hexdigest()
    (out / 'manifest.json').write_text(json.dumps(dict(baseline=BASELINE, hashes=hashes), indent=2))
    env = dict(os.environ, VERILATOR_ROOT='/usr/local/share/verilator',
               VERILATOR_BIN='../../bin/verilator_bin', MAKEFLAGS='OPT_FAST=-O0')
    results = []

    def build(T, port, typed):
        top = 'sxm_triangle_core_tb' if typed else 'sxm_compatible_core_tb'
        tag = f'{top}_t{T}_p{port}'
        obj = tmp / tag
        cmd = ['/usr/local/bin/verilator', '--binary', '--timing', '-j', '2',
               '--unroll-count', '4096', '--unroll-stmts', '1000000',
               '--top-module', top, f'-GT={T}', '--Mdir', str(obj)]
        if not typed:
            cmd += [f'-GPORT_STREAMS={port}']
        cmd += [str(p) for p in (src[:1] + refs[:1] if typed else src + refs)]
        cmd += [str(frozen_tests / (top + '.sv'))]
        print('BUILD', tag, flush=True)
        (out / (tag + '.command.json')).write_text(json.dumps(cmd, indent=2))
        with (out / (tag + '.build.log')).open('w') as log:
            subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        return obj / ('V' + top)

    def run(exe, name, params, marker, **meta):
        result = subprocess.run([str(exe), *params], capture_output=True, text=True)
        (out / (name + '.log')).write_text(result.stdout + result.stderr)
        ok = result.returncode == 0 and marker in result.stdout
        results.append(dict(name=name, pass_=ok, **meta))
        (out / 'summary.json').write_text(json.dumps(dict(
            passed=sum(x['pass_'] for x in results), total=len(results), results=results), indent=2))
        print(name, 'PASS' if ok else 'FAIL', flush=True)
        if not ok:
            raise RuntimeError(result.stdout + result.stderr)

    for T in args.tiles:
        if args.part in ('all', 'typed'):
            exe = build(T, 0, True)
            for mode in (0, 1):
                for fp in (0, 1):
                    # N=32 also covers the existing 8-bit timer wrap test.
                    for count in (2, 32):
                        run(exe, f'typed_t{T}_m{mode}_f{fp}_n{count}',
                            [f'+MODE={mode}', f'+FP={fp}', f'+N={count}'],
                            'PASS CORE', T=T, compare=True)
            for neg in range(1, 8):
                run(exe, f'typed_t{T}_negative{neg}',
                    ['+MODE=1', '+FP=1', '+N=1', f'+NEG={neg}'],
                    'PASS CORE', T=T, compare=False)
        if args.part in ('all', 'row'):
            for port in (16, 32):
                exe = build(T, port, False)
                for case in cases:
                    if case['T'] != T or case['port'] != port:
                        continue
                    run(exe, case['name'],
                        [f'+CASE={frozen_tests / "cases" / case["name"]}',
                         f'+CYCLES={case["cycles"]}', f'+COMPAT={case["compat"]}',
                         f'+COMPARE={int(case["compare"])}'],
                        'SXM_COMPATIBLE_CORE PASS', T=T, compare=case['compare'], origin=case['origin'])


if __name__ == '__main__':
    main()
