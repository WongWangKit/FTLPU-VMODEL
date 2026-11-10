"""Read-only publication preflight; --staged reads INDEX bytes, not working copies.

This catches common credentials/artifacts and evidence drift, not every secret.
No staging, commit, branch change, hook installation, or remote push is performed.
"""
from pathlib import Path
import argparse
import atexit
import datetime
import functools
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
mode = ap.add_mutually_exclusive_group()
mode.add_argument('--staged', action='store_true')
mode.add_argument('--base', help='scan committed HEAD changes relative to this base, e.g. origin/develop')
a = ap.parse_args()


def git(*args, data=None):
    return subprocess.check_output(['git', '-c', f'safe.directory={ROOT.as_posix()}',
                                    '-C', str(ROOT), *args], input=data)


def names(*args):
    return [s for s in git(*args).decode('utf-8').split('\0') if s]


blob_reader = None


def close_reader():
    if blob_reader is not None:
        blob_reader.stdin.close()
        blob_reader.wait(timeout=10)


atexit.register(close_reader)


@functools.lru_cache(maxsize=None)
def read(rel):
    global blob_reader
    if a.staged or a.base:
        if '\n' in rel or '\0' in rel:
            raise ValueError('Unsupported Git path separator')
        if blob_reader is None:
            blob_reader = subprocess.Popen(
                ['git', '-c', f'safe.directory={ROOT.as_posix()}', '-C', str(ROOT), 'cat-file', '--batch'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        request = (':' if a.staged else 'HEAD:') + rel
        blob_reader.stdin.write((request + '\n').encode('utf-8'))
        blob_reader.stdin.flush()
        header = blob_reader.stdout.readline().split()
        if len(header) != 3 or header[1] != b'blob':
            raise FileNotFoundError(rel)
        raw = blob_reader.stdout.read(int(header[2]))
        if blob_reader.stdout.read(1) != b'\n':
            raise RuntimeError('Invalid Git batch response')
        return raw
    return (ROOT / rel).read_bytes()


if a.staged:
    selected = names('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z')
elif a.base:
    selected = names('diff', a.base, 'HEAD', '--name-only', '--diff-filter=ACMR', '-z')
else:
    selected = sorted(set(names('diff', 'HEAD', '--name-only', '--diff-filter=ACMR', '-z') +
                          names('ls-files', '--others', '--exclude-standard', '-z')))

errors = []
records = []
scopes = [x.strip() for x in read('config/sxm_publication_paths.txt').decode('utf-8-sig').splitlines() if x.strip()]
for rel in selected:
    if not any(rel == scope or rel.startswith(scope + '/') for scope in scopes):
        errors.append(dict(path=rel, rule='outside_reviewed_publication_scope'))
forbidden_dirs = {'.git', '.ssh', '.aws', '.azure', '.codex', '.agents', 'tmp', 'build',
                  '.Xil', 'xsim.dir', 'obj_dir', '__pycache__', 'node_modules'}
forbidden_ext = {'.dcp', '.wdb', '.vcd', '.fst', '.fsdb', '.exe', '.dll', '.o', '.obj',
                 '.pb', '.jou', '.pem', '.key', '.p12', '.pfx', '.jks', '.lic', '.zip', '.7z'}
patterns = {
    'private_key': rb'(?m)^\s*-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----',
    'github_token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b',
    'aws_access_key': rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'api_secret_token': rb'\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b',
    'credential_url': rb'https?://[^\s/"<>:@]+:[^\s/"<>@]+@',
    'secret_assignment': rb'''(?im)^\s*["']?(?:api_key|access_token|password|client_secret)["']?\s*[:=]\s*["'][A-Za-z0-9_+/=-]{20,}["']''',
    'personal_windows_path': rb'(?i)[A-Z]:[/\\]+Users[/\\]+(?!<|PUBLIC[/\\]|Default[/\\])[^/\\\s"<>]+',
    'personal_wsl_path': rb'(?i)/mnt/[a-z]/Users/(?!<|PUBLIC/|Default/)[^/\s"<>]+',
    'personal_linux_path': rb'/home/(?!<)[^/\s"<>]+/',
}
for rel in selected:
    p = Path(rel)
    if (any(x in forbidden_dirs for x in p.parts) or p.suffix.lower() in forbidden_ext or
        p.name in {'synthesized.v', 'routed.v', 'netlist.v', 'credentials.json', 'license.dat', '.git-credentials', '.netrc'} or
        p.name.startswith('secrets.') or '.local.' in p.name or
        (p.name.startswith('.env') and p.name not in {'.env.example', '.env.template'})):
        errors.append(dict(path=rel, rule='excluded_artifact_or_sensitive_filename'))
        continue
    raw = read(rel)
    if len(raw) >= 50 * 1024**2:
        errors.append(dict(path=rel, rule='file_at_least_50_MiB'))
    for rule, pattern in patterns.items():
        if re.search(pattern, raw):
            errors.append(dict(path=rel, rule=rule))  # Never print matched values.
    records.append(dict(path=rel, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))

publication = 'sim/sxm_writetap/results/20261110_pause/publication_manifest.json'
try:
    m = json.loads(read(publication))
    for x in m['files']:
        raw = read(x['published'])
        if hashlib.sha256(raw).hexdigest() != x['published_sha256']:
            errors.append(dict(path=x['published'], rule='published_evidence_hash_changed'))
    for rel, expected in m['source_rtl_lf_sha256'].items():
        if hashlib.sha256(read(rel).replace(b'\r\n', b'\n')).hexdigest() != expected:
            errors.append(dict(path=rel, rule='RTL_changed_since_evidence_export'))
    if len(m['local_only_artifacts']) != 10 or m['completed_syntheses'] != 5 or m['routed_checkpoints'] != 0:
        errors.append(dict(path=publication, rule='unexpected_completion_inventory'))
except (FileNotFoundError, subprocess.CalledProcessError, KeyError) as exc:
    errors.append(dict(path=publication, rule='missing_evidence_or_source', detail=type(exc).__name__))

# Check ignore behavior without creating dummy secrets or modifying the index.
ignored = ['.env', '.aws/credentials', 'config/tools.local.json', 'tmp/compile.o',
           'build/synthesized.v', 'sim/sxm_writetap/results/test/a.dcp',
           'sim/sxm_writetap/results/test/synthesized.v',
           'sim/sxm_writetap/results/test/credentials.json',
           'spec_new_c7ae225/archive/test/backup.md']
allowed = ['spec_new_c7ae225/sxm设计与参数化方案.md',
           'spec_new_c7ae225/SXM三角主设计回归测试清单.md',
           'sim/sxm_writetap/results/test/synth_utilization.rpt',
           'sim/sxm_writetap/results/test/vivado.log', 'sim/vectors/test.hex']
for path, expected in [(p, True) for p in ignored] + [(p, False) for p in allowed]:
    proc = subprocess.run(['git', '-c', f'safe.directory={ROOT.as_posix()}', '-C', str(ROOT),
                           'check-ignore', '--no-index', '-q', '--', path])
    if proc.returncode not in [0, 1] or (proc.returncode == 0) != expected:
        errors.append(dict(path=path, rule='ignore_rule_mismatch', expected_ignored=expected))

result = dict(passed=not errors, scope='index' if a.staged else 'committed HEAD vs ' + a.base if a.base else 'working changes and untracked candidates',
              files=len(records), bytes=sum(x['bytes'] for x in records), errors=errors,
              limitations=['Pattern scan is not an exhaustive secret audit.',
                           'Existing unchanged history is outside this change-set scan.',
                           'No post-merge RTL regression is claimed.'])
out = ROOT / 'build/publication_check'
out.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
(out / (stamp + '.json')).write_text(json.dumps(dict(**result, manifest=records), ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
raise SystemExit(0 if result['passed'] else 1)
