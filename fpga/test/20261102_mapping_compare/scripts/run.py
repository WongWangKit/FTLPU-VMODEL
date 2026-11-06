"""Source-frozen equal-function resource mapping comparisons, confined to fpga/."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

EXP = Path(__file__).resolve().parents[1]
FPGA = EXP.parents[1]
REPO = FPGA.parent
VIVADO = Path(os.environ.get('VIVADO_BIN', 'C:/Users/huazh/Desktop/Vivado2023/Vivado/2023.2/bin'))

def execute(cmd, cwd, log, timeout):
    start = time.monotonic()
    with log.open('w', encoding='utf-8') as f:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
        minimum_free=float(os.environ.get('FPGA_MIN_FREE_GB','0'))*1e9
        if minimum_free:
            import psutil
        while True:
            try:
                rc=p.wait(timeout=min(2,max(0.1,timeout-(time.monotonic()-start))))
                status='completed' if rc==0 else 'failed'
                break
            except subprocess.TimeoutExpired:
                expired=time.monotonic()-start>=timeout
                exhausted=minimum_free and psutil.virtual_memory().available<minimum_free
                if expired or exhausted:
                    subprocess.run(['taskkill','/PID',str(p.pid),'/T','/F'],stdout=f,stderr=f)
                    p.wait()
                    rc,status=None,('host_memory_limit' if exhausted else 'timeout')
                    f.write('\nBOUNDED_STOP '+status+'\n')
                    break
    return dict(command=cmd, returncode=rc, status=status, elapsed_s=round(time.monotonic()-start, 1))

def definition(case, src):
    r=lambda p: src/'rtl'/p
    e=lambda p: src/'experiment'/p
    cfg=dict(case=case, generics=[], defines=[], clocked=True, top='', files=[], tb='', tb_defines=[], sim_files=[])
    if case.startswith('mem_'):
        cfg.update(top='mem_bank_superlane_leaf', files=[e('rtl/mem_leaf_'+case.split('_')[1]+'.sv')],
                   generics=['P_MEM_BANK_DEPTH_ROWS=1024','P_MEM_ACTIVE_ROWS=1024'], tb='mem_leaf')
    elif case.startswith('srf_'):
        cfg.update(top='ftlpu_sr_superlane_col_dir_lane', tb='srf_leaf',
                   files=[r('srf/ftlpu_sr_superlane_col_dir.sv') if case=='srf_default' else e('rtl/srf_onehot.sv')])
    elif case.startswith('alu_'):
        lines=(src/'filelist.f').read_text().splitlines()
        lines=lines[:lines.index('rtl/vxm/lpu_vxm_alu.sv')+1]
        files=[src/x for x in lines if x.startswith('rtl/')]
        if case=='alu_dsp':
            files=[e('rtl/mul8x8_dsp.sv') if p.name=='lpu_vxm_mul8x8.sv' else p for p in files]
        if case=='alu_wide_dsp':
            files=[e('rtl/significand_wide_dsp.sv') if p.name=='lpu_vxm_significand_multiplier.sv' else p for p in files]
        cfg.update(top='fpga_basic_alu_probe', files=files+[e('rtl/basic_alu_probe.sv')],
                   generics=['FIXED_BF16=0'], tb='alu_basic', tb_defines=['PRUNED'])
    elif case.startswith('mxm_'):
        kind=case.removeprefix('mxm_')
        dsp=kind.endswith('_dsp')
        pkg=e('rtl/math_dsp_pkg.sv') if dsp else r('vxm/lpu_vxm_math_pkg.sv')
        if kind.startswith('dot_'):
            cfg.update(top='lpu_mxm_dot_bank', files=[pkg,r('mxm/lpu_mxm_dot_bank.sv')], tb='mxm_dot')
        elif kind.startswith('column_'):
            cfg.update(top='fpga_mxm_column', files=[pkg,e('rtl/mxm_column.sv')], tb='mxm_column')
        elif kind.startswith('mul_'):
            cfg.update(top='fpga_mxm_mul', files=[pkg,e('rtl/mxm_mul.sv')], tb='mxm_mul')
        elif kind.startswith('compute_'):
            cfg.update(top='lpu_mxm_compute', files=[r('core/lpu_pkg.sv'),pkg,r('mxm/lpu_mxm_dot_bank.sv'),r('mxm/lpu_mxm_compute.sv')],
                       generics=['ACCUMULATOR_BLOCK_COUNT=1'], defines=['FTLPU_DISABLE_BLOCK8'], clocked=True,tb='mxm_compute')
        else: raise ValueError(case)
        if not kind.startswith('compute_'): cfg['clocked']=False
        if 'narrow' in kind or 'compact' in kind:
            if kind.startswith('mul_'):
                cfg['files']=[r('vxm/lpu_vxm_math_pkg.sv'),e('rtl/mxm_mul_narrow.sv')]
            elif kind.startswith('column_'):
                cfg['files']=[r('vxm/lpu_vxm_math_pkg.sv'),e('rtl/mxm_mul_narrow.sv'),e('rtl/mxm_column_narrow.sv')]
            elif kind.startswith('dot_'):
                cfg['files']=[r('vxm/lpu_vxm_math_pkg.sv'),e('rtl/mxm_mul_narrow.sv'),e('rtl/mxm_column_narrow.sv'),e('rtl/mxm_dot_narrow.sv')]
            elif kind.startswith('compute_'):
                cfg['files']=[r('core/lpu_pkg.sv'),r('vxm/lpu_vxm_math_pkg.sv'),e('rtl/mxm_mul_narrow.sv'),e('rtl/mxm_column_narrow.sv'),e('rtl/mxm_dot_narrow.sv'),r('mxm/lpu_mxm_compute.sv')]
            if 'compact' in kind:
                cfg['files']=[e('rtl/math_mxm_compact_pkg.sv') if p.name=='lpu_vxm_math_pkg.sv' else p for p in cfg['files']]
        if cfg['tb']:
            cfg['sim_files']=[e('rtl/math_reference_pkg.sv')]
    else: raise ValueError(case)
    return cfg

def tcl_for(cfg, out, src, period, part):
    q=lambda x:'{'+str(x).replace('\\','/')+'}'
    f='\n'.join('read_verilog -sv '+q(p) for p in cfg['files'])
    defines='set_property verilog_define {'+' '.join(cfg['defines'])+'} [current_fileset]' if cfg['defines'] else ''
    generics=' -generic {'+' '.join(cfg['generics'])+'}' if cfg['generics'] else ''
    timing_mode=' -no_timing_driven' if cfg.get('no_timing_driven') else ''
    return f'''set_param general.maxThreads 1
create_project -in_memory -part {part}
{defines}
{f}
read_xdc {q(out/'timing.xdc')}
synth_design -top {cfg['top']} -part {part} -mode out_of_context -flatten_hierarchy rebuilt{generics}{timing_mode}
report_utilization -file {q(out/'utilization.rpt')}
report_utilization -hierarchical -file {q(out/'utilization_hier.rpt')}
write_checkpoint -force [file join {q(out)} synthesized.dcp]
write_verilog -force -mode funcsim [file join {q(out)} netlist.v]
set fd [open {q(out/'primitives.txt')} w]
foreach pattern {{LUT* FD* RAMB18E2 RAMB36E2 URAM288 DSP48E2 SRL* MUXF* CARRY* LD*}} {{
  set selector [format {{REF_NAME =~ %s}} $pattern]
  puts $fd "$pattern=[llength [get_cells -hier -quiet -filter $selector]]"
}}
puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {{IS_BLACKBOX == 1}}]]"
close $fd
report_timing_summary -max_paths 3 -report_unconstrained -file {q(out/'timing_summary.rpt')}
report_drc -file {q(out/'drc.rpt')}
puts "MAPPING_COMPLETED {cfg['case']}"
exit
'''

def simulate(cfg, src, out, work, tb_override=None, modes=('rtl','gate')):
    records=[]
    for mode in modes:
        od=out/mode;od.mkdir()
        wd=work/mode;wd.mkdir()
        tb=tb_override or src/'experiment/tb'/f"{cfg['tb']}_tb.sv"
        defs=cfg['defines']+cfg['tb_defines']+(['GATE'] if mode=='gate' else [])
        files=([out/'netlist.v',VIVADO.parent/'data/verilog/src/glbl.v'] if mode=='gate' else cfg['files'])+cfg['sim_files']+[tb]
        args=[str(VIVADO/'xvlog.bat'),'--sv']
        for d in defs:args+=['-d',d]
        steps=[execute(args+[p.as_posix() for p in files],wd,od/'compile.log',240)]
        if steps[-1]['returncode']==0:
            args=[str(VIVADO/'xelab.bat'),cfg['tb']+'_tb']+(['glbl','-L','unisims_ver'] if mode=='gate' else [])+['-s','snapshot','--timescale','1ns/1ps','--mt','2']
            steps.append(execute(args,wd,od/'elaborate.log',300))
        if steps[-1]['returncode']==0:
            steps.append(execute([str(VIVADO/'xsim.bat'),'snapshot','-runall'],wd,od/'simulate.log',300))
        log=(od/'simulate.log').read_text(errors='replace') if (od/'simulate.log').exists() else ''
        passed=len(steps)==3 and all(s['returncode']==0 for s in steps) and 'PASS '+cfg['tb'] in log and 'Fatal:' not in log and 'ERROR:' not in log
        records.append(dict(mode=mode,passed=passed,steps=steps))
        (out/'simulation.json').write_text(json.dumps(records,indent=2))
        print(cfg['case'],mode,'PASS' if passed else 'FAIL',flush=True)
    return records

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--run',required=True)
    ap.add_argument('--cases',nargs='+',required=True)
    ap.add_argument('--timeout',type=int,default=900)
    ap.add_argument('--period',type=float,default=10.0)
    ap.add_argument('--part',default='xcvu9p-flga2104-2L-e')
    ap.add_argument('--simulate',action='store_true')
    ap.add_argument('--no-timing-driven',action='store_true')
    ap.add_argument('--rtl-only',action='store_true')
    a=ap.parse_args()
    for n in [a.run]+a.cases:
        if not n or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in n):ap.error('names must be single directory components')
    out=EXP/'results'/a.run;work=FPGA/'tmp'/('mapping_'+a.run)
    out.mkdir();work.mkdir();src=work/'src';src.mkdir()
    shutil.copytree(REPO/'rtl',src/'rtl')
    shutil.copy2(REPO/'sim/filelist.f',src/'filelist.f')
    for d in ['scripts','rtl','tb']:
        shutil.copytree(EXP/d,src/'experiment'/d,ignore=shutil.ignore_patterns('__pycache__'))
    manifest=[dict(path=p.relative_to(src).as_posix(),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(src.rglob('*')) if p.is_file()]
    (out/'source_manifest.json').write_text(json.dumps(manifest,indent=2))
    git=['git','-c','safe.directory='+REPO.as_posix(),'-C',str(REPO)]
    baseline=subprocess.run(git+['rev-parse','HEAD'],capture_output=True,text=True).stdout+subprocess.run(git+['status','--short'],capture_output=True,text=True).stdout
    (out/'baseline.txt').write_text(baseline,encoding='utf-8')
    records=[]
    for case in a.cases:
        cfg=definition(case,src);od=out/case;wd=work/case;od.mkdir();wd.mkdir()
        cfg['no_timing_driven']=a.no_timing_driven
        serial={k:([str(x) for x in v] if isinstance(v,list) else v) for k,v in cfg.items()}
        (od/'configuration.json').write_text(json.dumps(dict(**serial,part=a.part,period_ns=a.period),indent=2))
        if a.rtl_only:
            sims=simulate(cfg,src,od,wd,modes=('rtl',))
            records.append(dict(case=case,status='rtl_only',complete=False,simulation=sims))
            (out/'summary.json').write_text(json.dumps(records,indent=2))
            continue
        xdc=f'create_clock -period {a.period} -name clk'+(' [get_ports clk_i]' if cfg['clocked'] else '')+'\n'
        # Managed XDC accepts only a Tcl subset, not for/lrange control flow.
        xdc+='set_input_delay 1.0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]\n'
        xdc+='set_output_delay 1.0 -clock clk [all_outputs]\n'
        if cfg['clocked']:xdc+='set_false_path -from [get_ports -quiet rst_ni]\n'
        (od/'timing.xdc').write_text(xdc)
        script=od/'synth.tcl';script.write_text(tcl_for(cfg,od,src,a.period,a.part))
        cmd=[str(VIVADO/'vivado.bat'),'-mode','batch','-source',script.as_posix(),'-log',(od/'vivado.log').as_posix(),'-journal',(wd/'vivado.jou').as_posix()]
        print('START',case,flush=True)
        record=execute(cmd,wd,od/'console.log',a.timeout)
        log=(od/'console.log').read_text(errors='replace')
        complete=record['returncode']==0 and 'MAPPING_COMPLETED '+case in log
        record.update(case=case,complete=complete)
        if a.simulate and complete and cfg['tb']:record['simulation']=simulate(cfg,src,od,wd)
        records.append(record);(out/'summary.json').write_text(json.dumps(records,indent=2))
        print(case,record['status'],'complete='+str(complete),flush=True)
        if record['status']=='host_memory_limit':break
    raise SystemExit(0 if all((r['complete'] or a.rtl_only) and all(s['passed'] for s in r.get('simulation',[])) for r in records) else 1)

if __name__=='__main__':main()
