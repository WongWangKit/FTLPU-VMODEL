`timescale 1ns/1ps
module shared_dma_system_tb #(parameter V=32);
 import lpu_program_load_pkg::*;
 localparam W=8*V,N=21, SRC=4096-2*V,DST=16384-V;
 bit clk_i=0,rst_ni=0;always #5 clk_i=~clk_i;
 logic dv,dr,store,hem,done,err,busy,isolate,ack,fault,progready,pgstart,pgack,pgdone;
 logic [14:0] row;logic [6:0] bank;logic [2:0] lane;logic [31:0] tag,rtag,count,stride;
 logic [63:0] addr,araddr,awaddr;logic [7:0] arid,arlen,awid,awlen,rid,bid;
 logic [2:0] arsize,awsize;logic [1:0] arb,awb,rresp,bresp;
 logic arv,arr,awv,awr,wv,wr,wl,bv,br,rv,rr,rl;logic [W-1:0] wd,rd;logic [V-1:0] ws;
 logic cmdv,cmdr,ldv,ldr;logic [2:0] op,idx;logic reload,reloaded;
 lpu_top #(.PROGRAM_COMMAND_DEPTH(8),.PROGRAM_MEM_IMEM_DEPTH(8),.PROGRAM_MXM_IMEM_DEPTH(8),
    .DMA_VECTOR_BYTES(V),.MEM_DEPTH_ROWS(64),.ACTIVE_MEM_COLUMNS(4),.ENABLE_SXM_VXM_EXECUTION(0),
    .PROGRAM_ACTIVE_CONTEXTS(2),.MXM_ACCUMULATOR_BLOCK_COUNT(1)) dut (
    .clk_i,.rst_ni,.dma_desc_valid_i(dv),.dma_desc_ready_o(dr),.dma_store_i(store),.dma_hem_i(hem),
    .dma_bank_i(bank),.dma_lane_i(lane),.dma_row_i(row),.dma_addr_i(addr),.dma_count_i(count),.dma_stride_i(stride),
    .dma_tag_i(tag),.dma_busy_o(busy),.dma_result_valid_o(done),.dma_result_error_o(err),.dma_result_tag_o(rtag),
    .dma_result_ready_i(ack),.dma_isolated_o(isolate),
    .m_axi_araddr_o(araddr),.m_axi_arid_o(arid),.m_axi_arlen_o(arlen),.m_axi_arsize_o(arsize),
    .m_axi_arburst_o(arb),.m_axi_arvalid_o(arv),.m_axi_arready_i(arr),.m_axi_rvalid_i(rv),
    .m_axi_rready_o(rr),.m_axi_rid_i(rid),.m_axi_rdata_i(rd),.m_axi_rlast_i(rl),.m_axi_rresp_i(rresp),
    .m_axi_awaddr_o(awaddr),.m_axi_awid_o(awid),.m_axi_awlen_o(awlen),.m_axi_awsize_o(awsize),
    .m_axi_awburst_o(awb),.m_axi_awvalid_o(awv),.m_axi_awready_i(awr),.m_axi_wdata_o(wd),
    .m_axi_wstrb_o(ws),.m_axi_wlast_o(wl),.m_axi_wvalid_o(wv),.m_axi_wready_i(wr),
    .m_axi_bvalid_i(bv),.m_axi_bid_i(bid),.m_axi_bresp_i(bresp),.m_axi_bready_o(br),
    .program_reset_i(reload),.program_reload_ack_o(reloaded),.program_start_request_i(pgstart),
    .program_start_ack_o(pgack),.program_ready_o(progready),.program_done_o(pgdone),.program_fault_o(fault),
    .program_dependencies_ready_i(1'b1),.program_command_write_valid_i(cmdv),.program_command_write_ready_o(cmdr),
    .program_command_write_address_i(idx),.program_command_write_opcode_i(op),.program_command_write_source_address_i(64'h8005),
    .program_command_write_byte_count_i(48),.program_command_write_target_kind_i(PROGRAM_TARGET_MEM),
    .program_command_write_global_queue_id_i(0),.program_command_write_format_i(PROGRAM_FORMAT_96),
    .program_command_write_encoding_mode_i(0),.program_command_write_imem_base_address_i(0),
    .program_command_write_image_first_i(1'b1),.program_command_write_image_last_i(1'b1),
    .program_command_write_expected_word_count_i(4),.program_command_write_jump_address_i(0),
    .program_load_start_valid_i(ldv),.program_load_start_ready_o(ldr),.program_load_start_command_count_i(4),
    .qctl_load_mode_i(0),.qctl_partition_valid_i(0),.qctl_load_valid_i(0),.qctl_event_valid_i('0),.qctl_sync_valid_i('0),
    .qctl_notify_ready_i('0),.qctl_mem_packet_retired_i('0),.mem_east_edge_valid_i('0),.mem_east_edge_data_i('0),
    .mem_west_edge_valid_i('0),.mem_west_edge_data_i('0));

 typedef struct packed {logic [31:0] a;logic [8:0] n;logic [7:0] id;} burst_t;
 typedef struct packed {logic [W-1:0] data;logic last;} w_t;
 burst_t pq[$],dq[8][$],aq[$],x; w_t wq[$],y;logic [7:0] bids[$];
 integer qbeats=0; bit [7:0] read_ids,write_ids;
 logic [7:0] mem[65536],gold[2*N*V];integer t=0,np=0,nr=0,nw=0,nb=0,pending=0,iss=0,prog_overlap=0;
 integer mode=0;bit inject=0,hold_b=0,hold_r=0,hold_aw=0,hold_w=0,multibeat=0;string golden;
 assign arr=rst_ni && (t%7>=2);assign awr=rst_ni && !hold_aw && (t%13>=6);assign wr=rst_ni && !hold_w && (t%9>=3);
 always @(posedge clk_i)if(rst_ni) begin
   t++;if(t>12000)$fatal(1,"timeout busy=%b wait=%b memrow=%0d memret=%b ar=%d b=%d",
         busy,dut.u_data.waiting,dut.mem_row,dut.mem_ret,nr,nb);
   if(dut.local_mem_issue_valid[0])begin iss++;if(dut.local_mem_issue_instruction[31:0]!=32'h00018000)$fatal(1,"program word");end
   if(pgack && busy)$fatal(1,"program started during reserved MEM window");
   if(arv && arr)begin
     if(arsize!=$clog2(V)||arb!=1||araddr%V||araddr[11:0]+(32'(arlen)+1)*V>4096)$fatal(1,"AR shape");
     x.a=araddr;x.n=9'(arlen)+1;x.id=arid;
     if(arid==0)begin pq.push_back(x);np++;if(busy)prog_overlap++;end
     else if(arid<=7)begin dq[arid].push_back(x);qbeats+=x.n;nr++;read_ids[arid]=1;end else $fatal(1,"ARID");
   end
   if((!rv||rr) && !hold_r)begin
     rv<=0;
     if(t%5!=0 && (pq.size()||qbeats))begin
       bit prog;int pick;prog=pq.size() && (!qbeats || (t%3==1));
       pick=1;for(int k=1;k<=7;k++)if(dq[k].size())pick=k;
       x=prog?pq[0]:dq[pick][0];rid<=x.id;rresp<=0;rl<=x.n==1;
       for(int b=0;b<V;b++)rd[b*8+:8]<=mem[x.a+b];
       if(!prog && inject)begin if(mode==2)rid<=8;else if(mode==3)rl<=!(x.n==1);else rresp<=2;inject=0;end
       rv<=1;x.n--;x.a+=V;
       if(prog)begin if(x.n)pq[0]=x;else void'(pq.pop_front());end
       else begin qbeats--;if(x.n)dq[pick][0]=x;else void'(dq[pick].pop_front());end
     end
   end
   if(awv&&awr)begin
     if(awid<1||awid>7||awsize!=$clog2(V)||awb!=1||awaddr[11:0]+(32'(awlen)+1)*V>4096)$fatal(1,"AW shape");
     if(awlen!=0)multibeat=1; x.a=awaddr;x.n=9'(awlen)+1;x.id=awid;aq.push_back(x);nw++;write_ids[awid]=1;
   end
   if(wv&&wr)begin if(ws!='1)$fatal(1,"WSTRB");y.data=wd;y.last=wl;wq.push_back(y);end
   if(aq.size() && wq.size())begin
     x=aq[0];y=wq.pop_front();if(y.last!=(x.n==1))$fatal(1,"WLAST");
     for(int b=0;b<V;b++)mem[x.a+b]=y.data[b*8+:8];
     x.a+=V;x.n--;if(x.n)aq[0]=x;else begin void'(aq.pop_front());pending++;bids.push_back(x.id);end
   end
   if(bv&&br)nb++;
   if(!bv||br)begin
     bv<=0;if(pending && !hold_b && (t%11==0))begin
       logic [7:0] ret_id;int chosen;chosen=0;
       for(int k=1;k<bids.size();k++)if(bids[k]>bids[chosen])chosen=k;
       ret_id=bids[chosen];bids.delete(chosen);
       pending--;bv<=1;bid<=(mode==5 && inject)?8:ret_id;bresp<=(mode==4 && inject)?2:0;inject=0;
     end
   end
 end
 assert property(@(posedge clk_i) disable iff(!rst_ni || isolate) arv&&!arr |=> isolate || (arv&&$stable({araddr,arlen,arid})));
 assert property(@(posedge clk_i) disable iff(!rst_ni || isolate) awv&&!awr |=> isolate || (awv&&$stable({awaddr,awlen,awid})));
 assert property(@(posedge clk_i) disable iff(!rst_ni || isolate) wv&&!wr |=> isolate || (wv&&$stable({wd,ws,wl})));
 // Sample the actual physical SRAM, independently of the STORE address path:
 // symmetric bugs in LOAD/STORE routing must not pass a DDR round trip.
 for(genvar h=0;h<2;h++)begin: g_oracle_hem
   localparam S=h?3:1, B=h?1:0;
   for(genvar k=0;k<V/8;k++)begin: g_oracle_tile
     always @(negedge clk_i)if(rst_ni && done && !err && !store && hem==h)begin
       for(int v=0;v<N;v++)for(int b=0;b<8;b++)
         if(dut.u_fu_subsystems.gen_hemisphere[h].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[S].u_slice.gen_bank[B].u_logical_bank.gen_leaf[k].u_leaf.mem_array[3+v][8*b+:8]
             !==gold[(h*N+v)*V+8*k+b])$fatal(1,"physical MEM mismatch h=%0d slice=%0d bank=%0d row=%0d tile=%0d byte=%0d",h,S,B,3+v,k,b);
     end
   end
 end
 task automatic submit(bit st,int h,int base,int step,int seq);
   @(negedge clk_i);store=st;hem=h;lane=h?6:3;bank=h?7:2;row=3;addr=base;count=N;stride=step;tag=seq;dv=1;
   do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;
 endtask
 task automatic result(int seq,bit error);
   while(!done)@(negedge clk_i);
   repeat(3)begin if(rtag!=seq||err!=error||!done||busy)$fatal(1,"descriptor completion");@(negedge clk_i);end
   ack=1;@(negedge clk_i);ack=0;
 endtask
 task automatic command(int i,int opcode);
   @(negedge clk_i);idx=i;op=opcode;cmdv=1;do @(posedge clk_i);while(!cmdr);@(negedge clk_i);cmdv=0;
 endtask
 initial begin
   logic [287:0] body;logic [383:0] img;
   dv=0;store=0;hem=0;ack=0;pgstart=0;row=0;bank=0;lane=0;tag=0;count=0;stride=0;addr=0;
   cmdv=0;ldv=0;op=0;idx=0;reload=0;rv=0;bv=0;rid=0;bid=0;rd=0;rl=0;rresp=0;bresp=0;
   void'($value$plusargs("CASE=%d",mode));
   if(!$value$plusargs("GOLD=%s",golden))$fatal(1,"CModel golden missing");$readmemh(golden,gold);
   for(int i=0;i<65536;i++)mem[i]=8'ha5;
   for(int h=0;h<2;h++)for(int v=0;v<N;v++)for(int b=0;b<V;b++)
      mem[SRC+h*8192+v*(h+1)*V+b]=8'(h*97+v*37+b*11+5);
   body=0;body[3+:32]=5;body[35+:13]=3;body[49]=1;body[50+:32]=32'h00018000;
   body[82+:32]=1;body[114+:32]=1;body[178+:32]=1;body[210+:32]=1;body[274+:2]=1;
   img={body,96'h17};for(int b=0;b<48;b++)mem['h8005+b]=img[8*b+:8];
   repeat(5)@(negedge clk_i);rst_ni=1;
   if(mode==6)begin
     for(int i=0;i<4;i++)begin
       @(negedge clk_i);store=i[0];hem=0;lane=1;bank=0;row=(i==1)?60:0;
       addr=(i==0)?1:(i==2)?64'hffffffffffffff00:SRC;count=(i==3)?0:N;stride=V;tag=200+i;dv=1;
       do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;result(200+i,1);
       if(np||nr||nw||nb||dut.mem_req)$fatal(1,"invalid descriptor published work");
       reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);
     end
     submit(0,0,SRC,V,210);result(210,0);
   end else if(mode==1 || mode==2 || mode==3)begin
     inject=1;submit(0,0,SRC,V,101);
     if(mode==1)begin result(101,1);reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);
        submit(0,0,SRC,V,102);result(102,0);end
     else begin while(!isolate)@(negedge clk_i);repeat(10)@(negedge clk_i);if(dr||done||!fault)$fatal(1,"read quarantine");end
   end else begin
     command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
     hold_r=1;submit(0,0,SRC,V,100);ldv=1;pgstart=1;
     do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;pgstart=0;
     repeat(24)@(negedge clk_i);if(pq.size()==0||qbeats==0)$fatal(1,"no simultaneous program/data outstanding");
     hold_r=0;result(100,0);while(!pgdone)@(negedge clk_i);
     if(iss!=1||prog_overlap==0)$fatal(1,"program DDR issue");
     submit(0,1,SRC+8192,2*V,101);result(101,0);
     if(mode==4 || mode==5)inject=1;
     if(mode==7)begin
       reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);@(negedge clk_i);
       command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
       hold_w=1; // AW must handshake while W is blocked. Allow a real TX backlog.
     end
     hold_b=1;submit(1,0,DST,V,102);
     if(mode==7)begin
       while(!aq.size())@(negedge clk_i);
       if(wq.size()||!wv)$fatal(1,"AW-first independence");
       ldv=1;pgstart=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;pgstart=0;
       while(dut.u_data.tx_level<17)@(negedge clk_i);
       if(np!=4||pgack||iss!=1)$fatal(1,"program did not refill concurrently with stalled STORE");
       hold_w=0;
     end
     repeat(100)@(negedge clk_i);
     if(done)$fatal(1,"STORE retired before B");hold_b=0;
     if(mode==5)begin while(!isolate)@(negedge clk_i);if(done||dr)$fatal(1,"B quarantine");end
     else if(mode==4)result(102,1);
     else begin result(102,0);
       if(mode==7)begin while(!pgdone)@(negedge clk_i);if(iss!=2||!multibeat)$fatal(1,"program execution/multibeat STORE");hold_aw=1;end
       submit(1,1,DST+8192,2*V,103);
       if(mode==7)begin while(!wq.size())@(negedge clk_i);if(aq.size()||!awv)$fatal(1,"W-first independence");hold_aw=0;end
       result(103,0);
       for(int h=0;h<2;h++)for(int v=0;v<N;v++)for(int b=0;b<V;b++)begin
          if(mem[DST+h*8192+v*(1+h)*V+b]!==gold[(h*N+v)*V+b])$fatal(1,"CModel mismatch h=%d row=%d byte=%d",h,v,b);
          if(h && mem[DST+h*8192+v*2*V+b+V]!=8'ha5)$fatal(1,"stride hole overwritten");
       end
       if(nw!=nb||pending||wq.size()||aq.size()||!np||!nr||!nw||read_ids!=8'hfe||write_ids!=8'hfe)$fatal(1,"wire conservation/ID coverage");
     end
   end
   $display("PASS shared DMA V=%0d P/RT/Q=%0d/%0d/%0d case=%0d cycles=%0d programAR=%0d dataAR=%0d AW=%0d B=%0d",V,dut.PROGRAM_DMA_RX_FIFO_DEPTH,dut.DMA_RT,dut.DMA_Q,mode,t,np,nr,nw,nb);$finish;
 end
endmodule
