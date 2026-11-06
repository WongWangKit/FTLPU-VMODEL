"""Recheck frozen inputs and evidence; no synthesis, network or product-tree edits."""
import argparse, hashlib, json, re, shutil, zipfile
from pathlib import Path
EXP = Path(__file__).resolve().parents[1]
FPGA = EXP.parents[1]
def read(p): return json.loads(p.read_text(encoding="utf-8-sig"))
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    ap=argparse.ArgumentParser();ap.add_argument("--run",required=True);a=ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+",a.run): ap.error("Invalid run identifier")
    out=EXP/"results"/a.run;out.mkdir()
    checks=[]
    def check(name,ok,**kw): checks.append(dict(name=name,passed=bool(ok),**kw))
    b=read(EXP/"results/baseline001/baseline_audit.json")
    heads={}
    for line in (EXP/"results/baseline001/remote_heads_recheck.txt").read_text(encoding="utf-8-sig").splitlines():
        commit,ref=line.split();heads[ref.removeprefix("refs/heads/")]=commit
    check("remote_heads_recheck",heads=={x["branch"]:x["commit"] for x in b["branches"]},heads=heads)
    for branch in b["branches"]:
        zpath=EXP/"results/baseline001"/(branch["branch"]+".zip")
        check("archive_hash_"+branch["branch"],sha(zpath)==branch["archive_sha256"])
        with zipfile.ZipFile(zpath) as z:
            relevant=[x for x in b["source_comparisons"] if x["branch"]==branch["branch"]]
            check("remote_source_hashes_"+branch["branch"],all(hashlib.sha256(z.read(x["path"])).hexdigest()==x["remote_sha256"] for x in relevant),records=len(relevant))
    dev=[x for x in b["source_comparisons"] if x["branch"]=="develop"]
    check("historical_develop_key_sources",len(dev)==12 and all(x["byte_identical"] for x in dev),scope="12 file/run records, not complete dependency closure")
    api=read(EXP/"results/baseline001/granite_model_api.json")
    spec=read(EXP/"cases/demo_spec.json");cfg=read(EXP/"results/baseline001/granite_config.json")
    check("model_revision",api["sha"]==spec["model"]["revision"])
    check("model_dimensions",all(cfg[k]==v for k,v in dict(num_hidden_layers=24,hidden_size=1024,intermediate_size=512,num_local_experts=32,num_experts_per_tok=8,num_attention_heads=16,num_key_value_heads=8,vocab_size=49152).items()))
    brain=read(EXP/"results/brain001/brain_results.json")
    check("brain_tests",brain["passed"] and len(brain["tests"])==10 and all(x["passed"] for x in brain["tests"]),test_count=len(brain["tests"]))
    check("brain_script_snapshot",sha(EXP/"scripts/braincheck.py")==sha(EXP/"results/brain001/braincheck.py"))
    cap=read(EXP/"results/brain001/capacity.json")
    d,f,L,E,k,V,h,kv=1024,512,24,32,8,49152,16,8
    matrix_per_layer=2*d*d+2*d*kv*(d//h)+E*3*d*f
    other=V*d+L*d*E+2*L*d+d
    check("independent_weight_arithmetic",cap["parameters"]==L*matrix_per_layer+other and cap["mixed_weight_bytes"]==L*matrix_per_layer*33//32+other*2)
    check("capacity_and_context",b["lpu16_mem_profile"]["capacity_bytes"]==2*52*2*2*1024*64//8==3407872 and cap["kv_cache_bytes"]["32"]==2*L*32*kv*(d//h)*2==1572864)
    gp=cap["mem_group_plan"]
    check("logical_group_budget",sum(gp[x] for x in ["kv_groups","weight_staging_groups","scratch_groups","reserve_groups"])==26 and gp["group_bytes"]*26==3407872,scope="Bytes only; no physical placement/ports/cycle proof")
    p=read(EXP/"results/projection002/resource_projection.json")
    check("known_partial_resource_sum",p["known_partial"]["LUT"]==104*4953+128*2888+256*1513==1272104)
    check("integer_budget_math",all(x["DSP_remaining_at_70pct"]==x["resources"]["DSP"]*7//10-512 and x["LUT_remaining_at_70pct"]==x["resources"]["LUT_ELEMENTS"]*7//10-1272104 for x in p["boards"]))
    check("projection_script_snapshot",sha(EXP/"scripts/project_resources.py")==sha(EXP/"results/projection002/project_resources.py"))
    log=(EXP/"results/parts001/vivado.log").read_text(errors="replace")
    check("vivado_part_probe_complete","PART_AUDIT_COMPLETE" in log and len(re.findall(r"^PATTERN=.*MATCH_COUNT=1$",log,re.M))==3)
    old=FPGA/"test/20261102_mapping_compare/results/analysis003"
    historical=read(old/"audit.json")
    check("historical_selected_13",historical["passed"] and historical["selected_count"]==13 and all(x["passed"] for x in historical["selected"]))
    # The root index was intentionally updated for this dated report; historical data are immutable.
    old_manifest=read(old/"artifact_manifest.json");mismatches=[];verified=0;excluded=[]
    for x in old_manifest:
        if x["path"]=="README.md":
            excluded.append(dict(path=x["path"],reason="Intentional root index update for 2026-11-04"))
            continue
        target=FPGA/x["path"]
        if not target.exists() or sha(target)!=x["sha256"]: mismatches.append(x["path"])
        else: verified+=1
    check("historical_artifact_hashes",not mismatches,verified=verified,excluded=excluded,mismatches=mismatches)
    report=FPGA/"docs/IP17_FPGA平台与MoE演示范围_20261104.md"
    docs=[report,EXP/"README.md",FPGA/"README.md"]
    broken=[]
    for doc in docs:
        content=doc.read_text(encoding="utf-8-sig")
        for link in re.findall(r"\]\(([^)]+)\)",content):
            if re.match(r"^[A-Za-z]:/",link) and not Path(link).exists() and Path(link)!=(out/"audit.json"): broken.append(dict(doc=str(doc),link=link))
    check("local_markdown_links",not broken,broken=broken)
    syntax=[]
    for script in (EXP/"scripts").glob("*.py"):
        compile(script.read_text(encoding="utf-8-sig"),str(script),"exec");syntax.append(script.name)
    check("python_syntax",True,scripts=syntax)
    check("source_archive_failure_explicit",read(EXP/"results/sources001/archive_status.json")["status"]=="archive_download_failed")
    result=dict(passed=all(x["passed"] for x in checks),date="2026-11-04",checks=checks,
        limitations=["No new whole-system synthesis, place/route, bitstream or board run","Independent synthetic model, not real trained-weight inference","Not a complete RTL dependency audit","No DDR/DMA/SRF cycle-level scheduling proof","Public source archival HTTP failure is explicitly recorded; browser-readable primary pages support board facts"])
    shutil.copy2(__file__,out/"audit.py")
    shutil.copy2(EXP/"scripts/baseline.py",out/"baseline_generator.py")
    shutil.copy2(EXP/"scripts/parts.tcl",out/"parts.tcl")
    (out/"audit.json").write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
    paths=sorted({*EXP.rglob("*"),report,FPGA/"README.md"})
    entries=[dict(path=x.relative_to(FPGA).as_posix(),bytes=x.stat().st_size,sha256=sha(x)) for x in paths if x.is_file() and x!=(out/"artifact_manifest.json")]
    (out/"artifact_manifest.json").write_text(json.dumps(entries,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps(result,ensure_ascii=False,indent=2))
    print("MANIFEST_FILES="+str(len(entries)))
    raise SystemExit(0 if result["passed"] else 1)
if __name__=="__main__":main()
