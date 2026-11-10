"""Native WriteTap shell admission boundaries, all three hardware profiles."""
from pathlib import Path
import sys,json,subprocess,os,hashlib
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
tb=r'''`timescale 1ns/1ps
module admission_tb #(parameter integer T=4);
 reg clk_i=0,rst_ni=0;always #5 clk_i=~clk_i;
 reg job_valid_i=0,fp32_i=1,resources_ready_i=1;
 reg [15:0] matrices_i=1;reg [14:0] base_i=16;
 reg [T*$clog2(T)-1:0] tile_map_i=0;
 wire ready,busy,fault,start;wire [31:0] mi,count;wire [T*2048-1:0] data_zero;
 for(genvar z=0;z<T*32;z++)assign data_zero[z*64+:64]=0;
 lpu_sxm_writetap_shell #(.T(T),.DEPTH(1024)) dut(
 .clk_i,.rst_ni,.job_valid_i,.fp32_i,.resources_ready_i,.matrices_i,.base_i,.tile_map_i,.job_ready_o(ready),
 .block_valid_i('0),.block_fp32_i('0),.block_data_i(data_zero),.block_matrix_i('0),.block_column_i('0),.block_ready_o(),
 .stream_valid_o(),.stream_data_o(),.mem_issue_valid_o(mi),.mem_issue_o(),.target_tap_o(),.target_address_o(),.busy_o(busy),.fault_o(fault),
 .core_ready_i(1'b1),.core_busy_i(1'b0),.core_fault_i(1'b0),.mem_busy_i('0),.mem_fault_i('0),.transport_fault_i(1'b0),
 .read_issue_valid_i('0),.tap_data_valid_i('0),.start_o(start),.tap_sample_o(),.committed_segments_o(count),.done_o());
 task automatic check(input bit want);
   #1;if(ready!==want || fault || busy || |mi || count!=0)$fatal(1,"admission count%0d base%0d",matrices_i,base_i);
 endtask
 initial begin
  for(integer t=0;t<T;t++)tile_map_i[t*$clog2(T)+:$clog2(T)]=$clog2(T)'(t);
  repeat(2)@(negedge clk_i);rst_ni=1;check(1);
  matrices_i=0;check(0);matrices_i=65535;check(0);
  matrices_i=16'((1024-16)/T);check(1);matrices_i=matrices_i+1;check(0);
  matrices_i=1;base_i=1023;check(0);base_i=1024;check(0);
  base_i=32767;matrices_i=65535;check(0);base_i=16;matrices_i=1;
  resources_ready_i=0;check(0);resources_ready_i=1;tile_map_i=0;check(0);
  for(integer t=0;t<T;t++)tile_map_i[t*$clog2(T)+:$clog2(T)]=$clog2(T)'(t);
  matrices_i=16'((1024-16)/T);check(1);job_valid_i=1;#1;if(!start)$fatal(1,"maximum legal batch not admitted");
  @(posedge clk_i);#1;if(!busy || fault || count!=0)$fatal(1,"admitted job state");
  @(negedge clk_i);job_valid_i=0;rst_ni=0;@(posedge clk_i);#1;
  if(busy || fault || count!=0)$fatal(1,"reset valid leak");
  $display("PASS ADMISSION T=%0d probes=12 shell_payload_bits=0",T);$finish;
 end
endmodule
'''
src=[]
for n in ['lpu_sxm_triangle_mem_adapter','lpu_sxm_writetap_completion','lpu_sxm_writetap_shell']:
 p=R/f'rtl/integration/{n}.sv';q=tmp/p.name;q.write_bytes(p.read_bytes());src.append(q)
p=tmp/'admission_tb.sv';p.write_text(tb);src.append(p)
(out/'manifest.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in src},indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0');results=[]
for T in [2,4,8]:
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','--top-module','admission_tb',f'-GT={T}','--Mdir',str(obj),*[str(p) for p in src]]
 with (out/f'build_t{T}.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit('admission build failed')
 p=subprocess.run([str(obj/'Vadmission_tb')],capture_output=True,text=True);(out/f't{T}.log').write_text(p.stdout+p.stderr)
 results.append(dict(T=T,pass_=p.returncode==0 and 'PASS ADMISSION' in p.stdout));print(p.stdout+p.stderr,flush=True)
 (out/'summary.json').write_text(json.dumps(results,indent=2))
 if not results[-1]['pass_']:raise SystemExit('admission failure')
