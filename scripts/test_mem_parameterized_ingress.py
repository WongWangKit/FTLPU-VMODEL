"""Test raw parameterized commands through the existing adapter and MEM/SRF.

The original c7 codec is retained as an explicit compatibility ABI; old golden
vectors are not rewritten to model the new delay3 bit.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
BASELINE='8bcf3807dd4987aac3e25853b92c7e7d6757062f'
CORE=[f'rtl/mem_native/{name}.sv' for name in (
    'mem_bank_superlane_leaf','mem_bank_control_column','mem_logical_bank_column',
    'mem_slice','mem_group','mem_hemisphere','mem_c7_primitive_adapter')]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,default=ROOT/'build/mem_parameterized_ingress')
    p.add_argument('--iverilog');p.add_argument('--vvp')
    args=p.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    def tool(name,explicit):
        found=explicit or shutil.which(name)
        if found:return found
        for suffix in ('.exe',''):
            path=ROOT/'build/iverilog/bin'/(name+suffix)
            if path.is_file():return str(path)
        raise RuntimeError(name+' not found')
    iv=tool('iverilog',args.iverilog);vvp=tool('vvp',args.vvp)
    old=subprocess.run(['git','show',BASELINE+':rtl/mem_native/mem_c7_primitive_adapter.sv'],cwd=ROOT,capture_output=True,check=True).stdout.decode()
    old_path=out/'mem_c7_primitive_adapter_before.sv'
    old_path.write_text(old.replace('module mem_c7_primitive_adapter #(','module mem_c7_primitive_adapter_before #('),encoding='utf-8')
    results=[];identities={}
    def run(name,top,sources,params=None):
        resolved=[str(ROOT/source) if not Path(source).is_absolute() else str(source) for source in sources]
        for source in resolved:identities[source]=hashlib.sha256(Path(source).read_bytes()).hexdigest()
        exe=out/(name+'.vvp')
        command=[iv,'-g2012','-s',top,'-o',str(exe)]+[f'-P{top}.{k}={v}' for k,v in (params or {}).items()]+resolved
        for stage,argv in [('compile',command),('run',[vvp,str(exe)])]:
            done=subprocess.run(argv,cwd=ROOT,capture_output=True,text=True,timeout=600)
            text=done.stdout+done.stderr
            (out/(name+'_'+stage+'.log')).write_text(subprocess.list2cmdline(argv)+'\n'+text,encoding='utf-8')
            if done.returncode or (stage=='run' and 'TEST_PASS' not in text):
                raise RuntimeError(name+' '+stage+' failed: '+text[-2500:])
        results.append(dict(name=name,passed=True,summary=[s for s in text.splitlines() if 'TEST_PASS' in s]))
        (out/'results.json').write_text(json.dumps(dict(results=results,source_sha256=identities),indent=2)+'\n',encoding='utf-8')
        print(name,'PASS',flush=True)
    for depth,active in [(1024,1024),(2048,2048),(2048,32),(32768,32768)]:
        run(f'codec_p{depth}_e{active}','mem_parameterized_codec_tb',
            ['rtl/mem_native/mem_c7_primitive_adapter.sv',old_path,'sim/mem_timing/mem_parameterized_codec_tb.sv'],
            dict(DEPTH=depth,ACTIVE=active))
    for rows,depth in [(2,1024),(4,2048),(8,2048)]:
        run(f'raw_mem_rows{rows}_p{depth}','mem_timing_tb',CORE+['sim/mem_timing/mem_timing_tb.sv'],
            dict(ROWS=rows,PHYSICAL_ROWS=depth,RAW_INGRESS=1))
    run('native_mem_regression','mem_timing_tb',CORE+['sim/mem_timing/mem_timing_tb.sv'])
    sources=[s.strip() for s in (ROOT/'sim/filelist_mem_srf.f').read_text().splitlines()
             if s.strip() and '_bind.sv' not in s and s.strip()!='sim/tb/lpu_mem_srf_tb.sv']
    sources+=['rtl/mem_native/mem_c7_primitive_adapter.sv','sim/mem_timing/mem_srf_timing_tb.sv']
    run('raw_mem_srf_rows4_p2048','mem_srf_timing_tb',sources,dict(ROWS=4,PHYSICAL_ROWS=2048,RAW_INGRESS=1))
    report=dict(passed=True,cases=len(results),results=results,source_sha256=identities,
                baseline_ref=BASELINE,scope='Parameterized raw32 -> existing adapter -> MEM, and default four-row MEM/SRF integration',
                frozen_c7_abi='P_ALLOW_DELAY3=0; original golden vectors unchanged')
    (out/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('MEM_PARAMETERIZED_INGRESS_SUITE PASS cases='+str(len(results)),flush=True)


if __name__=='__main__':main()
