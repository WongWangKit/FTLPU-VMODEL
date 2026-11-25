`timescale 1ns/1ps
module shared_dma_system_tb #(parameter V=32, parameter bit PAGE_TEST=0,parameter bit BG_TEST=0,FORMAL_PROJECTION=0,
 parameter integer PRODUCT_ROWS=0,PRODUCT_COLUMNS=52);
 import lpu_program_load_pkg::*;
 localparam W=8*V,N=21, SRC=4096-2*V,DST=16384-V;
 bit clk_i=0,rst_ni=0;always #5 clk_i=~clk_i;
 logic dv,dr,store,hem,done,err,busy,isolate,ack,fault,progready,pgstart,pgack,pgdone;
 logic [14:0] row;logic [6:0] bank;logic [2:0] lane;logic [31:0] tag,rtag,count,stride;
 logic [63:0] addr,araddr,awaddr;logic [7:0] arid,arlen,awid,awlen,rid,bid;
 logic [2:0] arsize,awsize;logic [1:0] arb,awb,rresp,bresp;
 logic arv,arr,awv,awr,wv,wr,wl,bv,br,rv,rr,rl;logic [W-1:0] wd,rd;logic [V-1:0] ws;
 logic cmdv,cmdr,ldv,ldr;logic [2:0] op;logic [(FORMAL_PROJECTION?7:3)-1:0] idx;logic reload,reloaded;bit cancel=0,stall_ar=0;logic cancel_ready;
 logic [7:0] form_q,form_ncmd;logic [3:0] form_kind;logic [31:0] form_size,form_words;logic [63:0] form_src;
 logic [543:0] form_word;
 bit page_last=0,part=0,load_rec=0,cfg=0;
 integer mode=0;
 integer p0_read_src=0;
 bit hold_bid1=0;
 bit p0_end_only=0;
 bit bg=0,slot=0,first_seg=0,window_open=1,page_cancel=0,retire=0,rslot=0,publish=1;
 logic [63:0] page_no,rpage;
 logic [(PRODUCT_ROWS?4*PRODUCT_COLUMNS:(FORMAL_PROJECTION?208:32))-1:0] bank_set;
 logic [63:0] first_edge=0,limit_edge='1;
 wire [63:0] now_edge,image_id;
 wire rejected;
 bit start_on_b,read_b_image,b_observed;
 bit demanded_slot=1,want_fault=0,recovery=0,store_bad=0;
 logic [63:0] demanded_page=64'h1_0000_0005;
 int event_tag=63,epoch_events=0,epoch_receipts=0,epoch_commits=0;
 logic [63:0] desc_gen=11,current_gen=11;
 bit stale_image;
 wire [14:0] actual_step=(mode==17 || mode==30)?15'd3:15'd1;
 wire [4:0] actual_sr=mode==17?5'd11:5'(24+lane);
 wire [543:0] scheduled_word={image_id-64'(stale_image),tag,13'd0,page_last,first_seg,slot,actual_sr,lane,hem,bank,
   1'b0,actual_step,1'b0,row,stride,count,addr,limit_edge,first_edge,page_no,desc_gen};
 logic [1:0] resident;
 logic retire_ok,wave_fire;
 logic part_ready,rec_ready,receipt;
 bit external_release=0,overlap_return=0;
 wire external_ready;
 integer external_events=0;
 logic [31:0] receipt_tag;
 logic [63:0] receipt_gen;
 integer ncommit=0, nev=0, nreceipt=0, lastcommit=-1, eventtick=-1;
 always @(posedge clk_i)if(rst_ni && PAGE_TEST)begin
   if(dut.mem_ret && dut.page_armed)begin ncommit++;epoch_commits++;lastcommit=$time/10;end
   if(dut.pick_page && dut.fabric_ready)begin
     if((mode>=21?epoch_commits:ncommit)!=(mode==36?2:(FORMAL_PROJECTION?form_word[351:320]:(mode==17?3:(BG_TEST && mode>=13?3*(V/8):N)))) || lastcommit >= $time/10 || (mode>=21?epoch_events:nev)!=0 || want_fault)$fatal(1,"page event before final physical retirement or duplicated: commits=%0d",ncommit);
     epoch_events++;
     nev++;eventtick=$time/10;
   end
   if(receipt)begin
     if((mode>=21?epoch_events:nev)+external_events!=1 || receipt_tag!==event_tag || receipt_gen!==current_gen || (mode>=21?epoch_receipts:nreceipt)!=0 || want_fault)$fatal(1,"incorrect page release receipt");
     epoch_receipts++;
     nreceipt++;
   end
 end
 always @(posedge clk_i)if(rst_ni && external_release && external_ready)external_events++;
 bit ixload,eclear,ewr,ereq,edack,eswap;
 logic [63:0] ixaddr;logic [31:0] ixlimit,eword;logic [9:0] eid;
 wire ecfg,erdy,edone,efail;
 logic [31:0] file_streams;
 lpu_top #(.LEGACY_MXM(1),.ENABLE_QCTL(PAGE_TEST),.PROGRAM_COMMAND_DEPTH(FORMAL_PROJECTION?128:8),
    .PROGRAM_MEM_IMEM_DEPTH(PRODUCT_ROWS?lpu_pkg::dma_mixed_mem_imem_depth(V):8),
    .PROGRAM_MXM_IMEM_DEPTH(PRODUCT_ROWS?lpu_pkg::dma_mixed_mxm_imem_depth(V):8),
    .T(V/8),.MEM_DEPTH_ROWS(PRODUCT_ROWS?0:64),.ACTIVE_MEM_COLUMNS(PRODUCT_ROWS?PRODUCT_COLUMNS:(FORMAL_PROJECTION?52:(BG_TEST?8:4))),.ENABLE_STATIC_WEIGHTS(BG_TEST),.ENABLE_SXM_VXM_EXECUTION(0),
    .PROGRAM_ACTIVE_CONTEXTS(FORMAL_PROJECTION?4:2),.MXM_ACCUMULATOR_BLOCK_COUNT(FORMAL_PROJECTION?lpu_pkg::MXM_ACCUMULATOR_BLOCK_COUNT:1)) dut (
    .clk_i,.rst_ni,.dma_page_last_i(page_last),.dma_page_generation_i(desc_gen),
    .dma_indexed_i(ixload),.dma_index_addr_i(ixaddr),.dma_row_limit_i(ixlimit),
    .expert_clear_i(eclear),.expert_word_valid_i(ewr),.expert_word_i(eword),
    .expert_count_i(11'd2),.expert_segment_count_i(mode==38?9'd32:9'd3),.expert_config_ready_o(ecfg),
    .expert_valid_i(ereq),.expert_ready_o(erdy),.expert_id_i(eid),.expert_bank_xor_i(eswap),
    .expert_stream_mask_i(mode==38?file_streams:32'h01000000),.expert_done_o(edone),.expert_error_o(efail),.expert_done_ready_i(edack),
    .dma_page_event_tag_i(event_tag),.dma_page_mask_i(publish?(FORMAL_PROJECTION?220'd16:(mode==17?220'd2:220'd1)):220'd0),.dma_desc_valid_i(dv),.dma_desc_ready_o(dr),.dma_store_i(store),.dma_hem_i(hem),
    .dma_bg_load_i(bg),.dma_bg_command_i((FORMAL_PROJECTION || mode==31)?form_word:scheduled_word),.dma_bg_epoch_i(current_gen),
    .dma_bg_cycle_o(now_edge),.dma_bg_image_o(image_id),.dma_bg_reject_o(rejected),
    .dma_bg_cancel_i(page_cancel),.dma_bg_bank_mask_i(bank_set),
    .dma_bg_retire_i(retire),.dma_bg_retire_slot_i(rslot),.dma_bg_retire_page_i(rpage),.dma_bg_retire_epoch_i(64'd11),
    .dma_bg_resident_o(resident),.dma_bg_retire_ready_o(retire_ok),.dma_bg_wave_fire_o(wave_fire),
    .dma_start_needs_page_i(start_on_b),.dma_start_slot_i(demanded_slot),.dma_start_generation_i(current_gen),
    .dma_start_page_i(demanded_page),
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
    .program_cancel_valid_i(cancel),.program_cancel_ready_o(cancel_ready),.program_reset_i(reload),.program_reload_ack_o(reloaded),.program_start_request_i(pgstart),
    .program_start_ack_o(pgack),.program_ready_o(progready),.program_done_o(pgdone),.program_fault_o(fault),
    .program_dependencies_ready_i(1'b1),.program_command_write_valid_i(cmdv),.program_command_write_ready_o(cmdr),
    .program_command_write_address_i(idx),.program_command_write_opcode_i(op),.program_command_write_source_address_i(FORMAL_PROJECTION?form_src:64'h8005),
    .program_command_write_byte_count_i(FORMAL_PROJECTION?form_size:48),.program_command_write_target_kind_i(FORMAL_PROJECTION?form_kind:PROGRAM_TARGET_MEM),
    .program_command_write_global_queue_id_i(FORMAL_PROJECTION?form_q:8'(read_b_image)),.program_command_write_format_i(FORMAL_PROJECTION && form_kind!=0?PROGRAM_FORMAT_128:PROGRAM_FORMAT_96),
    .program_command_write_encoding_mode_i(0),.program_command_write_imem_base_address_i(0),
    .program_command_write_image_first_i(1'b1),.program_command_write_image_last_i(1'b1),
    .program_command_write_expected_word_count_i(FORMAL_PROJECTION?form_words:4),.program_command_write_jump_address_i(0),
    .program_load_start_valid_i(ldv),.program_load_start_ready_o(ldr),.program_load_start_command_count_i(FORMAL_PROJECTION?form_ncmd:(p0_end_only?1:4)),
    .qctl_load_mode_i(cfg),.qctl_partition_valid_i(part),.qctl_partition_ready_o(part_ready),
    .qctl_partition_queue_i(FORMAL_PROJECTION?4:(mode==17?1:0)),.qctl_partition_base_i(0),.qctl_partition_count_i(1),.qctl_partition_generation_i(64'd11),
    .qctl_load_valid_i(load_rec),.qctl_load_ready_o(rec_ready),.qctl_load_address_i(0),
    .qctl_load_data_i(lpu_qctl_pkg::qctl_pack_record(0,lpu_qctl_pkg::QCTL_OPCODE_WAIT_EVENT,event_tag)),
    .qctl_receipt_valid_o(receipt),.qctl_receipt_tag_o(receipt_tag),.qctl_receipt_generation_o(receipt_gen),
    .qctl_event_valid_i(external_release),.qctl_event_ready_o(external_ready),.qctl_event_mask_i(220'd1),
    .qctl_event_tag_i(32'd63),.qctl_event_generation_i(64'd11),.qctl_event_phase_i(1'b1),
    .qctl_receipt_ready_i(1'b1),.qctl_sync_valid_i('0),
    .qctl_notify_ready_i('0),.qctl_mem_packet_retired_i('0),.mem_east_edge_valid_i('0),.mem_east_edge_data_i('0),
    .mem_west_edge_valid_i('0),.mem_west_edge_data_i('0));

 typedef struct packed {logic [31:0] a;logic [8:0] n;logic [7:0] id;} burst_t;
 typedef struct packed {logic [W-1:0] data;logic last;} w_t;
 burst_t pq[$],dq[8][$],aq[$],x; w_t wq[$],y;logic [7:0] bids[$];
 integer qbeats=0; bit [7:0] read_ids,write_ids;
 logic [7:0] mem[FORMAL_PROJECTION?262144:65536],gold[2*N*V];integer t=0,np=0,nr=0,nw=0,nb=0,pending=0,iss=0,prog_overlap=0;
 bit inject=0,hold_b=0,hold_r=0,hold_aw=0,hold_w=0,multibeat=0;string golden;
 assign arr=rst_ni && !stall_ar && (t%7>=2);assign awr=rst_ni && !hold_aw && (t%13>=6);assign wr=rst_ni && !hold_w && (t%9>=3);
 integer last_progress=0,expected_ar,expected_row,issued_rows,retired_rows,expected_count;
 always @(posedge clk_i)if(rst_ni) begin
   t++;
   if(mode>=13 && ((arv && arr)||(awv && awr)||dut.mem_ret))last_progress=t;
   if(!FORMAL_PROJECTION && mode>=13 && mode<30 && bg && dv && dr && !rejected)begin
     expected_ar=addr;expected_row=row;expected_count=count;issued_rows=0;retired_rows=0;
   end
   if(!FORMAL_PROJECTION && mode>=13 && mode<30 && dut.bg_active)begin
     if(arv && arr && arid!=0)begin
       if(araddr!=expected_ar)$fatal(1,"background read address got %h expected %h",araddr,expected_ar);
       expected_ar+=(int'(arlen)+1)*V;
     end
     if(wave_fire)begin
       if(page_cancel || !window_open || dut.mem_row!=expected_row+issued_rows*actual_step || dut.mem_bank!=bank ||
          dut.active_stream!=actual_sr)
         $fatal(1,"wrong native wave bank/row or ungranted wave");
       issued_rows++;
     end
     if(dut.mem_ret)retired_rows++;
     if(dut.dma_result_valid_o && !dut.dma_result_error_o &&
        (issued_rows!=expected_count || retired_rows!=expected_count || expected_ar!=addr+expected_count*V))
       $fatal(1,"incomplete background descriptor");
   end
   // Case 13 replays 24 complete pages' segments and stores every vector;
   // keep the old bound on every old case and also detect lack of progress.
   if((FORMAL_PROJECTION || mode>=30)?(t>90000):((mode==13 || mode==16) ? (t>12000+48*3*(V/8)*V || t-last_progress>1200) : t>12000))$fatal(1,"timeout busy=%b wait=%b memrow=%0d memret=%b ar=%d b=%d",
         busy,dut.u_data.waiting,dut.mem_row,dut.mem_ret,nr,nb);
   if(FORMAL_PROJECTION && |dut.local_mem_issue_valid)iss++;
   if(!FORMAL_PROJECTION && dut.local_mem_issue_valid[0])begin iss++;if(dut.local_mem_issue_instruction[31:0]!=32'h00018000)$fatal(1,"program word");end
   if(mode==17 && read_b_image && dut.local_mem_issue_valid[1])begin
     iss++;if(dut.local_mem_issue_instruction[32+:32]!=32'h00018000)$fatal(1,"successor MEM instruction");
   end
   if(pgack && busy)$fatal(1,"program started during reserved MEM window");
   if(arv && arr)begin
     if((mode==38 || mode==39) && arid!=0)$display("DATA_AR %0d %0d %0d",t,araddr,arlen+1);
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
       if(!prog && inject && mode!=23 && (mode!=22 || x.n==1))begin if(mode==2)rid<=8;else if(mode==3)rl<=!(x.n==1);else rresp<=2;inject=0;end
       rv<=1;x.n--;x.a+=V;
       if(prog)begin if(x.n)pq[0]=x;else void'(pq.pop_front());end
       else begin qbeats--;if(x.n)dq[pick][0]=x;else void'(dq[pick].pop_front());end
     end
   end
   if(awv&&awr)begin
     if(mode==38 || mode==39)$display("DATA_AW %0d %0d %0d",t,awaddr,awlen+1);
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
       if(!hold_bid1 || bids[chosen]!=1)begin
       ret_id=bids[chosen];bids.delete(chosen);
       pending--;bv<=1;bid<=(mode==5 && inject)?8:ret_id;bresp<=((mode==4 || mode==23) && inject)?2:0;inject=0;
       end
     end
   end
 end
 // For case 16, the real MEM ICU reads A:row3 during B's outstanding DDR
 // read. Observe the registered native result, not just the issue signal.
 for(genvar tile=0;tile<V/8;tile++)begin: g_active_read
   wire rv_b=dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[0].u_slice.gen_bank[1].u_logical_bank.gen_leaf[tile].u_leaf.read_valid_o;
   wire [63:0] rd_b=dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[0].u_slice.gen_bank[1].u_logical_bank.gen_leaf[tile].u_leaf.read_data_o;
   // STORE readback uses this exact same leaf but reads rows 3,6,9.
   // Here observe only the FU's row-3 read; STORE has its own byte oracle.
   always @(negedge clk_i)if((mode==17 || mode==31) && read_b_image && !dut.dma_busy_o && rv_b)begin
     for(int b=0;b<8;b++)if(rd_b[8*b+:8]!==mem[(mode==31?p0_read_src:4096)+8*tile+b])$fatal(1,"successor read wrong B payload");
     if(tile==V/8-1)b_observed=1;
   end
   wire rv_a=dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[0].u_slice.gen_bank[0].u_logical_bank.gen_leaf[tile].u_leaf.read_valid_o;
   wire [63:0] rd_a=dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[0].u_slice.gen_bank[0].u_logical_bank.gen_leaf[tile].u_leaf.read_data_o;
   always @(negedge clk_i)if(mode==16 && hold_r && dut.bg_active && rv_a)begin
      for(int b=0;b<8;b++)if(rd_a[8*b+:8]!==mem[4096+3*V+8*tile+b])$fatal(1,"active A data changed");
      if(tile==V/8-1)overlap_return=1;
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
     always @(negedge clk_i)if(rst_ni && done && !err && !store && mode!=8 && mode<13 && hem==h)begin
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
 // Same program payloads for A/B. The offline linker supplies B's distinct
 // weight-port directory and rejects any relocation into an occupied queue.
 int fm[96][6],nmap,nprogram,nweight,store_bytes,ar_during_a,mac_issue;
 string fk[96];bit [7:0] expected[FORMAL_PROJECTION?262144:1],expected_b[FORMAL_PROJECTION?262144:1];logic [543:0] weight_cmd[16];
 int bq[64];
 if(FORMAL_PROJECTION)begin: gen_output_probe
   for(genvar h=0;h<2;h++)for(genvar m=0;m<2;m++)for(genvar c=0;c<V/8;c++)begin: g_bank_trace
     `define COL dut.u_fu_subsystems.gen_hemisphere[h].gen_mxm[m].g_legacy.u_mxm_subsystem.u_execution.gen_vector.u_array.gen_bank[c].active_bank
     always @(posedge clk_i)if($test$plusargs("MXM_TRACE") && rst_ni && (`COL.reading || `COL.writing))begin
       $display("BANK %0d %0d %0d %0d %b%b %h %b%b %h",$time/10,h,m,c,`COL.writing,`COL.reading,`COL.addr,`COL.clear_value,`COL.emit_result,`COL.out_value);
     end
     `undef COL
   end
   `define MXA dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].g_legacy.u_mxm_subsystem.u_execution.gen_vector.u_array
   always @(posedge clk_i)if($test$plusargs("MXM_TRACE") && dut.program_running_o && dut.program_schedule_cycle_o<132 && |`MXA.valid_i)
     $display("MAC c=%d valid=%b w0=%h ow=%h tail=%b:%h ok=%b enc=%b vector_w=%h cells=%h cell_ok=%b bad=%b",
       dut.program_schedule_cycle_o,`MXA.valid_i,`MXA.words_i[47:0],`MXA.op[V/8-1][0].w,
       `MXA.gen_bank[0].active_bank.writing,`MXA.gen_bank[0].active_bank.addr,`MXA.gen_bank[0].active_bank.ok,`MXA.gen_bank[0].active_bank.emit_result,`MXA.west_valid_o[31:0],`MXA.cell_valid_i,`MXA.gen_bank[0].active_bank.cell_ok,`MXA.output_bad);
   always @(posedge clk_i)if(rst_ni && dut.program_running_o && `MXA.gen_bank[0].active_bank.writing)
     if($isunknown({`MXA.gen_bank[0].active_bank.ok,`MXA.gen_bank[0].active_bank.cell_ok}))
       $fatal(1,"unknown MXM weight validity or write acceptance at logical cycle %d",dut.program_schedule_cycle_o);
   `undef MXA
   for(genvar s=0;s<2;s++)begin: gen_s
     `define MXM_LEAF dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[s].u_slice.gen_bank[1].u_logical_bank.gen_leaf[0].u_leaf
     always @(posedge clk_i)if($test$plusargs("MXM_TRACE") && dut.program_running_o && dut.program_schedule_cycle_o<132 && (s==0 || `MXM_LEAF.cmd_valid_i))
       $display("RET c=%0d slice=%d mxw=%h sxw=%h cmd=%b op=%h stream=%d row=%d data=%b error=%h",
         dut.program_schedule_cycle_o,s,dut.u_fu_subsystems.gen_hemisphere[0].mxm_west_valid[31:0],
         dut.u_fu_subsystems.gen_hemisphere[0].sxm_west_valid[31:0],`MXM_LEAF.cmd_valid_i,`MXM_LEAF.cmd_opcode_i,
         `MXM_LEAF.cmd_stream_idx_i,`MXM_LEAF.cmd_row_i,`MXM_LEAF.stream_valid_i,`MXM_LEAF.fault_code_o);
     `undef MXM_LEAF
   end
 end
 always @(posedge clk_i)if(FORMAL_PROJECTION && rst_ni)begin
   if(dut.program_running_o && dut.bg_active && arv && arr && arid!=0 && iss>0)begin
     ar_during_a++;$display("B_AR_IN_A edge=%0d schedule=%0d addr=%h count=%0d",now_edge,dut.program_schedule_cycle_o,araddr,arlen+1);
   end
   if(|dut.local_mxm_compute_issue_valid)mac_issue++;
   if(dut.pick_page && dut.fabric_ready)$display("B_EVENT sim_cycle=%0d last_ret_sim_cycle=%0d resident=%b",$time/10,lastcommit,resident);
   if(fault && !want_fault)begin
     $display("MXM local0 word=%h load_fault=%b load_row_valid=%b compute_fault=%b accum_fault=%b",
       dut.local_mxm_compute_issue_instruction[48:0],
       dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].g_legacy.u_mxm_subsystem.u_execution.load_fault,
       dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].g_legacy.u_mxm_subsystem.u_execution.load_row_valid,
       dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].g_legacy.u_mxm_subsystem.u_execution.compute_fault,
       dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].g_legacy.u_mxm_subsystem.u_execution.accumulator_fault);
     $fatal(1,"projection first fault edge=%0d schedule=%0d MEM=%h MXM=%h QCTL=%h SR=%h MEM_issue=%d compute_issue=%d B_AR_in_A=%d events=%d receipts=%d stored_bytes=%d compute_accepted=%b",
     now_edge,dut.program_schedule_cycle_o,dut.mem_fault_o,dut.mxm_fault_o,dut.qctl_fault_code_o,
     dut.stream_conflict_o,iss,mac_issue,ar_during_a,nev,nreceipt,store_bytes,
     dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].g_legacy.u_mxm_subsystem.execution_compute_valid);end
 end
 task automatic form_bind(input bit second,input int serial=0);
   int pc;pc=0;
   for(int i=0;i<nmap;i++)if(fk[i]=="P")begin
     form_kind=fm[i][0];form_q=second?bq[i]:fm[i][1];form_src=fm[i][2];form_size=fm[i][3];form_words=fm[i][4];
     command(pc++,PROGRAM_LOADER_LOAD_IMEM);command(pc++,PROGRAM_LOADER_WAIT_DMA);command(pc++,PROGRAM_LOADER_COMMIT_QUEUE);
   end
   command(pc,PROGRAM_LOADER_END);form_ncmd=pc+1;
   ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
   if(image_id!=(serial?serial:(second?2:1)))$fatal(1,"image activation serial");
 endtask
 logic [7:0] expected_c[FORMAL_PROJECTION?262144:1];
 task automatic form_tensor(input int i,input bit st,input int second);
   @(negedge clk_i);bg=0;store=st;hem=fm[i][0];bank=2*fm[i][1]+fm[i][2];row=fm[i][3];lane=bank%8;
   count=fm[i][4];addr=fm[i][5]+(recovery && !st && fk[i]=="W"?65536:0);stride=V;tag=100+i;page_last=0;dv=1;
   do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;result(tag,st && store_bad);
   if(st && !store_bad)for(int j=0;j<count*V;j+=2)begin
     logic [15:0] oracle,got;
     oracle=second==2?{expected_c[addr+j+1],expected_c[addr+j]}:second?{expected_b[addr+j+1],expected_b[addr+j]}:{expected[addr+j+1],expected[addr+j]};
     got={mem[addr+j+1],mem[addr+j]};
     if(got!==oracle)$fatal(1,"DDR projection B=%b byte=%h got=%h expected=%h",second,addr+j,got,oracle);
     store_bytes+=2;
   end
 endtask
 task automatic form_bg(input int j);
   @(negedge clk_i);bg=1;form_word=weight_cmd[j];dv=1;do @(posedge clk_i);while(!dr);
   if(rejected)$fatal(1,"runtime certificate rejected segment=%d",j);
   @(negedge clk_i);dv=0;result(form_word[479:448],0);bg=0;
 endtask
 logic [543:0] abc_cmd[48];
 task automatic set_mask(input int stage);
   bank_set='0;for(int j=0;j<16;j++)begin
     weight_cmd[j]=abc_cmd[stage*16+j];
     bank_set[(weight_cmd[j][423]?104:0)+weight_cmd[j][422:416]]=1;
   end
 endtask
 task automatic rearm_image;
   reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);@(negedge clk_i);
   if(qbeats || pq.size() || aq.size() || wq.size() || bids.size() || pending || rv || bv || busy || dut.page_pending)
     $fatal(1,"epoch acknowledged with obligations outstanding");
   epoch_events=0;epoch_receipts=0;epoch_commits=0;
 endtask
 task automatic waiting_queue;
   cfg=1;@(negedge clk_i);part=1;do @(posedge clk_i);while(!part_ready);
   @(negedge clk_i);part=0;load_rec=1;do @(posedge clk_i);while(!rec_ready);
   @(negedge clk_i);load_rec=0;cfg=0;
 endtask
 task automatic all_outputs(input int which);
   for(int i=0;i<nmap;i++)if(fk[i]=="S")form_tensor(i,1,which);
 endtask
 task automatic abc_projection;
   int old;
   $readmemh("abc_cmd.hex",abc_cmd);$readmemh("expected_c.hex",expected_c);
   // An END-only bootstrap has no competing compute queues. Its only job
   // is to establish a genuine lease for A before the first projection.
   command(0,PROGRAM_LOADER_END);form_ncmd=1;ldv=1;do @(posedge clk_i);while(!ldr);
   @(negedge clk_i);ldv=0;
   set_mask(0);publish=0;
   for(int i=0;i<nmap;i++)if(fk[i]=="A")form_tensor(i,0,0);
   for(int j=0;j<16;j++)begin
     int src;src=weight_cmd[j][319:256];
     for(int b=0;b<weight_cmd[j][351:320]*V;b++)mem[src+131072+b]=2*mem[src+b]+1;
     form_bg(j);
   end
   if(resident!==1 || nev || nreceipt)$fatal(1,"bootstrap ownership");
   for(int stage=0;stage<2;stage++)begin
     rearm_image();event_tag=70+stage;waiting_queue();form_bind(stage==1,2+stage);
     start_on_b=1;demanded_slot=stage;demanded_page=64'h100000004+stage;
     set_mask(stage+1);publish=1;rslot=0;rpage=64'h100000004;
     if(stage==1)begin
       // C has the live B image's valid calendar, but A still owns slot 0.
       old=nr;bg=1;form_word=weight_cmd[0];dv=1;
       repeat(3)begin @(posedge clk_i);if(dr || dut.desc_fire || nr!=old || resident!=3)$fatal(1,"overwrote A before retire");end
       @(negedge clk_i);dv=0;bg=0;retire=1;@(posedge clk_i);if(!retire_ok)$fatal(1,"A retirement refused");
       @(negedge clk_i);retire=0;if(resident!=2)$fatal(1,"wrong slot cleared");
       // B's ready token cannot release C's wait entry.
       if(epoch_receipts || epoch_events)$fatal(1,"old event released C");
     end
     for(int j=0;j<15;j++)form_bg(j);
     while(now_edge+8<weight_cmd[15][191:128])@(negedge clk_i);
     old=ar_during_a;pgstart=1;@(negedge clk_i);pgstart=0;
     while(!dut.program_running_o)@(negedge clk_i);
     if(stage==0)begin retire=1;repeat(3)begin @(posedge clk_i);if(retire_ok || !resident[0])$fatal(1,"early A retire");end
        @(negedge clk_i);retire=0;end
     form_bg(15);
     while(!pgdone || !epoch_receipts)@(negedge clk_i);
     if(ar_during_a<=old || resident!=3 || epoch_events!=1 || epoch_receipts!=1)$fatal(1,"missing overlap/ownership");
     all_outputs(stage);
   end
   rearm_image();form_bind(0,4);demanded_slot=0;demanded_page=64'h100000006;
   pgstart=1;@(negedge clk_i);pgstart=0;while(!pgdone)@(negedge clk_i);all_outputs(2);
   if(store_bytes!=12288 || nev!=2 || nreceipt!=2 || nw!=nb)$fatal(1,"incomplete triple");
   $display("PASS triple projection V=%d slots=0,1,0 bytes=%d events=%d receipts=%d",V,store_bytes,nev,nreceipt);$finish;
 endtask
 task automatic recover_projection;
   int oldev,oldreceipt,old_ar;oldev=nev;oldreceipt=nreceipt;
   if(!fault || isolate || inject)$fatal(1,"fault did not return as attributable failure");
   rearm_image();if(resident!=0 || fault || dut.desc_failed || !dut.axi_idle)$fatal(1,"unclean recovery");
   current_gen=12;desc_gen=12;start_on_b=0;want_fault=0;store_bad=0;page_cancel=0;
   recovery=1;publish=0;form_bind(0,2);
   @(negedge clk_i);old_ar=nr;bg=1;form_word=weight_cmd[0];dv=1;
   @(posedge clk_i);if(!(dr && rejected) || dut.desc_fire || nr!=old_ar)$fatal(1,"stale G11 command accepted");
   @(negedge clk_i);dv=0;bg=0;
   for(int i=0;i<nmap;i++)if(fk[i]=="W" || fk[i]=="A")form_tensor(i,0,0);
   pgstart=1;@(negedge clk_i);pgstart=0;while(!pgdone)@(negedge clk_i);
   all_outputs(1);
   if(nev!=oldev || nreceipt!=oldreceipt || store_bytes!=4096 || nw!=nb || qbeats || !dut.axi_idle)
     $fatal(1,"stale event, partial result, or bus not drained");
   $display("PASS recovered projection case=%d V=%d generation=%d bytes=%d",mode,V,current_gen,store_bytes);$finish;
 endtask
 task automatic project_pair;
   int fd,fq,k;string key;
   fd=$fopen("map.txt","r");fq=$fopen("b_queues.txt","r");if(!fd||!fq)$fatal(1,"missing projection directories");
   while($fscanf(fd,"%s",key)==1)begin
     if(nmap>=96)$fatal(1,"map capacity");fk[nmap]=key;
     for(int i=0;i<6;i++)if($fscanf(fd,"%d",fm[nmap][i])!=1)$fatal(1,"map record");
     if(key=="P")begin if($fscanf(fq,"%d",bq[nmap])!=1)$fatal(1,"B directory");nprogram++;end
     if(key=="W")nweight++;
     nmap++;
   end
   $fclose(fd);$fclose(fq);if(nweight!=16 || nprogram*3>=128)$fatal(1,"projection layout");
   $readmemh("ddr.hex",mem);$readmemh("expected.hex",expected);$readmemh("expected_b.hex",expected_b);$readmemh("weight_cmd.hex",weight_cmd);
   bank_set='0;
   for(int j=0;j<nweight;j++)begin
     int flat,src,len;flat=(weight_cmd[j][423]?104:0)+weight_cmd[j][422:416];bank_set[flat]=1;
     src=weight_cmd[j][319:256];len=weight_cmd[j][351:320]*V;
     for(int b=0;b<len;b++)mem[src+b]=-mem[src-65536+b]; // INT8 B = -A
   end
   if(mode==38)software_experts();
   if(mode==39)software_kv();
   if(mode==21)abc_projection();
   if(mode!=20)begin cfg=1;@(negedge clk_i);part=1;do @(posedge clk_i);while(!part_ready);
   @(negedge clk_i);part=0;load_rec=1;do @(posedge clk_i);while(!rec_ready);
   @(negedge clk_i);load_rec=0;cfg=0;end
   form_bind(0);
   for(int i=0;i<nmap;i++)if(fk[i]=="W" || fk[i]=="A")form_tensor(i,0,0);
   if(mode==20)begin
     pgstart=1;@(negedge clk_i);pgstart=0;while(!pgdone)@(negedge clk_i);
     for(int i=0;i<nmap;i++)if(fk[i]=="S")form_tensor(i,1,0);
     if(store_bytes!=4096 || !mac_issue)$fatal(1,"serial projection incomplete");
     $display("PASS serial product projection");$finish;
   end
   for(int j=0;j<nweight-1;j++)form_bg(j);
   while(now_edge+8<weight_cmd[15][191:128])@(negedge clk_i);
   pgstart=1;@(negedge clk_i);pgstart=0;while(!iss)@(negedge clk_i);
   if(mode==22 || mode==24 || mode==25)begin
     int old;old=nr;bg=1;form_word=weight_cmd[15];hold_r=1;dv=1;
     do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;while(nr==old)@(negedge clk_i);
     // A is an independent consumer and may finish its arithmetic. B's
     // native writes/event and any successor consumption must still wait.
     repeat(mode==25?384:64)begin @(negedge clk_i);
       if(resident[1] || nev || nreceipt || (mode!=25 && pgdone))$fatal(1,"late B consumed");end
     if(mode!=25)begin want_fault=1;if(mode==22)inject=1;else page_cancel=1;end
     hold_r=0;result(form_word[479:448],mode!=25);page_cancel=0;bg=0;
     if(mode!=25)begin if(nev || nreceipt || resident[1])$fatal(1,"failed B published");recover_projection();end
   end else form_bg(15);
   if(!ar_during_a || !resident[1])$fatal(1,"no B/A overlap or publication");
   while(!pgdone || !nreceipt)@(negedge clk_i);
   if(mode==23)begin want_fault=1;store_bad=1;inject=1;
     for(int i=0;i<nmap;i++)if(fk[i]=="S")begin form_tensor(i,1,0);break;end
     recover_projection();
   end
   for(int i=0;i<nmap;i++)if(fk[i]=="S")form_tensor(i,1,0);
   reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);@(negedge clk_i);
   form_bind(1);if(!resident[1])$fatal(1,"clean same-generation rearm discarded B");
   start_on_b=1;pgstart=1;@(negedge clk_i);pgstart=0;while(!pgdone)@(negedge clk_i);
   for(int i=0;i<nmap;i++)if(fk[i]=="S")form_tensor(i,1,1);
   if(store_bytes!=8192 || !mac_issue || nev!=1 || nreceipt!=1)$fatal(1,"incomplete projection pair");
   if(mode==25)$display("PASS delayed projection V=%d bytes=%d",V,store_bytes);
   $display("PASS product projection pair V=%d checked bytes=%d",V,store_bytes);$finish;
 endtask
 // Direct leaf observation prevents symmetric truncation on LOAD and STORE
 // from masquerading as a successful round trip.
 bit p0_inspect;
 integer p0_native=0,p0_rx=0,p0_tx=0,p0_used=0,p0_live=0,p0_b=0;
 if(PRODUCT_ROWS)for(genvar h=0;h<2;h++)for(genvar k=0;k<V/8;k++)begin
   `define P0BANK(b) dut.u_fu_subsystems.gen_hemisphere[h].u_mem_subsystem.u_native_mem.u_mem.gen_group[12].u_group.gen_slice[3].u_slice.gen_bank[b].u_logical_bank.gen_leaf[k].u_leaf
   always @(posedge clk_i) if(p0_inspect)for(int b=0;b<8;b++)begin
     if($size(`P0BANK(1).mem_array)!=PRODUCT_ROWS ||
        `P0BANK(1).mem_array[PRODUCT_ROWS-1][8*b+:8]!==mem[8192+(3*h+2)*V+k*8+b] ||
        `P0BANK(1).mem_array[0][8*b+:8]!==mem[8192+3*h*V+k*8+b] ||
        `P0BANK(0).mem_array[PRODUCT_ROWS-1][8*b+:8]!==mem[8192+(3*h+1)*V+k*8+b])
        $fatal(1,"P0 physical alias/width h=%d tile=%d byte=%d",h,k,b);
   end
   `undef P0BANK
 end
 task automatic p0_fire;
   dv=1;do @(posedge clk_i);while(!dr);if(rejected)$fatal(1,"unexpected certificate rejection");
   @(negedge clk_i);dv=0;
 endtask
 task automatic p0_indexed;
   int before_ar,before_mem;
   // Last u32 in a vector, select row 3. Payload starts one beat before a 4K boundary.
   ixaddr=1024+V-4;ixlimit=4;mem[ixaddr]=3;for(int b=1;b<4;b++)mem[ixaddr+b]=0;
   for(int b=0;b<3*V;b++)mem[8192-V+b]=8'(11+b*13);
   bank=2;row=9;count=3;stride=V;tag=351;addr=8192-V-3*512;ixload=1;
   p0_fire();result(tag,0);if(nr!=3 || p0_native!=3)$fatal(1,"index/payload burst split or spurious index replay");
   ixload=0;store=1;addr=16384;tag++;p0_fire();result(tag,0);
   for(int b=0;b<3*V;b++)if(mem[16384+b]!==8'(11+b*13))$fatal(1,"indexed output");
   // Runtime OOB must consume exactly the index, descriptor errors no DDR.
   for(int j=0;j<5;j++)begin
     before_ar=nr;before_mem=p0_native;ixload=1;store=(j==1);count=1;stride=V;addr=4096;tag++;
     ixaddr=1024+V-4;ixlimit=3;
     if(j==2)ixaddr++;if(j==3)addr=64'hfffffffffffffe00;
     if(j==4)begin ixlimit=4;inject=1;end
     p0_fire();result(tag,1);
     if(nr-before_ar!=((j==0 || j==4)?1:0) || p0_native!=before_mem || resident || nw!=nb)$fatal(1,"bad index side effect");
     reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);@(negedge clk_i);
   end
   // Accepted index read is still owed on cancel; no new payload may issue.
   p0_end_only=1;command(0,PROGRAM_LOADER_END);ldv=1;do @(posedge clk_i);while(!ldr);
   @(negedge clk_i);ldv=0;ixlimit=4;store=0;addr=4096;tag++;before_ar=nr;hold_r=1;p0_fire();
   while(nr==before_ar)@(negedge clk_i);cancel=1;@(posedge clk_i);if(!cancel_ready)$fatal(1,"cancel not accepted");
   @(negedge clk_i);cancel=0;hold_r=0;result(tag,1);rearm_image();
   if(nr!=before_ar+1 || p0_native!=before_mem)$fatal(1,"cancelled index issued data");
   $display("INDEXED direct STORE, indexed LOAD, 4K, bounds, malformed, cancel and R error V=%0d",V);
 endtask
 task automatic expert_word(int value);
   eword=value;ewr=1;@(posedge clk_i);if(!ecfg)$fatal(1,"blocked table write");@(negedge clk_i);ewr=0;
 endtask
 task automatic expert_request(int id,bit bad);
   eid=id;ereq=1;do @(posedge clk_i);while(!erdy);@(negedge clk_i);ereq=0;
   while(!edone)@(negedge clk_i);if(efail!==bad)$fatal(1,"expert response id=%0d expected_error=%0d",id,bad);
   edack=1;@(negedge clk_i);edack=0;
 endtask
 task automatic software_kv;
   int fd,k,base,ix,lim,c,st;logic [7:0] ref_byte[6144];
   command(0,PROGRAM_LOADER_END);form_ncmd=1;ldv=1;do @(posedge clk_i);while(!ldr);
   @(negedge clk_i);ldv=0;publish=0;
   $readmemh("kv_ddr.hex",mem);$readmemh("kv_gold.hex",ref_byte);
   fd=$fopen("kv_plan.txt","r");if(!fd)$fatal(1,"no KV plan");
   k=0;while($fscanf(fd,"%d%d%d%d%d",base,ix,lim,c,st)==5)begin
     if(k>=24 || c*V!=256)$fatal(1,"KV plane extent");
     ixload=1;ixaddr=ix;ixlimit=lim;store=0;hem=0;bank=0;row=k*c;
     tag=3900+k;addr=base;count=c;stride=st;p0_fire();result(tag,0);k++;
   end
   $fclose(fd);if(k!=24)$fatal(1,"incomplete KV plan");
   fd=$fopen("kv_readback.hex","w");if(!fd)$fatal(1,"KV readback output");
   for(int j=0;j<24;j++)begin
     ixload=0;ixaddr=0;ixlimit=0;store=1;row=j*(256/V);count=256/V;stride=V;
     addr=196608+j*256;tag=4000+j;p0_fire();result(tag,0);
     for(int i=0;i<256;i++)begin
       if(mem[196608+j*256+i]!==ref_byte[j*256+i])
         $fatal(1,"KV readback mismatch plane=%0d offset=%0d",j,i);
       $fdisplay(fd,"%02x",mem[196608+j*256+i]);
     end
   end
   $fclose(fd);$display("PASS software KV V=%0d planes=24 bytes=6144 cycle=%0d",V,t);$finish;
 endtask
 task automatic software_experts;
   int fd,v,rc,n;logic [543:0] grants[2];logic [223:0] mask;
   int h,b,r,base,ix,lim,c,st;
   command(0,PROGRAM_LOADER_END);form_ncmd=1;ldv=1;do @(posedge clk_i);while(!ldr);
   @(negedge clk_i);ldv=0;publish=0;
   fd=$fopen("experts.hex","r");if(!fd)$fatal(1,"no expert table");
   eclear=1;@(posedge clk_i);if(!ecfg)$fatal(1,"table not ready");@(negedge clk_i);eclear=0;
   n=0;while($fscanf(fd,"%h",v)==1)begin expert_word(v);n++;end $fclose(fd);
   if(n!=260)$fatal(1,"table length");$readmemh("grants.hex",grants);
   fd=$fopen("indexed.txt","r");if(!fd)$fatal(1,"no indexed plan");
   n=0;while($fscanf(fd,"%d%d%d%d%d%d%d%d",h,b,r,base,ix,lim,c,st)==8)begin
     if(ix!=262116)$fatal(1,"fixture index location");
     mem[ix]=3;mem[ix+1]=0;mem[ix+2]=0;mem[ix+3]=0;
     ixload=1;store=0;hem=h;bank=b;row=r;addr=base;ixaddr=ix;ixlimit=lim;count=c;stride=st;tag=3800+n;
     p0_fire();result(tag,0);n++;
   end $fclose(fd);if(!n)$fatal(1,"empty indexed plan");ixload=0;
   fd=$fopen("masks.hex","r");if(!fd)$fatal(1,"no calendar masks");
   for(int j=0;j<2;j++)begin
     if($fscanf(fd,"%h%h",mask,file_streams)!=2)$fatal(1,"bad mask");
     bank_set=mask;form_word=grants[j];eswap=j;
     $display("EXPERT_REQUEST %0d %0d",j,t);expert_request(j,0);
     if(!resident[j])$fatal(1,"premature expert completion");$display("RESIDENT %0d %0d",j,t);
     if(!j)begin rearm_image();form_bind(0,2);end
   end $fclose(fd);
   for(int j=0;j<2;j++)begin
     if(j)begin rearm_image();form_bind(1,3);end
     start_on_b=1;demanded_slot=j;demanded_page=64'h100000004+j;
     pgstart=1;@(negedge clk_i);pgstart=0;while(!pgack)@(negedge clk_i);
     $display("START %0d %0d",j,t);while(!pgdone)@(negedge clk_i);
     $display("KERNEL_DONE %0d %0d",j,t);all_outputs(j);$display("STORE_DONE %0d %0d",j,t);
   end
   if(store_bytes!=8192 || !mac_issue || nw!=nb)$fatal(1,"incomplete two expert projections");
   $display("PASS software experts V=%0d bytes=%0d",V,store_bytes);$finish;
 endtask
 task automatic expert_recovery;
   int old_ar;
   p0_end_only=1;command(0,PROGRAM_LOADER_END);ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
   slot=0;page_no=41;bank_set=4;publish=0;eswap=0;
   // Second segment overlaps the first: preflight must reject the WHOLE page.
   for(int pass=0;pass<2;pass++)begin
     eclear=1;@(posedge clk_i);if(!ecfg)$fatal(1,"config busy");@(negedge clk_i);eclear=0;
     expert_word(0);expert_word(2);expert_word(2);expert_word(1);
     for(int i=0;i<3;i++)begin expert_word(4096+256*i);expert_word(0);expert_word(2);expert_word(0);
       expert_word(1);expert_word(0);expert_word(pass==0?4:4+2*i);expert_word(24);end
     if(!pass)begin expert_request(0,1);if(nr || p0_native || resident)$fatal(1,"partial preflight write");end
   end
   // RRESP failure on the SECOND segment, after segment 0 was committed.
   fork
     begin wait(p0_native==2);@(negedge clk_i);hold_r=1;wait(nr==2);@(negedge clk_i);inject=1;hold_r=0;end
     begin expert_request(0,1);end
   join
   if(p0_native!=2 || resident || !fault || isolate)$fatal(1,"incorrect failed-page state");
   rearm_image();current_gen=12;desc_gen=12;command(0,PROGRAM_LOADER_END);ldv=1;
   do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
   desc_gen=11;old_ar=nr;expert_request(0,1);if(nr!=old_ar)$fatal(1,"stale-generation AR");
   desc_gen=12;page_no=42;
   for(int i=0;i<2;i++)for(int b=0;b<2*V;b++)mem[4096+256*i+b]=8'(37*i+b+1);
   expert_request(0,0);if(!resident[0] || nr!=old_ar+2)$fatal(1,"reloaded page not published");
   store=1;bank=2;row=4;addr=16384;count=4;stride=V;tag=370;p0_fire();result(tag,0);
   for(int i=0;i<2;i++)for(int b=0;b<2*V;b++)if(mem[16384+2*V*i+b]!==8'(37*i+b+1))$fatal(1,"stale payload after reload");
   $display("RECOVER overlap, second-segment R fault, stale generation and reload V=%0d",V);
 endtask
 task automatic p0_expert;
   int old_ar;
   p0_end_only=1;command(0,PROGRAM_LOADER_END);ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
   eclear=1;@(posedge clk_i);if(!ecfg)$fatal(1,"table init");@(negedge clk_i);eclear=0;
   expert_word(0);expert_word(2);expert_word(2);expert_word(1);
   for(int i=0;i<3;i++)begin
     expert_word(4096+512*i);expert_word(0);expert_word(2);expert_word(0);
     expert_word(1);expert_word(0);expert_word(4+2*i);expert_word(24);
     for(int b=0;b<2*V;b++)mem[4096+512*i+b]=8'(73*i+11*b+13);
   end
   publish=0;slot=0;page_no=11;bank_set=4;expert_request(2,1);
   bank_set=8;expert_request(0,1);if(nr || resident)$fatal(1,"invalid task touched DDR");
   bank_set=4;expert_request(0,0);if(resident!=1 || nr!=2)$fatal(1,"cold multi-segment");
   old_ar=nr;expert_request(0,0);if(nr!=old_ar)$fatal(1,"resident hit reloaded");
   expert_request(1,1); // occupied by A; bank/page identifier alone cannot hit.
   waiting_queue();publish=1;slot=1;page_no=12;eswap=1;bank_set=8;expert_request(1,0);
   if(resident!=3 || nr!=old_ar+1)$fatal(1,"second expert or slot alias");
   for(int i=0;i<3;i++)begin
     store=1;row=4+2*i;bank=i==2?3:2;count=2;stride=V;addr=16384+512*i;tag=360+i;p0_fire();result(tag,0);
     for(int b=0;b<2*V;b++)if(mem[addr+b]!==8'(73*i+11*b+13))$fatal(1,"wrong expert DDR payload");
   end
   if(nev!=1)$fatal(1,"missing expert page publication");
   // Retire A and start a fresh miss. Cancel after the address has escaped.
   retire=1;rpage=11;rslot=0;@(posedge clk_i);if(!retire_ok)$fatal(1,"A retire");
   @(negedge clk_i);retire=0;slot=0;page_no=13;eswap=0;bank_set=4;
   store=0;old_ar=nr;hold_r=1;eid=0;ereq=1;do @(posedge clk_i);while(!erdy);@(negedge clk_i);ereq=0;
   while(nr==old_ar)@(negedge clk_i);page_cancel=1;@(negedge clk_i);page_cancel=0;
   repeat(6)begin @(negedge clk_i);if(edone || resident[0])$fatal(1,"cancel before AXI drain");end
   hold_r=0;while(!edone)@(negedge clk_i);
   if(!efail || resident[0] || nr!=old_ar+1 || nev!=1)$fatal(1,"failed expert published");
   $display("EXPERT bounds, two slots, multi-segment, XOR, cached reuse, event, cancel and readback V=%0d",V);
 endtask
 task automatic p0_bounds;
   int oar,oaw,om;
   if(dut.u_data.ROWS!=PRODUCT_ROWS || dut.u_fu_subsystems.MEM_DEPTH_ROWS!=PRODUCT_ROWS)$fatal(1,"mixed target geometry");
   for(int h=0;h<2;h++)for(int j=0;j<3;j++)begin
     addr=8192+(3*h+j)*V;for(int b=0;b<V;b++)mem[addr+b]=8'(73*h+29*j+11*b+5);
     hem=h;bank=j==1?102:103;row=j?PRODUCT_ROWS-1:0;lane=7;
     count=1;stride=V;tag=401+3*h+j;store=0;p0_fire();result(tag,0);
     store=1;addr+=4096;p0_fire();result(tag,0);
     for(int b=0;b<V;b++)if(mem[addr+b]!==mem[addr-4096+b])$fatal(1,"bad last-row STORE");
   end
   // One-past and stepped end outside the bank. The latter uses the
   // scheduled port: ordinary descriptors have implicit unit row stride.
   for(int j=0;j<3;j++)begin
     if(j==2)begin p0_end_only=1;command(0,PROGRAM_LOADER_END);ldv=1;do @(posedge clk_i);while(!ldr);
       @(negedge clk_i);ldv=0;bg=1;first_seg=1;slot=0;page_no=99;bank_set='1;end
     store=j==1;row=j==2?PRODUCT_ROWS-3:PRODUCT_ROWS;count=j==2?2:1;tag=600+j;
     oar=nr;oaw=nw;om=p0_native;p0_fire();result(tag,1);
     if(nr!=oar || nw!=oaw || p0_native!=om || resident || nev)$fatal(1,"invalid span published");
     bg=0;reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);@(negedge clk_i);
   end
   p0_inspect=1;@(posedge clk_i);@(negedge clk_i);p0_inspect=0;
   $display("P0 BOUNDS V=%0d rows=%0d columns=%0d rowbits=%0d P=%0d RT=%0d Q=%0d mem_imem=%0d mxm_imem=%0d",V,PRODUCT_ROWS,dut.ACTIVE_MEM_COLUMNS,dut.PACKED_MEM_ROW_BITS,dut.PROGRAM_DMA_RX_FIFO_DEPTH,dut.DMA_RT,dut.DMA_Q,dut.PROGRAM_MEM_IMEM_DEPTH,dut.PROGRAM_MXM_IMEM_DEPTH);
 endtask
 always @(posedge clk_i)if(PRODUCT_ROWS && rst_ni)begin
   if((t%10000)==9999)$display("P0 PROGRESS case=%0d t=%0d fault=%b busy=%b desc=%b/%b reload=%b image=%0d pgack=%b pgdone=%b resident=%b rows=%0d native=%0d rx=%0d tx=%0d b_due=%0d",mode,t,fault,busy,dv,dr,reloaded,image_id,pgack,pgdone,resident,dut.u_data.rows_left,p0_native,dut.u_data.rx.level_o,dut.u_data.tx_level,dut.u_data.b_due);
   if(dut.native_req && dut.native_mem_ready)p0_native++;
   if(dut.u_data.rx.level_o>p0_rx)p0_rx=dut.u_data.rx.level_o;
   if(dut.u_data.tx_level>p0_tx)p0_tx=dut.u_data.tx_level;
   if(dut.u_shared.u_returns.used>p0_used)p0_used=dut.u_shared.u_returns.used;
   if(dut.u_shared.u_returns.live>p0_live)p0_live=dut.u_shared.u_returns.live;
   if(dut.u_data.b_due>p0_b)p0_b=dut.u_data.b_due;
 end
 task automatic p0_tail;
   int begin_tick,elapsed,n,src,dst,delay_r,all_ticks;src=4096;dst=16384;
   p0_end_only=1;command(0,PROGRAM_LOADER_END);ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
   all_ticks=t;
   for(int j=0;j<100;j++)begin
     n=4+j%5;slot=j%2;bank=2+slot;hem=j%2;lane=j%8;bank_set='0;bank_set[hem*104+bank]=1;
     first_seg=1;page_last=1;publish=0;bg=1;page_no=64'h100000000+j;first_edge=now_edge+1+(j*37)%143;
     row=4;count=n;stride=V;addr=src;tag=1000+j;store=0;hold_r=1;
     for(int b=0;b<n*V;b++)mem[src+b]=8'(j*67+b*17);
     begin_tick=t;p0_fire();delay_r=(j*53)%111;repeat(delay_r+1)@(negedge clk_i);hold_r=0;
     while(!resident[slot])@(negedge clk_i);elapsed=t-begin_tick;result(tag,0);
     bg=0;page_last=0;store=1;addr=dst;tag=2000+j;p0_fire();result(tag,0);
     for(int b=0;b<n*V;b++)if(mem[dst+b]!==8'(j*67+b*17))$fatal(1,"late page data");
     rslot=slot;rpage=page_no;retire=1;@(posedge clk_i);if(!retire_ok)$fatal(1,"page retirement");@(negedge clk_i);retire=0;
     $display("PAGE_SAMPLE idx=%0d bytes=%0d latency=%0d",j,n*V,elapsed);
   end
   if(resident || fault || nw!=nb || !dut.axi_idle)$fatal(1,"tail run not drained");
   $display("P0 TAIL V=%0d samples=100 elapsed=%0d",V,t-all_ticks);
 endtask
 task automatic p0_per_id;
   int n,src,dst,old,b_at_cap;n=7*dut.u_shared.PER+8;src=4096;dst=36864;
   for(int b=0;b<n*V;b++)mem[src+b]=8'(b*11+b/V*31+(b/V>>8));
   hem=0;bank=3;lane=6;row=16;count=n;addr=src;stride=V;tag=401;store=0;p0_fire();result(tag,0);
   hold_bid1=1;store=1;addr=dst;stride=2*V;tag=402;p0_fire();
   while(!(dut.u_shared.write_count[0]==dut.u_shared.PER && dut.u_shared.wid==0 && dut.u_data.wr))@(negedge clk_i);
   old=nw;b_at_cap=dut.u_data.b_due;
   repeat(55)begin @(negedge clk_i);
     if(awv || wv || done || nw!=old || dut.u_shared.write_count[0]!=dut.u_shared.PER)$fatal(1,"per-ID credit exceeded");end
   hold_bid1=0;result(tag,0);
   if(nw!=n || nb!=n || !dut.axi_idle || pending || fault)$fatal(1,"write debt");
   for(int k=0;k<7;k++)if(dut.u_shared.write_count[k] || dut.u_shared.u_returns.count[k])$fatal(1,"per-ID leak");
   for(int j=0;j<n;j++)for(int b=0;b<V;b++)if(mem[dst+2*j*V+b]!==mem[src+j*V+b] || mem[dst+(2*j+1)*V+b]!==8'ha5)$fatal(1,"B stress payload/guard");
   $display("P0 ID V=%0d id=1 limit=%0d all_due_at_cap=%0d writes=%0d",V,dut.u_shared.PER,b_at_cap,nw);
 endtask
 task automatic p0_flow;
   int rt,n,src,dst,start_tick,page_tick,store_tick,old;rt=dut.DMA_RT;n=2*rt+32;src=4608;dst=36864;
   for(int j=0;j<n;j++)for(int b=0;b<V;b++)mem[src+2*j*V+b]=8'(79*j+13*b+7+(j>>8));
   command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
   hold_r=1;stall_ar=1;ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
   bg=1;first_seg=1;page_last=1;publish=0;page_no=100;slot=0;hem=0;bank=2;lane=3;bank_set=4;
   row=32;stride=2*V;addr=src;count=n;tag=701;first_edge=now_edge+1200;start_tick=t;p0_fire();stall_ar=0;
   while(qbeats!=rt || !pq.size())@(negedge clk_i);
   old=nr;repeat(24)begin @(negedge clk_i);if(nr!=old || done || resident)$fatal(1,"AR exceeded promised RX");end
   hold_r=0;while(dut.u_data.rx.level_o!=rt)@(negedge clk_i);
   repeat(24)begin @(negedge clk_i);if(nr!=old || p0_native || resident)$fatal(1,"RX escaped calendar");end
   while(!resident[0])@(negedge clk_i);page_tick=t-start_tick;
   while(!done)@(negedge clk_i);
   repeat(77)begin @(negedge clk_i);if(!done || err || rtag!=701 || dr)$fatal(1,"result not held");end
   result(701,0);bg=0;page_last=0;hold_w=1;hold_b=1;store=1;addr=dst;tag=702;store_tick=t;p0_fire();
   while(dut.u_data.tx_level!=rt)@(negedge clk_i);
   old=p0_native;repeat(29)begin @(negedge clk_i);if(p0_native!=old || done)$fatal(1,"TX overflow");end
   hold_w=0;while(dut.u_data.b_due!=dut.u_data.ID_CAP)@(negedge clk_i);
   old=nw;repeat(113)begin @(negedge clk_i);if(nw!=old || done)$fatal(1,"B credit/early STORE");end
   hold_b=0;result(702,0);
   for(int j=0;j<n;j++)for(int b=0;b<V;b++)begin
     if(mem[dst+2*j*V+b]!==8'(79*j+13*b+7+(j>>8)) || mem[dst+(2*j+1)*V+b]!==8'ha5)$fatal(1,"payload or stride hole");
   end
   if(p0_tx!=rt || p0_rx!=rt || p0_live!=rt || p0_used!=rt || p0_b!=dut.u_data.ID_CAP ||
      nr!=n || nw!=n || nw!=nb || p0_native!=2*n || pending || qbeats || dut.u_shared.u_returns.live ||
      dut.u_shared.u_returns.used || dut.u_data.b_due || !dut.axi_idle || !np || fault)$fatal(1,"P0 conservation");
   $display("P0 FLOW V=%0d bytes_each=%0d page_cycles=%0d store_cycles=%0d elapsed=%0d RX=%0d TX=%0d read_live=%0d B_due=%0d program_AR=%0d",V,n*V,page_tick,t-store_tick,t-start_tick,p0_rx,p0_tx,p0_live,p0_b,np);
 endtask
`ifdef FTLPU_P0_DPI
 import "DPI-C" function int ip_can_bind(int gen);
 import "DPI-C" function int ip_bind(int image,int empty);
 import "DPI-C" function int ip_reserve(int page,int src,int users);
 import "DPI-C" function int ip_offer(int tag,int cycle);
 import "DPI-C" function int ip_word(int idx);
 import "DPI-C" function int ip_mask(int idx);
 import "DPI-C" function int ip_handshake(int rejected);
 import "DPI-C" function int ip_result(int tag,int error,int resident);
 import "DPI-C" function int ip_published(int page,int visible);
 import "DPI-C" function int ip_use(int page,int user_id,int finished);
 import "DPI-C" function longint unsigned ip_start_page(int user_id);
 import "DPI-C" function int ip_release(int page,int handshake);
 task automatic p0_driver;
   int old;
   for(int page=1;page<=2;page++)begin
     if(ip_can_bind(current_gen)!=1)$fatal(1,"blocked clean bootstrap bind");
     p0_end_only=1;command(0,PROGRAM_LOADER_END);ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
     p0_read_src=8192+512*page;
     for(int b=0;b<2*V;b++)mem[p0_read_src+b]=8'(page*89+b*13);
     if(ip_bind(image_id,1)!=1 || ip_reserve(page,p0_read_src,page==1?3:1)!=1)$fatal(1,"driver failed to bind/reserve");
     for(int j=0;j<2;j++)begin
       if(ip_offer(800+page*2+j,now_edge)!=1)$fatal(1,"driver calendar");
       for(int k=0;k<17;k++)form_word[k*32+:32]=ip_word(k);
       begin logic [223:0] mask;for(int k=0;k<7;k++)mask[k*32+:32]=ip_mask(k);bank_set=mask;end
       bg=1;publish=0;dv=1;do @(posedge clk_i);while(!dr);
       if(ip_handshake(int'(rejected))!=1 || rejected)$fatal(1,"scheduled command refused");
       @(negedge clk_i);dv=0;while(!done)@(negedge clk_i);
       // Take the very first result handshake; publication is registered
       // separately. Do not rely on an artificial three-clock Host delay.
       ack=1;@(posedge clk_i);
       if(!done || err || ip_result(rtag,int'(err),int'(resident[0]))!=1)$fatal(1,"bad immediate descriptor result");
       if(!resident[0] && ip_start_page(0)!=0)$fatal(1,"START before software observed publication");
       if(j==1)$display("P0 LAST_RESULT page=%0d resident_on_handshake=%0d",page,resident[0]);
       @(negedge clk_i);ack=0;
       if(resident[0]!=(j==1) || ip_published(page,int'(resident[0]))!=(j==1))$fatal(1,"early/missing page");
       bg=0;
     end
     demanded_slot=0;start_on_b=1;
     for(int user_id=0;user_id<(page==1?2:1);user_id++)begin
       rearm_image();read_b_image=1;b_observed=0;p0_end_only=0;
       command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);
       command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
       if(ip_can_bind(current_gen)!=1 || ip_can_bind(current_gen+1)!=0)$fatal(1,"epoch lease not preserved");
       ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
       if(ip_bind(image_id,0)!=1)$fatal(1,"consumer image bind");
       demanded_page=ip_start_page(user_id);if(demanded_page!=64'h100000000+page)$fatal(1,"bad START ticket");
       pgstart=1;@(negedge clk_i);pgstart=0;while(!pgack)@(negedge clk_i);
       if(ip_use(page,user_id,0)!=1 || ip_release(page,0)!=0)$fatal(1,"premature software release");
       while(!pgdone)@(negedge clk_i);
       if(!b_observed || ip_use(page+10,user_id,1)!=0 || ip_use(page,user_id,1)!=1 ||
          ip_use(page,user_id,1)!=0)$fatal(1,"incorrect/wrong-page/duplicate consumer retirement");
       rslot=0;rpage=demanded_page;@(negedge clk_i);
       if(page==1 && user_id==0)begin
         old=nr;
         if(!retire_ok || ip_release(page,0)!=0 || ip_reserve(2,9216,1)!=0)$fatal(1,"future consumer lost");
         repeat(12)begin @(negedge clk_i);if(retire || nr!=old || resident!=1)$fatal(1,"early reuse escaped driver");end
         $display("P0 LEASE first retired, hardware ready, host withheld retirement for pending use");
       end
     end
     if(ip_release(page,0)!=1)$fatal(1,"last retirement lost");retire=1;
     do @(posedge clk_i);while(!retire_ok);if(ip_release(page,1)!=1)$fatal(1,"retire handshake");
     @(negedge clk_i);retire=0;if(resident)$fatal(1,"lease retained");
     if(page==1)rearm_image();
   end
   $display("P0 DRIVER V=%0d pages=2 segments=4 consumers=3 data_AR=%0d",V,nr);
 endtask
`endif
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
   // Same native instruction; the compact initial row consumes only ten bits on LPU16.
   if(V==16) body={3'b0,body[287:48],body[44:0]};
   img={body,96'h17};for(int b=0;b<48;b++)mem['h8005+b]=img[8*b+:8];
   repeat(5)@(negedge clk_i);rst_ni=1;
   if(mode==37)expert_recovery();else if(mode==35)p0_indexed();else if(mode==36)p0_expert();else if(mode==30)p0_bounds();else if(mode==32)p0_flow();else if(mode==33)p0_tail();else if(mode==34)p0_per_id();
`ifdef FTLPU_P0_DPI
   else if(mode==31)p0_driver();
`endif
   else if(FORMAL_PROJECTION)begin project_pair();end else if(mode==17)begin
     int old_ar;
     read_b_image=1;cfg=1;@(negedge clk_i);part=1;do @(posedge clk_i);while(!part_ready);
     @(negedge clk_i);part=0;load_rec=1;do @(posedge clk_i);while(!rec_ready);
     @(negedge clk_i);load_rec=0;cfg=0;
     command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);
     command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
     ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
     bg=1;slot=1;first_seg=1;publish=1;page_last=1;page_no=64'h1_0000_0005;
     bank=1;bank_set=2;lane=5;row=3;count=3;addr=4096;stride=V;tag=701;
     old_ar=nr;stale_image=1;dv=1;@(posedge clk_i);if(!dr||!rejected||dut.desc_fire)$fatal(1,"old image accepted");
     @(negedge clk_i);dv=0;stale_image=0;start_on_b=1;pgstart=1;@(negedge clk_i);pgstart=0;
     repeat(8)begin @(negedge clk_i);if(pgack || nr!=old_ar || dut.program_running_o)$fatal(1,"early START or stale AR");end
     first_edge=now_edge+32;dv=1;do @(posedge clk_i);while(!dr);if(rejected)$fatal(1,"legal page rejected");
     @(negedge clk_i);dv=0;result(701,0);bg=0;page_last=0;
     while(!pgdone)@(negedge clk_i);
     if(!resident[1] || iss!=1 || !b_observed || nev!=1 || nreceipt!=1)$fatal(1,"keyed START/page event/actual MEM result");
     $display("B handoff: last native retire=%d QCTL event=%d MEM issue=%d receipt=%d page=%h",lastcommit,eventtick,iss,nreceipt,page_no);
     for(int j=0;j<3;j++)begin
       store=1;row=3+3*j;count=1;addr='hc000+j*V;tag=710+j;dv=1;
       do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;result(710+j,0);
       for(int b=0;b<V;b++)if(mem['hc000+j*V+b]!==mem[4096+j*V+b])$fatal(1,"non-unit physical row");
     end
     rslot=1;rpage=5;retire=1;@(posedge clk_i);if(retire_ok)$fatal(1,"page truncated to 32 bits");
     @(negedge clk_i);retire=0;reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);
     @(negedge clk_i);if(!resident[1])$fatal(1,"clean rearm lost page");b_observed=0;
     command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);
     command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
     ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
     if(image_id!=2 || !resident[1])$fatal(1,"same-generation B handoff");
     bg=1;dv=1;stale_image=1;@(posedge clk_i);if(!dr || !rejected || dut.desc_fire)$fatal(1,"same-gen stale certificate");
     @(negedge clk_i);bg=0;dv=0;stale_image=0;pgstart=1;@(negedge clk_i);pgstart=0;
     while(!pgdone)@(negedge clk_i);if(iss!=2 || !b_observed)$fatal(1,"successor did not consume prefetched B");
   end else if(mode>=13)begin
     string ds,bytes_file; integer fd,fields,hh,bk,ln,rw,sa,ct,st,sl,pn,last,words,seen_ar;
     integer saved_a[24],saved_bank[24];bit [7:0] bval;
     if(!BG_TEST || !$value$plusargs("DESC=%s",ds) || !$value$plusargs("BYTES=%s",bytes_file))$fatal(1,"missing replay");
     fd=$fopen(bytes_file,"r");words=0;while($fscanf(fd,"%h",bval)==1)begin mem[4096+words]=bval;words++;end
     $fclose(fd);if(words!=3*8*3*(V/8)*V)$fatal(1,"incomplete source weights");
     cfg=1;@(negedge clk_i);part=1;do @(posedge clk_i);while(!part_ready);
     @(negedge clk_i);part=0;load_rec=1;do @(posedge clk_i);while(!rec_ready);
     @(negedge clk_i);load_rec=0;cfg=0;
     command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);
     command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
     ldv=1;pgstart=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;pgstart=0;
     while(!dut.program_running_o)@(negedge clk_i);
     fd=$fopen(ds,"r");
     for(int j=0;j<24;j++)begin
       fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",hh,bk,ln,rw,sa,ct,st,sl,pn,last);
       if(fields!=10)$fatal(1,"incomplete descriptor %d",j);
       saved_a[j]=sa;saved_bank[j]=bk;
       if(j==16)begin
         rslot=0;rpage=999;retire=1;@(negedge clk_i);if(retire_ok || !resident[0])$fatal(1,"stale retire");
         rpage=1;@(posedge clk_i);if(!retire_ok)$fatal(1,"missing final-use grant");@(negedge clk_i);retire=0;
       end
       bg=1;slot=sl;page_no=pn;bank_set=sl?'haaaa:'h5555;first_seg=j%8==0;
       publish=(pn==2 && mode!=16);page_last=last;hem=hh;bank=bk;lane=ln;row=rw;addr=sa;count=ct;stride=st;tag=500+j;store=0;
       if(j==8)begin
         bank_set='h5555;bank=0;dv=1;repeat(3)begin @(posedge clk_i);if(dr)$fatal(1,"alias admitted");end
         @(negedge clk_i);bank_set='haaaa;bank=bk;
       end
       if(j==8 && mode==14)inject=1;
       if(j==8 && mode==16)hold_r=1;
       first_edge=now_edge+(j==8?128:0);
       if(j==8 && mode==19)limit_edge=first_edge+16+(V/8)-bk/8;
       window_open=j!=8;seen_ar=nr;dv=1;
       do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;
       if(j==8)begin
         while(nr==seen_ar)@(negedge clk_i);
         if(mode==16)begin
           external_release=1;do @(posedge clk_i);while(!external_ready);
           @(negedge clk_i);external_release=0;
           while(!overlap_return)@(negedge clk_i);
           if(!resident[0] || resident[1] || !busy || !iss)$fatal(1,"expected A read during B AR-to-R interval");
           hold_r=0;
         end
         repeat(16)begin @(negedge clk_i);if(wave_fire||resident[1]||
           (mode!=14 && (!resident[0]||(mode!=16 && !dut.program_running_o))))$fatal(1,"unsafe B wave");end
         if(mode==15)page_cancel=1;
         window_open=1;
       end
       if(j==8 && (mode==14 || mode==15 || mode==19))begin
         result(tag,1);page_cancel=0;
         if(mode==19 && (issued_rows!=1 || retired_rows!=1))$fatal(1,"expired segment must drain exactly one launched wave");
         if(nev || resident[1])$fatal(1,"failed B became visible");
         reload=1;@(negedge clk_i);reload=0;while(!reloaded)@(negedge clk_i);@(negedge clk_i);
         if(resident!=0 || qbeats || fault)$fatal(1,"reload leaked old epoch");
         // The old generation is rejected even before the external epoch input advances.
         first_seg=1;page_last=1;publish=0;dv=1;
         @(posedge clk_i);if(!(dr && rejected) || dut.desc_fire)$fatal(1,"accepted aborted generation");
         @(negedge clk_i);dv=0;current_gen=12;desc_gen=12;
         command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);
         command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
         @(negedge clk_i);ldv=1;do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
         if(image_id!=2)$fatal(1,"reload did not bind the second image");
         limit_edge='1;dv=1;
         do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;result(tag,0);
         if(!resident[1] || nev)$fatal(1,"new generation did not republish slot");
         bg=0;page_last=0;store=1;addr='hc000;dv=1;
         do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;result(tag,0);
         for(int i=0;i<ct*V;i++)if(mem['hc000+i]!==mem[sa+i])$fatal(1,"reloaded B byte %0d",i);
         break;
       end
       result(tag,0);
       if(last && !resident[sl])$fatal(1,"missing page publication");
       if(j==15 || j==23)begin
         if(j==15)while(!pgdone)@(negedge clk_i);
         for(int k=(j==15?0:16);k<=j;k++)begin
           bg=0;page_last=0;store=1;bank=saved_bank[k];row=0;count=ct;addr='hc000;dv=1;
           do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;result(tag,0);
           for(int i=0;i<ct*V;i++)if(mem['hc000+i]!==mem[saved_a[k]+i])$fatal(1,"replay mismatch desc=%0d byte=%0d",k,i);
         end
       end
     end
     $fclose(fd);
     if(mode==13 && (nev!=1 || nreceipt!=1 || iss!=1 || fault || nw!=nb))$fatal(1,"page execution or B retirement");
     if(mode==16 && (!overlap_return || external_events!=1 || nev || nreceipt!=1 || iss!=1 || fault || nw!=nb))$fatal(1,"concurrent A read and B load");
   end else if(mode==11 || mode==12)begin
     if(!PAGE_TEST)$fatal(1,"enable page producer");
     cfg=1;@(negedge clk_i);part=1;do @(posedge clk_i);while(!part_ready);
     @(negedge clk_i);part=0;load_rec=1;do @(posedge clk_i);while(!rec_ready);
     @(negedge clk_i);load_rec=0;cfg=0;
     command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);
     command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
     page_last=1;inject=mode==12;submit(0,0,SRC,V,101);page_last=0;
     if(mode==12)begin
       result(101,1);repeat(12)@(negedge clk_i);
       if(nev||nreceipt||iss||pgack)$fatal(1,"failed page published");
     end else begin
       result(101,0);
       @(negedge clk_i);ldv=1;pgstart=1;do @(posedge clk_i);while(!ldr);
       @(negedge clk_i);ldv=0;pgstart=0;while(!pgdone)@(negedge clk_i);
       if(iss!=1 || nev!=1 || nreceipt!=1 || fault)$fatal(1,"missing execution/event/receipt %d %d %d",iss,nev,nreceipt);
       submit(1,0,DST,V,102);result(102,0);
       for(int b=0;b<N*V;b++)if(mem[DST+b]!==gold[b])$fatal(1,"page roundtrip byte=%0d",b);
       $display("PAGE commit=%0d event=%0d receipt=%0d MEM_issue=%0d DDR_bytes=%0d",lastcommit,eventtick,nreceipt,iss,N*V);
     end
   end else if(mode==9 || mode==10)begin
     command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
     hold_r=1;stall_ar=mode==10;@(negedge clk_i);ldv=1;
     do @(posedge clk_i);while(!ldr);@(negedge clk_i);ldv=0;
     if(stall_ar)begin while(!arv)@(negedge clk_i);end
     else begin while(pq.size()==0)@(negedge clk_i);end
     cancel=1;@(posedge clk_i);if(!cancel_ready)$fatal(1,"cancel not accepted");
     @(negedge clk_i);cancel=0;reload=1;@(negedge clk_i);reload=0;
     repeat(9)begin @(negedge clk_i);if(reloaded||iss||pgack||(stall_ar&&!arv))$fatal(1,"lost old obligation");end
     stall_ar=0;while(pq.size()==0)@(negedge clk_i);
     repeat(12)begin @(negedge clk_i);if(reloaded||iss)$fatal(1,"R owner reused before return");end
     hold_r=0;while(!reloaded)@(negedge clk_i);if(pq.size()||iss||np!=1)$fatal(1,"cancel did not drain exactly one request");
     @(negedge clk_i);command(0,PROGRAM_LOADER_LOAD_IMEM);command(1,PROGRAM_LOADER_WAIT_DMA);command(2,PROGRAM_LOADER_COMMIT_QUEUE);command(3,PROGRAM_LOADER_END);
     @(negedge clk_i);ldv=1;pgstart=1;do @(posedge clk_i);while(!ldr);
     @(negedge clk_i);ldv=0;pgstart=0;while(!pgdone)@(negedge clk_i);
     if(iss!=1||fault||np!=3)$fatal(1,"fresh epoch did not execute exactly once");
   end else if(mode==8)begin
     // One shared descriptor engine. Cover both hemispheres x eight streams;
     // interleave LOAD(l+1) / STORE(l) while retaining distinct resident rows.
     for(int l=0;l<16;l++)for(int b=0;b<V;b++)mem[24576+l*V+b]=8'(37*l+11*b+5);
     for(int j=0;j<32;j++)begin
       int l;bit st;st=(j==31 || (j>=2 && j%2==0));l=st?(j==31?15:(j-2)/2):(j==0?0:(j+1)/2);
       @(negedge clk_i);store=st;hem=l/8;lane=l%8;bank=l%8;row=32+l;
       addr=(st?28672:24576)+l*V;count=1;stride=V;tag=300+j;dv=1;
       do @(posedge clk_i);while(!dr);@(negedge clk_i);dv=0;result(300+j,0);
     end
     for(int l=0;l<16;l++)for(int b=0;b<V;b++)
       if(mem[28672+l*V+b]!==8'(37*l+11*b+5))$fatal(1,"lane %0d byte %0d",l,b);
   end else if(mode==6)begin
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
