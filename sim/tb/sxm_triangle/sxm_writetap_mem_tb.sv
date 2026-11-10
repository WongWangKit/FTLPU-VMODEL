`timescale 1ns/1ps
module sxm_writetap_mem_tb #(parameter integer T=4,COLUMNS=6,LEFT=3);
 reg clk_i=0,rst_ni=0;always #5 clk_i=~clk_i;
 reg job_valid_i=0,fp32_i=1,resources_ready_i=1;
 reg [15:0] matrices_i=1;reg [14:0] base_i=16;
 reg [T*$clog2(T)-1:0] tile_map_i=0;reg [T*24-1:0] lane_map_i=0;
 wire job_ready_o;
 reg [T-1:0] cap_valid_i=0;reg [T*256-1:0] cap_data_i=0;
 wire [T-1:0] cap_accept_o;
 reg [31:0] read_issue_valid_i=0;reg [1023:0] read_issue_i=0;
 wire [T*32-1:0] read_valid_o;wire [T*2048-1:0] read_data_o;
 wire [31:0] committed_segments_o;wire done_o,busy_o,fault_o;
 wire [32*T-1:0] tap_sample_o;
 lpu_sxm_triangle_mem_integration #(.T(T),.DEPTH(1024),.FABRIC_COLUMNS(COLUMNS),.MEM_LEFT(LEFT)) dut(.*);
 integer N=1,FP=1,MAP=0,NEG=0,SECOND=0,SCRAMBLE=0,pass,c,s,m,a,r,l,b,g,phase,ix,row,st,readstart,cycles;
 bit reset_done=0;
 integer seen=0,dones=0,leaf_writes=0;
 reg [T*32-1:0] expected;
 reg [31:0] v;
 function automatic [31:0] value(input integer mm,rr,cc);
   if(FP!=0)value=32'h3f000001+32'((mm*(8*T)*(8*T)+rr*(8*T)+cc)*259);
   else value=32'hdead0000 | ((32'h4000+32'((mm*(8*T)*(8*T)+rr*(8*T)+cc)*13))&32'hffff);
 endfunction
 // Independent observation of actual native leaf write conditions. No force,
 // no internal SRAM readback. It must agree with the adapter's metadata monitor.
 wire [32*T-1:0] actual_tap;
 for(genvar gg=0;gg<4;gg++)for(genvar bb=0;bb<8;bb++)for(genvar tt=0;tt<T;tt++)begin:g_observe
   wire cv=dut.g_mem[gg].u_mem.gen_slice[bb/2].u_slice.gen_bank[bb%2].u_logical_bank.current_cmd_valid_o[tt];
   wire [2:0] op=dut.g_mem[gg].u_mem.gen_slice[bb/2].u_slice.gen_bank[bb%2].u_logical_bank.current_cmd_opcode_o[tt*3+:3];
   wire preserve=dut.g_mem[gg].u_mem.gen_slice[bb/2].u_slice.gen_bank[bb%2].u_logical_bank.current_cmd_preserve_o[tt];
   wire valid_data=dut.g_mem[gg].u_mem.gen_slice[bb/2].u_slice.gen_bank[bb%2].u_logical_bank.stream_valid_i[tt];
   assign actual_tap[(gg*8+bb)*T+tt]=cv && op==1 && preserve && valid_data;
 end
 always @(posedge clk_i)if(rst_ni)begin
   if(actual_tap!==tap_sample_o)$fatal(1,"native Tap observer mismatch actual=%h sample=%h issue=%h monitor_issue=%h target=%h",actual_tap,tap_sample_o,dut.wi,dut.u_sxm.u_completion.wi,dut.target);
   for(integer p=0;p<32*T;p++)if(actual_tap[p])leaf_writes++;
 end
 initial begin
   if($value$plusargs("N=%d",N))begin end
   if($value$plusargs("FP=%d",FP))begin end
   if($value$plusargs("MAP=%d",MAP))begin end
   if($value$plusargs("NEG=%d",NEG))begin end
   if($value$plusargs("SECOND=%d",SECOND))begin end
   if($value$plusargs("SCRAMBLE=%d",SCRAMBLE))begin end
   if(NEG==1)resources_ready_i=0;
   if(NEG==2)base_i=1023;
   for(integer t=0;t<T;t++)begin
     tile_map_i[t*$clog2(T)+:$clog2(T)]=$clog2(T)'(MAP!=0?T-1-t:t);
     for(integer ll=0;ll<8;ll++)lane_map_i[t*24+ll*3+:3]=3'(MAP!=0?(ll*3+1)%8:ll);
   end
   if(NEG==7)tile_map_i=0;
   matrices_i=16'(N);fp32_i=(FP!=0);readstart=(N+2)*8*T+40;cycles=readstart+N*64*T+T+10;
   if(NEG==8)matrices_i=0;
   repeat(2)@(negedge clk_i);rst_ni=1;
   for(pass=0;pass<(SECOND!=0?2:1);pass++)begin
   if(pass!=0)begin FP=1-FP;fp32_i=(FP!=0);seen=0;dones=0;leaf_writes=0;end
   for(c=0;c<cycles;c++)begin
     if(NEG==6 && c==12 && !reset_done)begin
       rst_ni=0;job_valid_i=0;cap_valid_i=0;read_issue_valid_i=0;
       repeat(3)@(negedge clk_i);leaf_writes=0;rst_ni=1;reset_done=1;c=-1;continue;
     end
     job_valid_i=(c==0);cap_valid_i=0;cap_data_i=0;read_issue_valid_i=0;read_issue_i=0;expected=0;
     if(SCRAMBLE!=0 && c==2)begin fp32_i=!fp32_i;matrices_i=0;base_i=1023;tile_map_i=0;lane_map_i=0;end
     if(NEG==9 && c==2)job_valid_i=1;
     for(s=0;s<T;s++)if(c>=1+s)begin
       ix=c-1-s;m=ix/(8*T);a=(ix%(8*T))/8;r=ix%8;
       if(m<N)begin cap_valid_i[s]=1;for(l=0;l<8;l++)cap_data_i[s*256+l*32+:32]=value(m,8*a+r,8*s+l);end
     end
     for(g=0;g<4;g++)for(phase=0;phase<2;phase++)begin
       ix=c-readstart+(5-g)-phase;
       if(ix>=0 && ix%8==0 && ix/8<N*8*T && (FP!=0 || phase==0))begin
         row=ix/8;r=row%8;
         if((r*((FP!=0)?4:2))/8==g)for(b=0;b<2;b++)begin
           st=r*((FP!=0)?4:2)+2*phase+b;
           read_issue_valid_i[st]=1;
           read_issue_i[st*32+:32]=(32'(16+row/8)<<15)|32'h100|(32'(b)<<3);
         end
       end
     end
     for(s=0;s<T;s++)begin
       ix=c-readstart-s;
       if(ix>=0 && ix/8<N*8*T && (ix%8==0 || (FP!=0 && ix%8==1)))expected[s*32+:2]=2'b11;
     end
     if(NEG==3 && c==2)begin read_issue_valid_i=1;read_issue_i[31:0]=32'h100;end
     // Drop one producer segment before SRF capture. The targeted native Tap
     // must be diagnosed even though a non-target empty Tap is a legal no-op.
     if(NEG==4 && c==9)force dut.sv[0]=1'b0;
     if(NEG==4 && c==10)release dut.sv[0];
     // Native command fault injection only: drop a whole group's root issue,
     // or corrupt the monitored bank's target address. Never change MEM arrays.
`ifdef SXM_FAULT_INJECTION
     // Test-only root-command interposer is inserted into the frozen snapshot
     // by run_sim.py. Both native MEM and completion see the same faulty net.
     dut.u_sxm.test_drop_root=(NEG==10 && c==11);
     dut.u_sxm.test_bad_address=(NEG==11 && c==11);
`else
     if(NEG>=10)$fatal(1,"command fault cases require the explicit test interposer");
`endif
     if(NEG==5 && c==8)cap_valid_i[0]=0;
     #1;
     if(NEG>0 && NEG!=6 && fault_o)begin
       if(done_o)$fatal(1,"negative fake completion");
       if((NEG==1 || NEG==2 || NEG==7 || NEG==8) && (|cap_accept_o || |dut.wi || committed_segments_o!=0))$fatal(1,"rejected job side effect");
       $display("PASS WRITETAP NEG=%0d T=%0d first_fault=%0d",NEG,T,c);$finish;#1;
     end
     if(NEG>0 && NEG!=6 && c>30)$fatal(1,"missing negative fault");
     if(fault_o)$fatal(1,"T%0d N%0d FP%0d C%0d fault core%0b writer%0b mem%h monitor%0b bad%0b",T,N,FP,c,dut.core_fault,dut.writer_fault,dut.mem_fault,dut.monitor_bad,dut.bad_q);
     if(cap_accept_o!==cap_valid_i)$fatal(1,"capture C%0d",c);
     if(read_valid_o!==expected)$fatal(1,"read valid C%0d actual%h expected%h",c,read_valid_o,expected);
     if(done_o)dones++;
     for(s=0;s<T;s++)for(b=0;b<2;b++)if(expected[s*32+b])begin
       ix=c-readstart-s;row=ix/8;phase=ix%8;m=row/(8*T);r=row%(8*T);
       for(l=0;l<8;l++)begin
         v=value(m,8*(MAP!=0?T-1-s:s)+(MAP!=0?(l*3+1)%8:l),r);
         if(read_data_o[(s*32+b)*64+l*8+:8]!==v[(phase*2+b)*8+:8])$fatal(1,"Read data C%0d tile%0d row%0d lane%0d byte%0d",c,s,r,l,phase*2+b);
       end
       seen++;
     end
     @(posedge clk_i);#1;@(negedge clk_i);
   end
   if(busy_o || dones!=1 || committed_segments_o!=32'(N*8*T*T*((FP!=0)?4:2)) || seen!=leaf_writes || seen!=N*8*T*T*((FP!=0)?4:2))$fatal(1,"count/drain commits%0d reads%0d leaf%0d done%0d",committed_segments_o,seen,leaf_writes,dones);
   $display("PASS WRITETAP T=%0d FP=%0d N=%0d elements=%0d commits=%0d reads=%0d payload_shell_bytes=0",T,FP,N,N*64*T*T,committed_segments_o,seen);
   end
   $finish;
 end
endmodule
