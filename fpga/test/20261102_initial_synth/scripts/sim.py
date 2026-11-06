"""Run the same pin-level self-checking bench on RTL and post-synthesis netlists."""
import argparse
import json
import hashlib
import shutil
from pathlib import Path
from run import EXPERIMENT, FPGA, VIVADO, execute

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--synth-run',required=True)
    ap.add_argument('--run',required=True)
    ap.add_argument('--cases',nargs='+',default=['mem_leaf','alu_basic'])
    ap.add_argument('--modes',nargs='+',choices=['rtl','gate'],default=['rtl','gate'])
    a=ap.parse_args()
    for name in [a.run,a.synth_run]:
        if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in name):
            ap.error('invalid run name')
    out=EXPERIMENT/'results'/a.run
    work=FPGA/'tmp'/a.run
    out.mkdir(parents=True);work.mkdir(parents=True)
    src=FPGA/'tmp'/a.synth_run/'src'
    records=[]
    for case in a.cases:
      for mode in a.modes:
        wd=work/f'{case}_{mode}';wd.mkdir()
        od=out/f'{case}_{mode}';od.mkdir()
        bench='mem_leaf' if case=='mem_leaf_bram' else ('alu_basic' if case=='alu_basic_pruned' else case)
        tb=EXPERIMENT/'tb'/f'{bench}_tb.sv'
        shutil.copy2(tb,od/tb.name)
        (od/'testbench_sha256.txt').write_text(hashlib.sha256(tb.read_bytes()).hexdigest())
        netlist=EXPERIMENT/'results'/a.synth_run/case/'netlist.v'
        if mode=='gate':
            files=[netlist,tb,VIVADO.parent/'data/verilog/src/glbl.v']
        elif case=='mem_leaf':
            files=[src/'rtl/mem_native/mem_bank_superlane_leaf.sv',tb]
        elif case=='mem_leaf_bram':
            files=[src/'fpga_experiment/rtl/mem_leaf_bram.sv',tb]
        elif case=='srf_leaf':
            files=[src/'rtl/srf/ftlpu_sr_superlane_col_dir.sv',tb]
        else:
            lines=(src/'sim/filelist.f').read_text().splitlines()
            lines=lines[:lines.index('rtl/vxm/lpu_vxm_alu.sv')+1]
            files=[src/x.strip() for x in lines if x.startswith('rtl/')]+[tb]
            if case in ['alu_basic_pruned','alu_basic_bf16']: files.insert(-1,src/'fpga_experiment/rtl/basic_alu_probe.sv')
        steps=[]
        cmd=[str(VIVADO/'xvlog.bat'),'--sv']+(['-d','GATE'] if mode=='gate' else [])+(['-d','PRUNED'] if case=='alu_basic_pruned' else [])+[p.as_posix() for p in files]
        steps.append(execute(cmd,wd,od/'compile.log',180))
        if steps[-1]['returncode']==0:
          cmd=[str(VIVADO/'xelab.bat'),bench+'_tb']+(['glbl','-L','unisims_ver'] if mode=='gate' else [])+['-s','snapshot','--debug','typical','--timescale','1ns/1ps','--mt','4']
          steps.append(execute(cmd,wd,od/'elaborate.log',240))
        if steps[-1]['returncode']==0:
          steps.append(execute([str(VIVADO/'xsim.bat'),'snapshot','-runall'],wd,od/'simulate.log',240))
        log=(od/'simulate.log').read_text(errors='replace') if (od/'simulate.log').exists() else ''
        passed=len(steps)==3 and all(s['returncode']==0 for s in steps) and f'PASS {bench}' in log and 'Fatal:' not in log and 'ERROR:' not in log
        record={'case':case,'mode':mode,'passed':passed,'steps':steps}
        records.append(record)
        (out/'summary.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
        print(case,mode,'PASS' if passed else 'FAIL',flush=True)

if __name__=='__main__':main()
