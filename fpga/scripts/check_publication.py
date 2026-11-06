"""Read-only Git publication preflight. Never stage, commit, switch or push."""
import collections, hashlib, json, re, subprocess, zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def git(*args):
    return subprocess.check_output(["git","-C",str(ROOT),*args]).decode("utf-8")
def paths(*args): return [p for p in git(args[0],"-z",*args[1:]).split("\0") if p]
def main():
    selected=sorted(set(paths("ls-files","--cached","--","fpga")+paths("ls-files","--others","--exclude-standard","--","fpga")))
    errors=[]; manifest=[]; counts=collections.Counter(); archives=[]
    for rel in selected:
        p=ROOT/rel
        if not p.is_file(): errors.append("Missing file: "+rel);continue
        raw=p.read_bytes();parts=Path(rel).parts
        if any(x in parts for x in ["tmp","__pycache__",".git","node_modules","xsim.dir",".Xil"]) or p.suffix.lower() in [".dcp",".exe",".dll",".wdb",".vcd",".pyc"] or p.name=="netlist.v":
            errors.append("Excluded artifact selected: "+rel)
        if len(raw)>=50*1024**2: errors.append("Large file >=50 MiB: "+rel)
        if re.search(rb"(?m)^[ \t]*-----BEGIN (?:RSA )?PRIVATE KEY-----\r?$", raw):
            errors.append("Private-key marker: "+rel)
        category="metadata"
        if rel.startswith("fpga/docs/"): category="reports"
        elif "/results/" in rel: category="evidence"
        elif rel.startswith("fpga/test/"): category="tests"
        counts[category]+=1
        manifest.append(dict(path=rel,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),category=category))
        if p.suffix==".zip":
            with zipfile.ZipFile(p) as z:
                names=z.namelist()
                if any(n.startswith(("/", "\\")) or ".." in Path(n).parts or ".git" in Path(n).parts for n in names):
                    errors.append("Unsafe/nested Git archive: "+rel)
                archives.append(dict(path=rel,entries=len(names)))
    staged=paths("diff","--cached","--name-only")
    unrelated=[p for p in staged if p!=".gitignore" and not p.startswith("fpga/")]
    if unrelated: errors.append("Unrelated staged paths: "+", ".join(unrelated))
    required=[
      "fpga/docs/IP17_FPGA平台与MoE演示范围_20261104.md",
      "fpga/test/20261102_mapping_compare/results/analysis003/audit.json",
      "fpga/test/20261102_mapping_compare/results/analysis003/frozen_sources.zip",
      "fpga/test/20261104_ip17_decision/results/brain001/brain_results.json"]
    for p in required:
        if p not in selected: errors.append("Required evidence missing: "+p)
    rpt=sum(p.endswith(".rpt") for p in selected);logs=sum(p.endswith(".log") for p in selected)
    if not rpt or not logs: errors.append("Reports/logs still ignored")
    # Hashes in historical manifests cover local-only DCP/netlists as well.
    # Verify published files without rewriting old manifests or claims.
    old=ROOT/"fpga/test/20261102_mapping_compare/results/analysis003/artifact_manifest.json"
    verified=0;omitted=0;changed=[]
    for x in json.loads(old.read_text(encoding="utf-8-sig")):
        rel="fpga/"+x["path"]
        if rel=="fpga/README.md": continue # intentional index update
        if rel not in selected: omitted+=1;continue
        if hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()!=x["sha256"]:changed.append(rel)
        else: verified+=1
    if changed: errors.append("Historical published bytes changed: "+", ".join(changed))
    result=dict(passed=not errors,branch=git("branch","--show-current").strip(),head=git("rev-parse","HEAD").strip(),
      file_count=len(manifest),total_bytes=sum(x["bytes"] for x in manifest),categories=dict(counts),rpt_count=rpt,log_count=logs,
      zip_archives=archives,historical_published_hashes_verified=verified,historical_local_only_omitted=omitted,
      errors=errors,staged_paths=staged,
      caveats=["No comprehensive secret scan; retained logs may contain local paths and host/tool information",
               "Historical full-run audits require locally omitted checkpoints/netlists and original paths",
               "Counts exclude the root .gitignore; no index or remote mutation performed"])
    out=ROOT/"fpga/tmp/publish_20261106";out.mkdir(parents=True,exist_ok=True)
    (out/"audit.json").write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
    (out/"manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps(result,ensure_ascii=False,indent=2))
    raise SystemExit(0 if result["passed"] else 1)
if __name__=="__main__":main()
