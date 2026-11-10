"""Typed -> legacy/ROW/legacy -> typed without reset, same physical pool."""
from pathlib import Path
import subprocess,os,json,hashlib,sys
E=Path(__file__).resolve().parents[1];ROOT=E.parents[1];R=ROOT/'lpu_src/FTLPU-VMODEL'
out=E/'results'/sys.argv[1];out.mkdir(exist_ok=False);tmp=E/'tmp'/sys.argv[1];tmp.mkdir(parents=True,exist_ok=False)
tb=(E/'tmp/full03/sxm_compatible_core_tb.sv').read_text()
ports={".batch_job_i(1'b0)":'.batch_job_i(bjob)',".batch_dtype_i(2'b0)":'.batch_dtype_i(bdtype)',".batch_count_i(16'b0)":".batch_count_i(16'd2)",".batch_lane_map_i('0)":'.batch_lane_map_i(blane)',".batch_tile_map_i('0)":'.batch_tile_map_i(btile)','.batch_ready_o()':'.batch_ready_o(bready)','.batch_fault_o()':'.batch_fault_o(bfault)',".batch_cap_valid_i('0)":'.batch_cap_valid_i(bcap)',".batch_lane_valid_i('0)":".batch_lane_valid_i({T*8{1'b1}})",'.batch_cap_data_i(batch_zero)':'.batch_cap_data_i(bdata)','.batch_cap_accept_o()':'.batch_cap_accept_o(baccept)',".batch_block_ready_i('0)":".batch_block_ready_i({T{1'b1}})",'.batch_block_valid_o()':'.batch_block_valid_o(bvalid)','.batch_block_data_o()':'.batch_block_data_o(bout)','.batch_block_matrix_o()':'.batch_block_matrix_o(bmatrix)','.batch_block_column_o()':'.batch_block_column_o(bcolumn)'}
for a,b in ports.items():assert a in tb;tb=tb.replace(a,b)
body=r'''
  reg bjob=0;reg [1:0] bdtype=0;
  reg [T*24-1:0] blane=0;reg [T*$clog2(T)-1:0] btile=0;
  reg [T-1:0] bcap=0;reg [T*2048-1:0] bdata=0;
  wire bready,bfault;wire [T-1:0] baccept,bvalid;
  wire [T*2048-1:0] bout;wire [T*16-1:0] bmatrix;wire [T*$clog2(T)-1:0] bcolumn;
  function automatic [31:0] pattern(input integer m,r,q,fp);
    pattern=32'h3f128765+32'((m*64*T*T+r*8*T+q)*257);
    if(fp==0)pattern=pattern&32'hffff;
  endfunction
  task automatic batch(input integer fp);
    integer x,s,d,q,l,ix,m,a,r,k,n,total;
    reg [T-1:0] expected_v;reg [31:0] gold;
    begin
      @(negedge clk_i);cmd=0;lc=0;sr_read_valid_i=0;
      #1;if(!bready || busy_o)$fatal(1,"ownership not released before typed batch");
      bdtype=2'(fp);total=0;
      for(d=0;d<T;d++)begin
        btile[d*$clog2(T)+:$clog2(T)]=$clog2(T)'(T-1-d);
        for(l=0;l<8;l++)blane[d*24+l*3+:3]=3'(7-l);
      end
      for(x=0;x<8*(3*T-2)+30;x++)begin
        bjob=(x==0);bcap=0;bdata=0;expected_v=0;
        for(s=0;s<T;s++)if(x>=1+s)begin
          ix=x-1-s;m=ix/(8*T);a=(ix%(8*T))/8;r=ix%8;
          if(m<2)begin bcap[s]=1;for(l=0;l<8;l++)bdata[s*2048+l*32+:32]=pattern(m,8*a+r,8*s+l,fp);end
        end
        if(x>=9 && (x-9)%8==0)begin
          k=(x-9)/8;
          for(d=0;d<T;d++)begin a=T-1-d;n=k-a;if(n>=0 && n<2*T)expected_v[d]=1;end
        end
        #1;if(bfault || (|compat_fault_o) || (|fault_o) || baccept!==bcap || bvalid!==expected_v)$fatal(1,"mixed typed calendar T%0d C%0d",T,x);
        for(d=0;d<T;d++)if(expected_v[d])begin
          a=T-1-d;n=(x-9)/8-a;m=n/T;s=n%T;
          if(bmatrix[d*16+:16]!=16'(m) || bcolumn[d*$clog2(T)+:$clog2(T)]!=$clog2(T)'(s))$fatal(1,"mixed owner");
          for(q=0;q<8;q++)for(l=0;l<8;l++)begin
            gold=pattern(m,8*a+7-l,8*s+q,fp);
            if(bout[d*2048+(q*8+l)*32+:32]!==gold)$fatal(1,"mixed typed payload");
          end
          total++;
        end
        @(posedge clk_i);#1;@(negedge clk_i);
      end
      if(busy_o || total!=2*T*T)$fatal(1,"mixed typed drain");
      bjob=0;bcap=0;
    end
  endtask
'''
tb=tb.replace('  string path;',body+'\n  string path;')
tb=tb.replace('repeat(2) @(negedge clk_i); rst_ni=1;', 'repeat(2) @(negedge clk_i); rst_ni=1;batch(0);')
tb=tb.replace('    $display("SXM_COMPATIBLE_CORE PASS','    batch(1);\n    $display("SXM_COMPATIBLE_CORE PASS')
tb=tb.replace('endmodule', '\n'+(E/'scripts/resource_bits.svh').read_text()+'\nendmodule') if (E/'scripts/resource_bits.svh').exists() else tb
test=tmp/'mixed_tb.sv';test.write_text(tb)
src=[]
for n in ['sxm_triangle_core','sxm_triangle_row_frontend','sxm_compat_decode','sxm_compat_engine','sxm_triangle_full_core']:
 p=R/f'rtl/sxm_native/{n}.sv';q=tmp/p.name;q.write_bytes(p.read_bytes());src.append(q)
src.append(test)
env=dict(os.environ,VERILATOR_ROOT='/usr/local/share/verilator',VERILATOR_BIN='../../bin/verilator_bin',MAKEFLAGS='OPT_FAST=-O0')
cases=json.loads((E/'results/full03/summary.json').read_text())['results'];results=[]
(out/'manifest.json').write_text(json.dumps(dict(hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in src}),indent=2))
for T in [2,4,8]:
 obj=tmp/f't{T}';cmd=['/usr/local/bin/verilator','--binary','--timing','-j','2','--unroll-count','4096','--unroll-stmts','1000000','--top-module','sxm_compatible_core_tb',f'-GT={T}','--Mdir',str(obj),*[str(p) for p in src]]
 with (out/f'build_t{T}.log').open('w') as f:p=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode:raise SystemExit('mixed build failed')
 case=next(c for c in cases if c['name']==f't{T}_compat_legacy_row_legacy')
 p=subprocess.run([str(obj/'Vsxm_compatible_core_tb'),f'+CASE={case["path"]}',f'+CYCLES={case["cycles"]}','+COMPAT=1'],capture_output=True,text=True)
 (out/f't{T}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr,flush=True)
 results.append(dict(T=T,pass_=p.returncode==0 and 'SXM_COMPATIBLE_CORE PASS' in p.stdout));(out/'summary.json').write_text(json.dumps(results,indent=2))
 if not results[-1]['pass_']:raise SystemExit('mixed ownership regression failed')
