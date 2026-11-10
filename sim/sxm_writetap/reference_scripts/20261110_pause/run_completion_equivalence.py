"""Unchanged-edge check of balanced vs serial Tap counting, including faults.
Uses the frozen linear reference; no production registers or latency added.
"""
from pathlib import Path
import sys,json,hashlib,subprocess,os
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
old=E/'tmp/before/completion_linear.sv';new=R/'rtl/integration/lpu_sxm_writetap_completion.sv'
(tmp/'old.sv').write_text(old.read_text().replace('module lpu_sxm_writetap_completion','module completion_reference'))
(tmp/'new.sv').write_bytes(new.read_bytes())
inputs='clk_i rst_ni job_valid_i fp32_i matrices_i core_ready writer_ready core_busy writer_busy core_fault writer_fault mem_busy mem_fault transport_fault read_issue_valid_i wi wc target target_addr tap_data_valid_i'.split()
outputs=[('',n) for n in 'job_ready_o start busy_o fault_o pending_q bad_q monitor_bad done_o'.split()]+[('[32*T-1:0]','tap_sample_o'),('[31:0]','committed_segments_o')]
tb='''`timescale 1ns/1ps
module count_tb #(parameter integer T=4);
 reg clk_i=0,rst_ni=0,job_valid_i=0,fp32_i=0;always #5 clk_i=~clk_i;
 reg [15:0] matrices_i=2;
 reg core_ready=1,writer_ready=1,core_busy=1,writer_busy=0,core_fault=0,writer_fault=0,transport_fault=0;
 reg [3:0] mem_busy=0,mem_fault=0;reg [31:0] read_issue_valid_i=0,wi=0;
 reg [1023:0] wc=0;reg [4*T-1:0] target=0;reg [4*T*15-1:0] target_addr=0;
 reg [32*T-1:0] tap_data_valid_i=0;
'''
for prefix,module in [('ref','completion_reference'),('dut','lpu_sxm_writetap_completion')]:
 tb+='\n'.join(f' wire {width} {prefix}_{name};' for width,name in outputs)+'\n'
 tb+=f' {module} #(.T(T),.DEPTH(1024)) {prefix}_inst('+','.join('.'+n for n in inputs)+','+','.join(f'.{n}({prefix}_{n})' for _,n in outputs)+');\n'
tb+=''' integer c,g,w,checks=0;reg [31:0] seed=32'h91f3a706;
 task check_outputs;begin
'''
for _,n in outputs:
 tb+=f' if(ref_{n}!==dut_{n})$fatal(1,"count equivalence {n} C%0d",c);\n'
tb+=''' checks++;end endtask
 initial begin
  repeat(2)@(negedge clk_i);
  for(c=0;c<2048;c++)begin
   rst_ni=(c%256!=0);job_valid_i=(c%256==1);fp32_i=(c/256)%2!=0;
   for(w=0;w<T;w++)begin
    seed=seed^(seed<<13);seed=seed^(seed>>17);seed=seed^(seed<<5);
    tap_data_valid_i[w*32+:32]=(c%64<8)?32'hffffffff:seed;
   end
   wi=(c%64<16)?32'hffffffff:seed;
   for(g=0;g<32;g++)wc[g*32+:32]=32'h80000101 | (32'(g)<<3) | ((seed&1023)<<15);
   // Target/address mismatches intentionally exercise the sticky-fault path.
   target=(c%17==0)?{(4*T){1'b1}}:0;target_addr=0;
   read_issue_valid_i=(c%101==0)?32'h1:0;
   #1;check_outputs();@(posedge clk_i);#1;check_outputs();@(negedge clk_i);
  end
  if(dut_committed_segments_o==0)$fatal(1,"no counting exercised");
  $display("PASS COUNT_EQ T=%0d checks=%0d final_segments=%0d",T,checks,dut_committed_segments_o);$finish;
 end
endmodule
'''
(tmp/'count_tb.sv').write_text(tb)
(out/'manifest.json').write_text(json.dumps(dict(old=hashlib.sha256(old.read_bytes()).hexdigest(),new=hashlib.sha256(new.read_bytes()).hexdigest(),test=hashlib.sha256(tb.encode()).hexdigest(),cycles=2048),indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0');results=[]
for T in [2,4,8]:
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','--public-flat-rw','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','count_tb',f'-GT={T}','--Mdir',str(obj),*[str(tmp/f) for f in ['old.sv','new.sv','count_tb.sv']]]
 with (out/f'build_t{T}.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit('count equivalence build failed')
 p=subprocess.run([str(obj/'Vcount_tb')],capture_output=True,text=True);(out/f't{T}.log').write_text(p.stdout+p.stderr)
 results.append(dict(T=T,pass_=p.returncode==0 and 'PASS COUNT_EQ' in p.stdout));print(p.stdout+p.stderr,flush=True)
 (out/'summary.json').write_text(json.dumps(results,indent=2))
 if not results[-1]['pass_']:raise SystemExit('count equivalence failure')
