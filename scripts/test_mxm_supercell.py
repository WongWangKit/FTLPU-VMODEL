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


def dequant_trace(iverilog,vvp,sources):
    top='lpu_mxm_weight_dequant_tb'
    name=top+'_trace'
    output=BUILD/(name+'.vvp')
    run([iverilog,'-g2012','-s',top,'-o',str(output),*sources,f'sim/tb/mxm/{top}.sv'],name+'_compile.log')
    trace_dir=BUILD/'traces';trace_dir.mkdir(parents=True,exist_ok=True)
    return run([vvp,str(output),'+count=512',f'+vectors={(BUILD/"vectors/weight_dequant.hex").as_posix()}',
                f'+trace_path={(trace_dir/(name+".csv")).as_posix()}',
                f'+vcd_path={(trace_dir/(name+".vcd")).as_posix()}'],name+'_run.log')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--top', help='Run one test top or comma-separated tops')
    parser.add_argument('--trace', action='store_true', help='Export public-port CSV/VCD for control, frontend, backend and core benches')
    parser.add_argument('--core-scenarios', help='Comma-separated core scenario numbers; defaults to all')
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    tops = ['lpu_mxm_dequant_control_tb', 'lpu_mxm_weight_dequant_tb', 'lpu_mxm_bf16_dot_csa_tb', 'lpu_mxm_fp32_add_pipe_tb', 'lpu_mxm_output_pipe_tb',
            'lpu_mxm_supercell_tb', 'lpu_mxm_supercell_chain_tb',
            'lpu_mxm_control_tb', 'lpu_mxm_compact_isa_tb', 'lpu_mxm_frontend_tb', 'lpu_mxm_weight_shift_tb', 'lpu_mxm_backend_tb',
            'lpu_mxm_backend_config_tb', 'lpu_mxm_result_return_tb', 'lpu_mxm_core_tb']
    if args.top:
        tops = args.top.split(',')
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
    if 'lpu_mxm_weight_dequant_tb' in tops:
        spec_dq=importlib.util.spec_from_file_location('dequant_reference',ROOT/'sim/cmodel/generate_mxm_dequant_vectors.py')
        dequant_reference=importlib.util.module_from_spec(spec_dq)
        spec_dq.loader.exec_module(dequant_reference)
        assert dequant_reference.generate(BUILD/'vectors')==524288
    iverilog, vvp = tool('iverilog'), tool('vvp')
    for top in tops:
        sizes = [1,3,8,16] if top == 'lpu_mxm_bf16_dot_csa_tb' else (
            [(8,8),(3,3),(1,1),(3,5)] if top == 'lpu_mxm_supercell_tb' else (
            [(1,1),(2,3),(4,1),(4,3)] if top == 'lpu_mxm_control_tb' else (
            [(1,1),(1,3),(4,8)] if top == 'lpu_mxm_backend_tb' else (
            [(1,1),(2,3),(3,1),(4,8),(8,3)] if top == 'lpu_mxm_result_return_tb' else (
            list(range(11)) if top == 'lpu_mxm_core_tb' else [None])))))
        if top == 'lpu_mxm_dequant_control_tb':
            sizes = [(1,1),(2,3),(4,1),(4,3)]
        if top == 'lpu_mxm_backend_config_tb':
            sizes = [2,6,1000,1024,2048,65536]
        if top == 'lpu_mxm_weight_shift_tb':
            sizes = [3,1]
        if top == 'lpu_mxm_weight_dequant_tb':
            sizes = [(1,1),(3,1),(8,1),(8,0)]
        if top == 'lpu_mxm_core_tb' and args.core_scenarios:
            sizes = [int(value) for value in args.core_scenarios.split(',')]
        for size in sizes:
            if top == 'lpu_mxm_core_tb':
                suffix = f'_s{size}' if size else ''
            elif top == 'lpu_mxm_backend_config_tb':
                suffix = f'_d{size}'
            elif top == 'lpu_mxm_weight_shift_tb':
                suffix = '' if size==3 else f'_i{size}'
            else:
                suffix = (f'_k{size[0]}_n{size[1]}' if isinstance(size,tuple) else f'_k{size}') if size else ''
            name = top + suffix
            output = BUILD / (name+'.vvp')
            command = [iverilog, '-g2012', '-s', top, '-o', str(output)]
            if isinstance(size,tuple):
                fields = (('LANES','ZERO_ENABLE') if top == 'lpu_mxm_weight_dequant_tb' else (
                          ('ROWS','QUEUE_DEPTH') if top in ('lpu_mxm_control_tb','lpu_mxm_dequant_control_tb') else (
                          ('COLS','LANES') if top == 'lpu_mxm_backend_tb' else (
                          ('ROWS','LANES') if top == 'lpu_mxm_result_return_tb' else ('TERMS','OUTPUTS')))))
                command += ['-P', f'{top}.{fields[0]}={size[0]}', '-P', f'{top}.{fields[1]}={size[1]}']
            elif top == 'lpu_mxm_core_tb':
                command += ['-P', f'{top}.SCENARIO={size}']
            elif top == 'lpu_mxm_backend_config_tb':
                command += ['-P', f'{top}.DEPTH={size}']
            elif top == 'lpu_mxm_weight_shift_tb':
                command += ['-P', f'{top}.LOAD_INTERVAL={size}']
            elif size:
                command += ['-P', f'{top}.TERMS={size}']
            command += sources + [f'sim/tb/mxm/{top}.sv']
            run(command, name+'_compile.log')
            command = [vvp, str(output)]
            if args.trace and top in ('lpu_mxm_control_tb','lpu_mxm_frontend_tb','lpu_mxm_backend_tb','lpu_mxm_core_tb') and not (top=='lpu_mxm_core_tb' and size==8):
                trace_dir = BUILD/'traces'
                trace_dir.mkdir(parents=True, exist_ok=True)
                command += [f'+trace_path={(trace_dir/(name+".csv")).as_posix()}',
                            f'+vcd_path={(trace_dir/(name+".vcd")).as_posix()}']
            if size and not isinstance(size,tuple) and top not in ('lpu_mxm_core_tb','lpu_mxm_backend_config_tb','lpu_mxm_weight_shift_tb'):
                command += [f'+vectors={(BUILD/f"vectors/dot_k{size}.hex").as_posix()}', f'+count={dot_count}']
            elif top == 'lpu_mxm_fp32_add_pipe_tb':
                command += [f'+vectors={(BUILD/"vectors/fp32_add.hex").as_posix()}', f'+count={add_count}']
            elif top == 'lpu_mxm_backend_tb':
                command += [f'+vectors={(BUILD/"vectors/backend.hex").as_posix()}',
                            f'+output_vectors={(BUILD/"vectors/backend_output.hex").as_posix()}']
            elif top == 'lpu_mxm_output_pipe_tb':
                command += [f'+vectors={(BUILD/"vectors/output.hex").as_posix()}']
            elif top == 'lpu_mxm_weight_dequant_tb':
                command += [f'+vectors={(BUILD/"vectors/weight_dequant.hex").as_posix()}']
            print(run(command, name+'_run.log'), flush=True)
        if top == 'lpu_mxm_weight_dequant_tb' and args.trace:
            print(dequant_trace(iverilog,vvp,sources),flush=True)
        if top == 'lpu_mxm_result_return_tb':
            invalid = BUILD / 'lpu_mxm_result_return_rectangle.vvp'
            run([iverilog,'-g2012','-s',top,'-o',str(invalid),
                 '-P',f'{top}.ROWS=1','-P',f'{top}.COLS=2',
                 *sources,f'sim/tb/mxm/{top}.sv'], 'lpu_mxm_result_return_rectangle_compile.log')
            result=subprocess.run([vvp,str(invalid)],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            (BUILD/'lpu_mxm_result_return_rectangle_run.log').write_text(result.stdout,encoding='utf-8')
            if not result.returncode or 'requires a positive square array' not in result.stdout:
                raise SystemExit('non-square return configuration was not rejected')
            print('MXM_RETURN_RECTANGLE_REJECT_PASS',flush=True)


if __name__ == '__main__':
    main()
