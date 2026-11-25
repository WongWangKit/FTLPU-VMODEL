"""Produce a release-independent P0 numerical summary from completed RTL logs."""
import json,re,sys
from pathlib import Path
root=Path(__file__).resolve().parents[4]/"learn/data_dma_ip_p0_20261125/results"
run=root/sys.argv[1]
out={}
for v in (16,32):
    p=run/str(v)
    def log(n):
        s=(p/f"case{n}.log").read_text(encoding="utf-8",errors="replace")
        if "Fatal:" in s or f"PASS shared DMA V={v} " not in s or f"case={n} " not in s:
            raise ValueError((v,n))
        return s
    def numbers(s,marker):
        line=next(x for x in s.splitlines() if x.startswith(marker))
        return {k:int(value) for k,value in re.findall(r"(\w+)=(\d+)",line)}
    bounds=numbers(log(30),"P0 BOUNDS")
    handoff=log(31)
    assert "hardware ready, host withheld retirement" in handoff
    drv=numbers(handoff,"P0 DRIVER")
    assert (drv['pages'],drv['segments'],drv['consumers'],drv['data_AR'])==(2,4,3,4)
    flow=numbers(log(32),"P0 FLOW")
    assert all(flow[k]==bounds["RT"] for k in ("RX","TX","read_live","B_due"))
    ident=numbers(log(34),"P0 ID")
    assert ident["limit"]==(bounds["Q"]+7)//8 and ident["writes"]==7*ident["limit"]+8
    tail=log(33)
    samples=[numbers(x,"PAGE_SAMPLE") for x in tail.splitlines() if x.startswith("PAGE_SAMPLE")]
    assert [x["idx"] for x in samples]==list(range(100))
    lat=sorted(x["latency"] for x in samples)
    out[f"LPU{v}"]=dict(config=bounds,driver=drv,flow=flow,per_id=ident,
        flow_payload_bytes_per_clock=2*flow["bytes_each"]/flow["elapsed"],
        page_wait_clocks=dict(samples=len(lat),p50=lat[49],p95=lat[94],p99=lat[98],max=lat[-1]),
        tail_load_store_bytes=sum(2*x["bytes"] for x in samples))
report=run/"metrics.json"
if report.exists():raise FileExistsError(report)
report.write_text(json.dumps(out,indent=2)+"\n",encoding="utf-8")
print(report)
