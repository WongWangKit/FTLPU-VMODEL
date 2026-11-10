"""Cycle/bit comparison: frozen pre-optimization writer vs fixed-index wiring.
Random 32-bit payload words, both formats, identity/reversed Tile map, all T.
This complements native MEM regression without rerunning the expensive FU chain.
"""
from pathlib import Path
import sys,json,hashlib,subprocess,os
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
old=E/'tmp/l5_queue02_adapter_t2_synth/src/lpu_sxm_triangle_mem_adapter.sv';new=R/'rtl/integration/lpu_sxm_triangle_mem_adapter.sv'
(tmp/'old.sv').write_text(old.read_text().replace('module lpu_sxm_triangle_mem_adapter','module writer_reference'))
(tmp/'new.sv').write_bytes(new.read_bytes())
outputs=[('','job_ready_o'),('[T-1:0]','block_ready_o'),('[T*32-1:0]','stream_valid_o'),('[T*2048-1:0]','stream_data_o'),('[31:0]','mem_issue_valid_o'),('[1023:0]','mem_issue_o'),('[4*T-1:0]','target_tap_o'),('[4*T*15-1:0]','target_address_o'),('','busy_o'),('','fault_o')]
inputs=['clk_i','rst_ni','job_valid_i','fp32_i','resources_ready_i','matrices_i','base_i','tile_map_i','block_valid_i','block_fp32_i','block_data_i','block_matrix_i','block_column_i']
tb='''`timescale 1ns/1ps
module pack_tb #(parameter integer T=4,localparam integer TW=$clog2(T));
 reg clk_i=0,rst_ni=0,job_valid_i=0,fp32_i=0,resources_ready_i=1;always #5 clk_i=~clk_i;
 reg [15:0] matrices_i=2;reg [14:0] base_i=16;reg [T*TW-1:0] tile_map_i=0;
 reg [T-1:0] block_valid_i=0,block_fp32_i=0;reg [T*2048-1:0] block_data_i /* verilator public_flat_rw */ =0;
 reg [T*16-1:0] block_matrix_i=0;reg [T*TW-1:0] block_column_i=0;
'''
for prefix,module in [('ref','writer_reference'),('dut','lpu_sxm_triangle_mem_adapter')]:
 tb+='\n'.join(f' wire {width} {prefix}_{name};' for width,name in outputs)+'\n'
 tb+=f' {module} #(.T(T),.DEPTH(1024)) {prefix}_inst('+','.join('.'+n for n in inputs)+','+','.join(f'.{n}({prefix}_{n})' for _,n in outputs)+');\n'
left='{'+','.join('ref_'+n for _,n in outputs)+'}';right='{'+','.join('dut_'+n for _,n in outputs)+'}'
tb+=''' integer FP=0,MAP=0,c,d,k,n,a,checks=0;reg [31:0] random_word=32'h16b913ed;
 initial begin
  if($value$plusargs("FP=%d",FP))begin end
  if($value$plusargs("MAP=%d",MAP))begin end
  fp32_i=(FP!=0);block_fp32_i={T{FP!=0}};
  for(d=0;d<T;d++)tile_map_i[d*TW+:TW]=TW'(MAP!=0?T-1-d:d);
  repeat(2)@(negedge clk_i);rst_ni=1;
  for(c=0;c<8*(3*T-2)+40;c++)begin
   job_valid_i=(c==0);block_valid_i=0;block_matrix_i=0;block_column_i=0;
   if(c>=9 && (c-9)%8==0)for(d=0;d<T;d++)begin
    k=(c-9)/8;a=MAP!=0?T-1-d:d;n=k-a;
    if(n>=0 && n<2*T)begin block_valid_i[d]=1;block_matrix_i[d*16+:16]=16'(n/T);block_column_i[d*TW+:TW]=TW'(n%T);end
   end
   for(integer w=0;w<T*64;w++)begin
    random_word=random_word^(random_word<<13);random_word=random_word^(random_word>>17);random_word=random_word^(random_word<<5);
    block_data_i[w*32+:32]=random_word;
   end
   #1;
'''
for _,name in outputs:
 tb+=f'   if(ref_{name}!==dut_{name})$fatal(1,"packing equivalence {name} C%0d",c);\n'
tb+='''   if(dut_fault_o)$fatal(1,"equivalence stimulus calendar");
   checks++;@(posedge clk_i);#1;@(negedge clk_i);
  end
  if(dut_busy_o)$fatal(1,"equivalence drain");
  $display("PASS PACK_EQ T=%0d FP=%0d MAP=%0d cycles=%0d",T,FP,MAP,checks);$finish;
 end
endmodule
'''
(tmp/'pack_tb.sv').write_text(tb)
(out/'manifest.json').write_text(json.dumps(dict(old=hashlib.sha256(old.read_bytes()).hexdigest(),new=hashlib.sha256(new.read_bytes()).hexdigest(),test=hashlib.sha256(tb.encode()).hexdigest()),indent=2))
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0');results=[]
for T in [2,4,8]:
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','pack_tb',f'-GT={T}','--Mdir',str(obj),*[str(tmp/f) for f in ['old.sv','new.sv','pack_tb.sv']]]
 with (out/f'build_t{T}.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit('equivalence build failed')
 for FP in [0,1]:
  for MAP in [0,1]:
   p=subprocess.run([str(obj/'Vpack_tb'),f'+FP={FP}',f'+MAP={MAP}'],capture_output=True,text=True);(out/f't{T}_fp{FP}_map{MAP}.log').write_text(p.stdout+p.stderr)
   results.append(dict(T=T,FP=FP,MAP=MAP,pass_=p.returncode==0 and 'PASS PACK_EQ' in p.stdout));print(p.stdout+p.stderr,flush=True)
   (out/'summary.json').write_text(json.dumps(results,indent=2))
   if not results[-1]['pass_']:raise SystemExit('packing equivalence failure')
