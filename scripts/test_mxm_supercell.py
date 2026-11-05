"""Generate independent vectors, elaborate RTL and run Supercell regressions.

Requires Icarus Verilog (iverilog/vvp) on PATH or under build/iverilog/bin.
The optional --compile-only path uses pyslang, including build/tools installs.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/mxm_supercell'
os.chdir(ROOT)


def tool(name):
    candidate = ROOT / 'build/iverilog/bin' / (name + ('.exe' if os.name == 'nt' else ''))
    if candidate.is_file():
        return str(candidate)
    found = shutil.which(name)
    if not found:
        raise SystemExit(f'{name} not found; install Icarus Verilog or use --compile-only')
    return found


def run(command, log):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (BUILD / log).write_text(result.stdout, encoding='utf-8')
    if result.returncode:
        print(result.stdout[-12000:])
        raise SystemExit(f'FAILED: {log} (exit {result.returncode})')
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--top', help='Run only one test top')
    parser.add_argument('--trace', action='store_true', help='Export public-port CSV/VCD for control, frontend, backend and core benches')
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    tops = ['lpu_mxm_bf16_dot_csa_tb', 'lpu_mxm_fp32_add_pipe_tb', 'lpu_mxm_output_pipe_tb',
            'lpu_mxm_supercell_tb', 'lpu_mxm_supercell_chain_tb',
            'lpu_mxm_control_tb', 'lpu_mxm_frontend_tb', 'lpu_mxm_backend_tb', 'lpu_mxm_core_tb']
    if args.top:
        tops = [args.top]
    if args.top == 'lpu_top' and not args.compile_only:
        parser.error('lpu_top is supported here only with --compile-only')
    sources = [line.strip() for line in (ROOT/'sim/filelist_mxm_supercell.f').read_text().splitlines()
               if line.strip() and not line.startswith('#')]
    if args.compile_only:
        sys.path.insert(0, str(ROOT/'build/tools'))
        from pyslang.driver import Driver
        for top in tops:
            compile_sources = sources
            benches = [f'sim/tb/mxm/{top}.sv']
            if top == 'lpu_top':
                compile_sources = [line.strip() for line in (ROOT/'sim/filelist.f').read_text().splitlines()
                                   if line.strip().startswith('rtl/')]
                benches = []
            driver = Driver()
            driver.addStandardArgs()
            driver.setTerminalColorsEnabled(False)
            if not driver.parseCommandLine(f"slang {' '.join(compile_sources + benches)} --top {top} --timescale 1ns/1ps"):
                raise SystemExit('invalid compilation arguments')
            if not driver.processOptions() or not driver.parseAllSources():
                raise SystemExit('source parse failed')
            compilation = driver.createCompilation()
            driver.reportCompilation(compilation, True)
            if not driver.reportDiagnostics(False):
                raise SystemExit(f'{top} compile FAIL')
            print(f'{top} compile PASS', flush=True)
        return

    spec = importlib.util.spec_from_file_location('mxm_reference', ROOT/'sim/cmodel/generate_mxm_supercell_vectors.py')
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    dot_count, add_count = reference.generate(BUILD/'vectors')
    iverilog, vvp = tool('iverilog'), tool('vvp')
    for top in tops:
        sizes = [1,3,8,16] if top == 'lpu_mxm_bf16_dot_csa_tb' else (
            [(8,8),(3,3),(1,1),(3,5)] if top == 'lpu_mxm_supercell_tb' else (
            [(1,1),(2,3),(4,1),(4,3)] if top == 'lpu_mxm_control_tb' else (
            [(1,1),(1,3),(4,8)] if top == 'lpu_mxm_backend_tb' else (
            [0,1,2,3,4,5,6,7] if top == 'lpu_mxm_core_tb' else [None]))))
        for size in sizes:
            if top == 'lpu_mxm_core_tb':
                suffix = f'_s{size}' if size else ''
            else:
                suffix = (f'_k{size[0]}_n{size[1]}' if isinstance(size,tuple) else f'_k{size}') if size else ''
            name = top + suffix
            output = BUILD / (name+'.vvp')
            command = [iverilog, '-g2012', '-s', top, '-o', str(output)]
            if isinstance(size,tuple):
                fields = (('ROWS','QUEUE_DEPTH') if top == 'lpu_mxm_control_tb' else (
                          ('COLS','LANES') if top == 'lpu_mxm_backend_tb' else ('TERMS','OUTPUTS')))
                command += ['-P', f'{top}.{fields[0]}={size[0]}', '-P', f'{top}.{fields[1]}={size[1]}']
            elif top == 'lpu_mxm_core_tb':
                command += ['-P', f'{top}.SCENARIO={size}']
            elif size:
                command += ['-P', f'{top}.TERMS={size}']
            command += sources + [f'sim/tb/mxm/{top}.sv']
            run(command, name+'_compile.log')
            command = [vvp, str(output)]
            if args.trace and top in ('lpu_mxm_control_tb','lpu_mxm_frontend_tb','lpu_mxm_backend_tb','lpu_mxm_core_tb'):
                trace_dir = BUILD/'traces'
                trace_dir.mkdir(parents=True, exist_ok=True)
                command += [f'+trace_path={(trace_dir/(name+".csv")).as_posix()}',
                            f'+vcd_path={(trace_dir/(name+".vcd")).as_posix()}']
            if size and not isinstance(size,tuple) and top != 'lpu_mxm_core_tb':
                command += [f'+vectors={(BUILD/f"vectors/dot_k{size}.hex").as_posix()}', f'+count={dot_count}']
            elif top == 'lpu_mxm_fp32_add_pipe_tb':
                command += [f'+vectors={(BUILD/"vectors/fp32_add.hex").as_posix()}', f'+count={add_count}']
            elif top == 'lpu_mxm_backend_tb':
                command += [f'+vectors={(BUILD/"vectors/backend.hex").as_posix()}',
                            f'+output_vectors={(BUILD/"vectors/backend_output.hex").as_posix()}']
            elif top == 'lpu_mxm_output_pipe_tb':
                command += [f'+vectors={(BUILD/"vectors/output.hex").as_posix()}']
            print(run(command, name+'_run.log'), flush=True)


if __name__ == '__main__':
    main()
