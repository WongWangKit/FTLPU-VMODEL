"""Windows EDA lifetime: awake-time deadline and task-scoped idle-sleep request."""
import ctypes
from ctypes import wintypes
from pathlib import Path
import json
import os
import shutil
import subprocess
import time

ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001


class WindowsRuntime:
    def __init__(self):
        if os.name != 'nt':
            raise RuntimeError('This runner requires Windows native awake-time APIs')
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.QueryUnbiasedInterruptTime.argtypes = [ctypes.POINTER(ctypes.c_ulonglong)]
        self.kernel.QueryUnbiasedInterruptTime.restype = wintypes.BOOL
        self.kernel.SetThreadExecutionState.argtypes = [wintypes.DWORD]
        self.kernel.SetThreadExecutionState.restype = wintypes.DWORD

    def awake_seconds(self):
        ticks = ctypes.c_ulonglong()
        if not self.kernel.QueryUnbiasedInterruptTime(ctypes.byref(ticks)):
            raise ctypes.WinError(ctypes.get_last_error())
        return ticks.value / 10_000_000

    def execution_state(self, flags):
        previous = self.kernel.SetThreadExecutionState(flags)
        if not previous:
            raise ctypes.WinError(ctypes.get_last_error())
        return previous


class AwakeDeadline:
    def __init__(self, seconds, awake_clock, wall_clock=time.monotonic):
        if seconds <= 0:
            raise ValueError('timeout must be positive')
        self.seconds = seconds
        self.awake_clock, self.wall_clock = awake_clock, wall_clock
        self.awake_start, self.wall_start = awake_clock(), wall_clock()

    def sample(self):
        awake = self.awake_clock() - self.awake_start
        wall = self.wall_clock() - self.wall_start
        return dict(awake_seconds=round(awake, 6), wall_seconds=round(wall, 6),
                    excluded_sleep_seconds=round(max(0, wall - awake), 6),
                    expired=awake >= self.seconds)


class KeepAwake:
    """Same-thread request only; no display request or global power-plan edits."""
    def __init__(self, runtime):
        self.runtime = runtime
        self.previous = None
        self.released = False

    def __enter__(self):
        self.previous = self.runtime.execution_state(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
        return self

    def __exit__(self, exc_type, exc, tb):
        self.runtime.execution_state(self.previous | ES_CONTINUOUS)
        self.released = True


def stop_owned_child(process, log):
    if process.poll() is None:
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                       stdout=log, stderr=log, check=True)
        process.wait()


def run_command(command, *, out, work, env, timeout, prefix='', poll_seconds=30,
                sample_interval=300):
    out, work = Path(out), Path(work)
    runtime = WindowsRuntime()
    deadline = AwakeDeadline(timeout, runtime.awake_seconds)
    lease = KeepAwake(runtime)
    process = None
    result = dict(clock='QueryUnbiasedInterruptTime', timeout_awake_seconds=timeout,
                  keep_awake='ES_CONTINUOUS | ES_SYSTEM_REQUIRED',
                  display_required=False, global_power_plan_changed=False)
    started = time.time()
    snapshot = Path(__file__).with_name('sample_owned_process.ps1')
    pwsh = '<USER_HOME>/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
    with (out / (prefix + 'console.log')).open('w', encoding='utf-8') as log:
        try:
            with lease:
                process = subprocess.Popen(command, cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT)
                (out / (prefix + 'process.json')).write_text(json.dumps(dict(
                    pid=process.pid, started=started, timeout=timeout, timeout_clock=result['clock']), indent=2), encoding='utf-8')
                next_sample = 0
                with (out / (prefix + 'host_samples.jsonl')).open('w', encoding='utf-8', buffering=1) as samples:
                    while True:
                        t = deadline.sample()
                        if t['awake_seconds'] >= next_sample:
                            item = dict(timestamp=time.time(), **t)
                            try:
                                probe = subprocess.run([pwsh, '-NoProfile', '-File', str(snapshot),
                                                        '-RootPid', str(process.pid)],
                                                       capture_output=True, text=True, encoding='utf-8', timeout=30)
                                if probe.returncode == 0:
                                    item['host'] = json.loads(probe.stdout)
                                else:
                                    item['sampling_error'] = dict(exit_code=probe.returncode, stderr=probe.stderr)
                            except (subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
                                # Diagnostic sampling may itself be slow under paging; record it
                                # without killing a valid computation or fabricating a measurement.
                                item['sampling_error'] = repr(exc)
                            samples.write(json.dumps(item) + '\n')
                            next_sample = t['awake_seconds'] + sample_interval
                        try:
                            rc = process.wait(timeout=poll_seconds)
                            result.update(exit_code=rc, status='completed' if rc == 0 else 'failed')
                            break
                        except subprocess.TimeoutExpired:
                            t = deadline.sample()
                            free = shutil.disk_usage(work.anchor).free
                            reason = 'host_disk_pressure' if free < 6 * 1024**3 else ('timeout' if t['expired'] else None)
                            if reason:
                                (out / (prefix + 'stop_reason.json')).write_text(json.dumps(dict(
                                    reason=reason, free_bytes=free, **t), indent=2), encoding='utf-8')
                                stop_owned_child(process, log)
                                result.update(exit_code=None, status=reason)
                                break
        except BaseException as exc:
            result.update(status='runner_error', error=repr(exc))
            if process is not None:
                stop_owned_child(process, log)
            raise
        finally:
            result.update(deadline.sample())
            result.update(started=started, finished=time.time(),
                          keep_awake_previous=lease.previous, keep_awake_released=lease.released)
            (out / (prefix + 'runtime.json')).write_text(json.dumps(result, indent=2), encoding='utf-8')
    return result['exit_code'], result['status']
