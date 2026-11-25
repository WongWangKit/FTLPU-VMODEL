`timescale 1ns/1ps
module weight_schedule_tb #(parameter T=2,F=52);
 localparam V=8*T,W=8*V;
 bit clk=0,rst=0;always #5 clk=~clk;
 logic [543:0] fixture[0:2],word_i;
 bit activate;wire activate_ready;wire [63:0] image_id;
 bit valid,ack,wrong,inspect; logic [14:0] inspect_row;
 bit [63:0] tick,gen;wire [63:0] rg,pg;wire [31:0] rtag;
 wire ready,reject_cmd,nreq,nready,done,err,ret,merr;
 wire [6:0] mb;wire [2:0] ml;wire [4:0] ms;
 wire [14:0] mr;wire [W-1:0] md,mq;
 wire slot,first_seg,last_seg;
 wire av,rr;wire [63:0] aa;wire [7:0] al;
 bit rv; logic [W-1:0] rd;
 lpu_dma_scheduled_weight_load #(.T(T),.F(F),.RT(128),.Q(T==2?832:384),.ROWS(32)) dut(
   .clk_i(clk),.rst_ni(rst),.enable_i(1'b1),.isolated_i(1'b0),.cancel_i(1'b0),
   .generation_i(gen),.cycle_i(tick),.image_activate_i(activate),.image_activate_ready_o(activate_ready),.image_id_o(image_id),
   .valid_i(valid),.cmd_i(word_i),.ready_o(ready),.reject_o(reject_cmd),
   .result_generation_o(rg),.result_page_o(pg),.slot_o(slot),.first_seg_o(first_seg),.last_seg_o(last_seg),
   .result_valid_o(done),.result_ready_i(ack),.result_error_o(err),.result_tag_o(rtag),
   .native_req_o(nreq),.native_ready_i(nready),.native_lane_o(ml),.native_bank_o(mb),.native_row_o(mr),
   .native_stream_o(ms),.native_data_o(md),.native_ret_i(ret && !inspect),.native_err_i(merr),
   .arvalid(av),.arready(!rv),.araddr(aa),.arlen(al),.rvalid(rv),.rready(rr),.rdata(rd),.rresp(2'b0),.rlast(1'b1));
 wire [2*F-1:0] cmdv,bfault;wire [31:0] cmd;wire [2*F*T-1:0] commits,bc;
 wire [T*32-1:0] west;wire [T*32*64-1:0] westd;wire [2*T*32-1:0] edges;wire [2*T*32*64-1:0] ed;
 wire [2*16*T-1:0] sc;bit inspect_issue;
 lpu_dma_mem_wave #(.T(T),.F(F)) wave(.clk_i(clk),.rst_ni(rst),.req(inspect?inspect_issue:nreq),
   .write_i(!inspect),.bank_i(mb),.stream_i(ms),.row_i(inspect?inspect_row:mr),.vector_i(md),
   .ready(nready),.ret,.err(merr),.vector_o(mq),.cmd_valid(cmdv),.cmd,.normal_write_committed(commits),
   .east_valid(edges[T*32-1:0]),.east_data(ed[T*32*64-1:0]),.west_valid(west),.west_data(westd),
   .native_fault(|bfault),.collision((|sc)||(|bc)));
 lpu_mem_srf_integration #(.MEM_SLICES(F),.MEM_DEPTH_ROWS(32),.SUPERLANES(T)) mem(
   .clk_i(clk),.rst_ni(rst),.bank_issue_valid_i(cmdv),.bank_issue_i({(2*F){cmd}}),
   .boundary_valid_i({west,{(T*32){1'b0}}}),.boundary_data_i({westd,{(T*32*64){1'b0}}}),
   .boundary_valid_o(edges),.boundary_data_o(ed),.normal_write_committed_o(commits),
   .srf_collision_o(sc),.mem_internal_collision_o(bc),.mem_bank_fault_valid_o(bfault));
 function automatic logic [W-1:0] payload(input int idx);
   for(int j=0;j<V;j++)payload[8*j+:8]=8'(idx*47+j+19);
 endfunction
 int ars,launches,leaves,refused,blocked;
 always @(posedge clk) if(rst)begin
   tick<=tick+1;if(tick>1000)$fatal(1,"timeout");
   if(av && !rv)begin
     if(al!=0 || aa!=(ars==6?8192:4096+(ars%3)*2*V))$fatal(1,"bad AXI stride addr=%d",aa);
     rv<=1;rd<=payload(ars==6?3:ars%3);ars++;
   end
   if(rv&&rr)rv<=0;
   if(ready&&reject_cmd)refused++;
   if(dut.mem_req && wrong && tick>=32)blocked++;
   if(nreq && nready)begin
     if(tick<32 || wrong || (rtag==78 && (tick<180 || tick+15+T-int'(mb)/8>=210)) ||
       (rtag==79 && (tick!=420 || tick+15+T-int'(mb)/8+1!=fixture[2][255:192])) ||
       mr!=(rtag==79?14:2+3*(launches%3)) || ms!=fixture[0][431:427] || mb!=fixture[0][422:416] || ml!=(rtag==79?0:3))
       $fatal(1,"unexpected launch edge=%d",tick);
     $display("launch edge=%0d tag=%0d bank=%0d row=%0d stream=%0d",tick,rtag,mb,mr,ms);
     launches++;
   end
   leaves+=$countones(commits);
 end
 task automatic send(input logic [543:0] word,input bit bad);
   @(negedge clk);word_i=word;valid=1;
   do @(posedge clk);while(!ready);
   if(reject_cmd!==bad || dut.dv===bad)$fatal(1,"command rejection");
   @(negedge clk);valid=0;word_i='1; // no metadata may depend on this bus now
 endtask
 task automatic result(input int id,input bit failed);
   while(!done)@(negedge clk);
   repeat(3)begin
     if(err!==failed || rg!=fixture[0][63:0] || pg!=(id==79?fixture[2][127:64]:fixture[0][127:64]) || rtag!=id ||
        {slot,first_seg,last_seg}!==(id==79?3'b011:3'b111))$fatal(1,"result metadata/lifetime");
     @(negedge clk);
   end
   ack=1;@(negedge clk);ack=0;
 endtask
 task automatic readrow(input int r,input logic [W-1:0] expected);
   @(negedge clk);inspect_row=r;inspect_issue=1;
   do @(posedge clk);while(!nready);
   @(negedge clk);inspect_issue=0;while(!ret)@(negedge clk);
   if(merr || mq!==expected)$fatal(1,"physical SRAM readback row=%d",r);
 endtask
 initial begin
   $readmemh("commands.hex",fixture);gen=fixture[0][63:0];
   repeat(4)@(negedge clk);rst=1;
   // Same low 32 generation bits, different high identity: reject before AR.
   activate=1;repeat(2)begin @(posedge clk);if(!activate_ready)$fatal(1,"image bind not ready");end
   @(negedge clk);activate=0;if(image_id!=2)$fatal(1,"same-generation image bind");
   send(fixture[0]^(544'd1<<32),1);
   send(fixture[0]^(544'd3<<480),1); // previous image, same gen/tag/page, still in date
   wrong=1;send(fixture[0],0);
   activate=1;@(posedge clk);if(activate_ready)$fatal(1,"image switched with live descriptor");
   @(negedge clk);activate=0;
   // Corrupt and restore the saved certificate, not a collapsed port net:
   // the active data-channel descriptor and native SR remain untouched.
   if(fixture[0][431:427]!=0)force dut.issuer.s=5'd0;
   else force dut.issuer.s=5'd1;
   while(tick<38)@(negedge clk);
   force dut.issuer.s=fixture[0][431:427];#1;release dut.issuer.s;wrong=0;result(77,0);
   if(launches!=3||leaves!=3*T||blocked==0)$fatal(1,"incomplete positive path");
   send(fixture[1],0);result(78,1);
   if(ars!=6 || launches!=4 || leaves!=4*T || refused!=2)$fatal(1,"expired lease did not drain safely");
   inspect=1;for(int j=0;j<3;j++)begin readrow(2+j*3,payload(j));readrow(3+j*3,'0);end
   inspect=0;send(fixture[2],0);result(79,0);
   inspect=1;readrow(14,payload(3));readrow(15,'0);
   if(ars!=7 || launches!=5 || leaves!=5*T)$fatal(1,"static pager command not consumed");
   $display("PASS scheduled V=%0d AR=%0d launches=%0d leaf_commits=%0d readback_rows=8",V,ars,launches,leaves);
   $finish;
 end
endmodule
