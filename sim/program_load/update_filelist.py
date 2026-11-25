"""Regenerate the production dependency closure, excluding RTL test snapshots."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]

def clean(text):
    return re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)

modules, packages, sources = {}, {}, {}
for path in sorted((ROOT / 'rtl').rglob('*.sv')):
    if any(part in {'test', 'tests', 'baseline'} for part in path.relative_to(ROOT).parts):
        continue
    text = clean(path.read_text(encoding='utf-8-sig'))
    sources[path] = text
    for kind, table in [('module', modules), ('package', packages)]:
        for name in re.findall(r'\b' + kind + r'\s+(\w+)', text):
            if name in table:
                raise RuntimeError(f'Duplicate {kind}: {name}: {path}, {table[name]}')
            table[name] = path

ordered, seen = [], set()
def visit(path):
    if path in seen:
        return
    seen.add(path)
    text = sources[path]
    for name in sorted(set(re.findall(r'\b(\w+)::', text))):
        if name in packages:
            visit(packages[name])
    for name in re.findall(r'^\s*((?:lpu_|ftlpu_|mem_|c2c_|sxm_)[A-Za-z0-9_]+)\s*(?:#\s*\(|\s+[A-Za-z_]\w*\s*\()', text, re.M):
        visit(modules[name])
    ordered.append(path)

visit(modules['lpu_top'])
target = ROOT / 'sim/filelist_program_integrated.f'
target.write_text(''.join(p.relative_to(ROOT).as_posix() + '\n' for p in ordered), encoding='utf-8')
benches = ['program_transport_tb', 'program_mem_native_tb', 'program_frontends_tb',
           'program_qctl_tb', 'program_mem_subsystem_tb', 'program_system_tb', 'native_chain_tb']
(ROOT / 'sim/filelist.f').write_text(target.read_text() + ''.join(
    f'sim/program_load/{name}.sv\n' for name in benches), encoding='utf-8')
print(f'{target}: {len(ordered)} production files')
