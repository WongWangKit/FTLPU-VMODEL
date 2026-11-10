"""Task-scoped lease spanning queue replacement, edits and report collection.
Stops on results/RUN/stop.request or after 12 awake hours. Allows display-off.
Does not launch/kill EDA jobs and does not change global power settings.
"""
from pathlib import Path
import sys,time,json,os
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1]
sys.path.insert(0,str(ROOT/'learn/sxm_gap10_20261104/scripts'))
from host_runtime import WindowsRuntime,KeepAwake,AwakeDeadline
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False)
runtime=WindowsRuntime();deadline=AwakeDeadline(43200,runtime.awake_seconds)
with KeepAwake(runtime) as lease:
 (out/'lease.json').write_text(json.dumps(dict(pid=os.getpid(),started=time.time(),previous=lease.previous,display_required=False,global_power_plan_changed=False,timeout_awake_seconds=43200),indent=2))
 while not (out/'stop.request').exists() and not deadline.sample()['expired']:
  (out/'heartbeat.json').write_text(json.dumps(dict(timestamp=time.time(),**deadline.sample()),indent=2));time.sleep(30)
(out/'finished.json').write_text(json.dumps(dict(finished=time.time(),released=lease.released,**deadline.sample()),indent=2))
