"""MEM native S01-S05 only. No RTL SRF integration or CModel timing patch."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
if os.name == 'nt':
    ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002 | 0x8000)
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CM = ROOT.parent / 'FTLPU-CMODEL'
CM_SHA = 'c7ae225b9cdd4a5fb5d96e7b1eabcf484dedc0ec'
CORE = ['rtl/mem_native/' + s + '.sv' for s in [
    'mem_bank_superlane_leaf', 'mem_bank_control_column', 'mem_logical_bank_column',
    'mem_slice', 'mem_group', 'mem_hemisphere']]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, obj):
    Path(path).write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def git(root, *args):
    return subprocess.check_output(['git', '-c', 'safe.directory=' + root.as_posix(),
                                    '-C', str(root), *args], text=True).strip()


def execute(args, cwd, log, timeout=600):
    args = [str(x) for x in args]
    command = args
    if args[0].lower().endswith(('.bat', '.cmd')):
        command = os.environ.get('COMSPEC', 'cmd.exe') + ' /d /s /c "' + \
            ' '.join('"' + a + '"' for a in args) + '"'
    with Path(log).open('w', encoding='utf-8') as f:
        f.write('COMMAND ' + subprocess.list2cmdline(args) + '\n'); f.flush()
        process = subprocess.Popen(command, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            process.wait(); code = -999
    result = dict(command=args, exit=code, timeout=code == -999, log=str(log))
    save(Path(log).with_suffix('.command.json'), result)
    return result


def required(args, cwd, log, timeout=600):
    result = execute(args, cwd, log, timeout)
    if result['exit'] != 0:
        raise RuntimeError('command failed: ' + str(log))
    return result


def compile_sim(out, name, sources, top, generics=()):
    tools = read(out / 'tools.json')
    work = out / name; work.mkdir(parents=True, exist_ok=False)
    filelist = work / 'sources.f'
    filelist.write_text(''.join(Path(p).as_posix() + '\n' for p in sources), encoding='utf-8')
    save(work / 'source_identity.json', {str(p): sha(p) for p in sources})
    required([tools['xvlog'], '--sv', '-f', filelist], work, work / 'compile.txt')
    required([tools['xelab'], top, '-s', 'mem_sim', '--debug', 'typical', '--O0',
              '--timescale', '1ns/1ps', *[x for g in generics for x in ['-generic_top', g]]],
             work, work / 'elaborate.txt')
    return work


def simulate(out, work, name, plus=(), marker='TEST_PASS', failure=None, timeout=900):
    tools = read(out / 'tools.json')
    result = execute([tools['xsim'], 'mem_sim', '-runall',
                      *[x for p in plus for x in ['-testplusarg', p]]],
                     work, work / (name + '.txt'), timeout)
    text = Path(result['log']).read_text(encoding='utf-8', errors='replace')
    if failure:
        ok = not result['timeout'] and failure in text and 'Fatal:' in text and 'UNEXPECTED_' not in text
    else:
        ok = result['exit'] == 0 and marker in text and not re.search(r'Fatal:|FATAL|TEST_FAIL|ERROR:', text)
    result.update(pass_=bool(ok), failure=failure)
    save(work / (name + '.result.json'), result)
    print(name, 'PASS' if ok else 'FAIL', flush=True)
    if not ok:
        raise RuntimeError('simulation failed: ' + result['log'])
    return result


def protected():
    paths = []
    for directory in ['rtl', 'sim', 'scripts', 'spec_new_c7ae225']:
        paths += [p for p in (ROOT / directory).rglob('*') if p.is_file() and HERE not in p.parents]
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(paths)}


def prepare(out):
    out.mkdir(parents=True, exist_ok=False)
    assert git(CM, 'rev-parse', 'HEAD') == CM_SHA and not git(CM, 'status', '--porcelain', '--untracked-files=no')
    for rel in CORE:
        target = out / 'before' / rel; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, target)
    for directory in ['include', 'src', 'config', 'cmake']:
        shutil.copytree(CM / directory, out / 'reference_source' / directory)
    vivado = Path('C:/Users/huazh/Desktop/Vivado2023/Vivado/2023.2/bin')
    tools = {k: str(vivado / (k + '.bat')) for k in ['xvlog', 'xelab', 'xsim']}
    tools.update(cmake=shutil.which('cmake'), compiler=shutil.which('g++'),
                 iverilog=shutil.which('iverilog'), vvp=shutil.which('vvp'))
    assert all(Path(tools[k]).is_file() for k in ['xvlog', 'xelab', 'xsim'])
    save(out / 'tools.json', tools)
    required([tools['xvlog'], '--version'], out, out / 'xvlog_version.txt')
    required([tools['compiler'], '--version'], out, out / 'compiler_version.txt')
    wsl = execute(['wsl.exe', '--list', '--quiet'], out, out / 'wsl_probe.txt', 30)
    save(out / 'manifest_before.json', dict(
        reference_sha=CM_SHA, reference_files={p.relative_to(out).as_posix(): sha(p)
            for p in (out / 'reference_source').rglob('*') if p.is_file()},
        source_revision=git(ROOT, 'rev-parse', 'HEAD'), protected=protected(),
        core={p: sha(ROOT / p) for p in CORE},
        authorization='S01-S05 RTL only; E power-of-two; legacy16/32 retained; no CModel/SRF integration edits',
        wsl_probe=wsl, cmodel_timing_adaptation=False))
    print('MEM_PREPARED', out, flush=True)


def baseline(out, current=False):
    base = ROOT if current else out / 'before'
    work = compile_sim(out, 'baseline_new' if current else 'baseline_old',
                       [base / p for p in CORE] + [HERE / 'baseline_tb.sv'], 'mem_p1_baseline_tb')
    trace = work / 'trace.txt'
    simulate(out, work, 'run', ['TRACE=' + trace.as_posix()], 'MEM_BASELINE TEST_PASS')
    if current:
        assert trace.read_bytes() == (out / 'baseline_old/trace.txt').read_bytes(), 'legacy trace changed'
        save(out / 'baseline_compatibility.json', dict(pass_=True, trace_sha256=sha(trace),
             cold_initialization_excluded_from_legacy_trace=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['prepare', 'baseline', 'compat'])
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id): parser.error('invalid run ID')
    out = ROOT / 'build/mem_p1' / args.run_id
    {'prepare': prepare, 'baseline': baseline, 'compat': lambda x: baseline(x, True)}[args.stage](out)
