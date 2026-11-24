`timescale 1ns/1ps
module program_system_tb #(parameter bit PHASE_TEST=0);
import lpu_program_load_pkg::*;

localparam PROGRAM_COMMAND_DEPTH=16, PROGRAM_COMMAND_ADDRESS_WIDTH=4, PROGRAM_DMA_DATA_WIDTH=256;
localparam QCTL_QUEUE_COUNT=220;

logic clk_i;
logic rst_ni;
logic program_reset_i,program_cancel_valid_i=0,program_cancel_ready_o;
logic program_reload_ready_o, program_reload_ack_o;
logic program_command_write_valid_i;
logic program_command_write_ready_o;
logic [PROGRAM_COMMAND_ADDRESS_WIDTH-1:0] program_command_write_address_i;
logic [2:0] program_command_write_opcode_i;
logic [63:0] program_command_write_source_address_i;
logic [31:0] program_command_write_byte_count_i;
logic [3:0] program_command_write_target_kind_i;
logic [7:0] program_command_write_global_queue_id_i;
logic [1:0] program_command_write_format_i;
logic [1:0] program_command_write_encoding_mode_i;
logic [16:0] program_command_write_imem_base_address_i;
logic program_command_write_image_first_i;
logic program_command_write_image_last_i;
logic [15:0] program_command_write_expected_word_count_i;
logic [PROGRAM_COMMAND_ADDRESS_WIDTH-1:0] program_command_write_jump_address_i;
logic program_load_start_valid_i;
logic program_load_start_ready_o;
logic [PROGRAM_COMMAND_ADDRESS_WIDTH:0] program_load_start_command_count_i;
logic [63:0] m_axi_araddr_o;
logic [7:0] m_axi_arid_o, m_axi_arlen_o, m_axi_rid_i;
logic [2:0] m_axi_arsize_o;
logic [1:0] m_axi_arburst_o, m_axi_rresp_i;
logic m_axi_arvalid_o, m_axi_arready_i, m_axi_rlast_i, m_axi_rvalid_i, m_axi_rready_o;
logic [PROGRAM_DMA_DATA_WIDTH-1:0] m_axi_rdata_i;
logic program_start_request_i;
logic program_dependencies_ready_i;
logic program_start_ack_o;
logic program_load_complete_o;
logic program_ready_o;
logic program_running_o;
logic program_done_o;
logic program_fault_o;
logic [5:0] program_fault_code_o;
logic [31:0] program_schedule_cycle_o;
logic qctl_load_mode_i;
logic qctl_partition_valid_i;
logic qctl_partition_ready_o;
logic [$clog2(QCTL_QUEUE_COUNT)-1:0] qctl_partition_queue_i;
logic [8:0] qctl_partition_base_i;
logic [4:0] qctl_partition_count_i;
logic [63:0] qctl_partition_generation_i;
logic qctl_load_valid_i;
logic qctl_load_ready_o;
logic [8:0] qctl_load_address_i;
logic [95:0] qctl_load_data_i;
logic qctl_event_valid_i;
	logic qctl_event_ready_o;
	logic [31:0] qctl_event_tag_i;
	logic [QCTL_QUEUE_COUNT-1:0] qctl_event_mask_i;
	logic [64-1:0] qctl_event_generation_i;
	logic qctl_event_phase_i;
	logic qctl_receipt_valid_o;
	logic qctl_receipt_ready_i;
	logic [31:0] qctl_receipt_tag_o;
	logic [64-1:0] qctl_receipt_generation_o;
	logic [63:0] qctl_receipt_cycle_o;
logic [QCTL_QUEUE_COUNT-1:0] qctl_sync_valid_i;
logic [QCTL_QUEUE_COUNT-1:0] qctl_sync_ready_o;
logic [QCTL_QUEUE_COUNT-1:0] qctl_notify_valid_o;
logic [QCTL_QUEUE_COUNT-1:0] qctl_notify_ready_i;
logic [QCTL_QUEUE_COUNT-1:0] qctl_mem_packet_valid_o;
logic [QCTL_QUEUE_COUNT*32-1:0] qctl_mem_packet_ordinal_o;
logic [QCTL_QUEUE_COUNT-1:0] qctl_mem_packet_retired_i;
logic [QCTL_QUEUE_COUNT-1:0] qctl_queue_active_o;
logic [QCTL_QUEUE_COUNT-1:0] qctl_wait_event_blocked_o;
logic [QCTL_QUEUE_COUNT*32-1:0] qctl_wait_event_tag_o;
logic [QCTL_QUEUE_COUNT-1:0] qctl_primed_o;
logic [QCTL_QUEUE_COUNT-1:0] qctl_done_o;
logic qctl_fault_o;
logic [7:0] qctl_fault_code_o;
logic [2*4*32-1:0] mem_east_edge_valid_i;
logic [2*4*32*64-1:0] mem_east_edge_data_i;
logic [2*4*32-1:0] mem_east_edge_valid_o;
logic [2*4*32*64-1:0] mem_east_edge_data_o;
logic [2*4*32-1:0] mem_west_edge_valid_i;
logic [2*4*32*64-1:0] mem_west_edge_data_i;
logic [2*4*32-1:0] mem_west_edge_valid_o;
logic [2*4*32*64-1:0] mem_west_edge_data_o;
logic [lpu_pkg::MEM_BANK_COUNT-1:0] mem_fault_o;
logic [1:0] mxm_fault_o;
logic [1:0] sxm_fault_o;
logic vxm_fault_o;
logic [1:0] stream_conflict_o;
lpu_top #(
.ENABLE_QCTL(PHASE_TEST), .PROGRAM_COMMAND_DEPTH(16), .PROGRAM_MEM_IMEM_DEPTH(16),
.PROGRAM_MXM_IMEM_DEPTH(16), .MEM_DEPTH_ROWS(32), .ACTIVE_MEM_COLUMNS(4),
.ENABLE_SXM_VXM_EXECUTION(1'b0), .PROGRAM_ACTIVE_CONTEXTS(2),
.MXM_ACCUMULATOR_BLOCK_COUNT(1)
) dut (.dma_page_last_i(1'b0),.dma_page_event_tag_i('0),.dma_page_generation_i('0),.dma_page_mask_i('0),.dma_desc_valid_i(1'b0),.dma_desc_ready_o(),.dma_store_i(1'b0),.dma_hem_i(1'b0),
 .dma_bank_i('0),.dma_lane_i('0),.dma_row_i('0),.dma_addr_i('0),.dma_count_i('0),.dma_stride_i('0),.dma_tag_i('0),
 .dma_busy_o(),.dma_result_valid_o(),.dma_result_error_o(),.dma_result_ready_i(1'b1),.dma_result_tag_o(),.dma_isolated_o(),
 .m_axi_awaddr_o(),.m_axi_awid_o(),.m_axi_awlen_o(),.m_axi_awsize_o(),.m_axi_awburst_o(),
 .m_axi_awvalid_o(),.m_axi_awready_i(1'b0),.m_axi_wvalid_o(),.m_axi_wready_i(1'b0),
 .m_axi_wlast_o(),.m_axi_wdata_o(),.m_axi_wstrb_o(),.m_axi_bid_i('0),.m_axi_bvalid_i(1'b0),.m_axi_bresp_i('0),.m_axi_bready_o(),.*);
initial clk_i=0; always #5 clk_i=~clk_i;

logic [383:0] image0,image1;
// One independently encoded extended macro per bank. The two images exercise
// both native hop modes; no preloaded ICU instructions or FU stubs are used.
function automatic logic [383:0] mem_image(input logic [31:0] native_word);
 logic [287:0] payload;
 payload='0;payload[3+:32]=5;payload[35+:13]=native_word[27:15];
 payload[49]=1;payload[50+:32]=native_word;
 payload[82+:32]=1;payload[114+:32]=1;
 payload[178+:32]=1;payload[210+:32]=1;payload[274+:2]=1;
 return {payload,96'h17};
endfunction
localparam integer A0='hff5, A1='h2013, AX='h3000;
integer cycles=0,seen0=0,seen1=0,page=0,ar_count=0;
integer issue_last=0, done_at=0;
logic [31:0] retired_cycle;
integer mode=0,phase_edge=-1;localparam MQ=lpu_pkg::MEM_BANK_COUNT+8;
always @(posedge clk_i)if(rst_ni && PHASE_TEST && (qctl_wait_event_blocked_o[0] || qctl_wait_event_blocked_o[MQ]))begin
 if(dut.u_fu_subsystems.qctl_scheduler_enable[0] && qctl_wait_event_blocked_o[0])begin
   if(!qctl_wait_event_blocked_o[MQ]||!dut.u_fu_subsystems.qctl_scheduler_enable[MQ])$fatal(1,"half phase");
   // $time is independent of simulator ordering between posedge monitors.
   phase_edge=$time/10;
 end
end
task automatic setup_phase(input int gen);
 qctl_load_mode_i=1;
 for(int q=0;q<2;q++)begin
   @(negedge clk_i);qctl_partition_queue_i=q?MQ:0;qctl_partition_base_i=q;qctl_partition_count_i=1;qctl_partition_generation_i=gen;qctl_partition_valid_i=1;
   do @(posedge clk_i);while(!qctl_partition_ready_o);@(negedge clk_i);qctl_partition_valid_i=0;
   qctl_load_address_i=q;qctl_load_data_i=lpu_qctl_pkg::qctl_pack_record(q?2:0,lpu_qctl_pkg::QCTL_OPCODE_WAIT_EVENT,63);qctl_load_valid_i=1;
   do @(posedge clk_i);while(!qctl_load_ready_o);@(negedge clk_i);qctl_load_valid_i=0;
 end
 qctl_load_mode_i=0;phase_edge=-1;
endtask
task automatic phase_event(input int gen);
 @(negedge clk_i);qctl_event_mask_i='0;qctl_event_mask_i[0]=1;qctl_event_mask_i[MQ]=1;qctl_event_generation_i=gen;qctl_event_tag_i=63;qctl_event_phase_i=1;qctl_event_valid_i=1;
 do @(posedge clk_i);while(!qctl_event_ready_o);@(negedge clk_i);qctl_event_valid_i=0;
endtask
logic expect_stale_fault=0;
integer mxm_seen=0, mxm_rows=0;
localparam logic [48:0] MXM_RD=49'h0000000002802; // legacy accumulator read, stream 20
localparam integer LONG_CONTEXTS=100;
logic [31:0] native0,native1;
function automatic logic [383:0] mem_long_image(input logic [31:0] word);
  logic [287:0] bits;
  bits='0;
  bits[0+:3]=1;              // one dictionary entry
  bits[3+:22]=12;            // start-cycle delta
  bits[3+36+:32]=1;         // initial cycle 1 exercises prime tail
  bits[3+36+32+:13]=word[27:15];
  bits[84]=1; bits[85+:16]=16'(LONG_CONTEXTS-1); // single run, 100 distinct contexts
  // Read/shape-0 template and all delta symbols (dictionary index 0) are zero.
  return {bits,(96'(LONG_CONTEXTS)<<4)|96'h7};
endfunction
function automatic logic [383:0] mxm_read_image();
  logic [127:0] bits;
  bits='0;
  bits[3+:32]=40; // skip past the initial MEM wavefront
  bits[50+:49]=MXM_RD;
  return {128'd0,bits,128'h17};
endfunction
task automatic ck(input logic ok,input string s);if(!ok)$fatal(1,"%s phy=%0d sched=%0d fault=%0d",s,cycles,program_schedule_cycle_o,program_fault_code_o);endtask
always @(posedge clk_i)if(rst_ni)begin
 cycles++;
 if(cycles>5000)$fatal(1,"system timeout");
 if(!expect_stale_fault) ck(!program_fault_o,"program fault");
 else ck(!m_axi_arvalid_o,"old command escaped re-arm");
 if(dut.local_mem_issue_valid[0])begin
   ck((PHASE_TEST ? ($time/10-phase_edge) : program_schedule_cycle_o)==((mode==1 && page==0)?1+seen0*12:5) &&
      dut.local_mem_issue_instruction[0+:32]==native0,"bank0 issue");
   seen0++;issue_last=cycles;
 end
 if(dut.local_mem_issue_valid[1])begin ck(program_schedule_cycle_o==5&&dut.local_mem_issue_instruction[32+:32]==native1,"bank1 issue");seen1++;issue_last=cycles;end
 if(dut.local_mxm_compute_issue_valid[0]) begin
   ck((PHASE_TEST ? ($time/10-phase_edge+2) : program_schedule_cycle_o)==40 && dut.local_mxm_compute_issue_instruction[0+:49]==MXM_RD,"MXM compute queue issue");
   mxm_seen++;issue_last=cycles;
 end
 if (|dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].u_mxm_subsystem.u_execution.accumulator_produced_valid) begin
   ck(dut.u_fu_subsystems.gen_hemisphere[0].gen_mxm[0].u_mxm_subsystem.u_execution.accumulator_produced_data=='0,
      "legacy accumulator reset readback");
   mxm_rows++;
 end
 if(program_done_o && done_at==0) begin
    done_at=cycles;
    ck(dut.endpoint_execution_drained && dut.endpoint_frontends_idle && issue_last!=0 && cycles>issue_last+3,"DONE before execution and SR drain");
 end
end
task automatic cmd(input integer ix,op,q,addr,bytes,words,
                   input logic [3:0] target=PROGRAM_TARGET_MEM,
                   input logic [1:0] fmt=PROGRAM_FORMAT_96);
 @(negedge clk_i);program_command_write_valid_i=1;program_command_write_address_i=4'(ix);program_command_write_opcode_i=3'(op);
 program_command_write_global_queue_id_i=8'(q);program_command_write_source_address_i=64'(addr);program_command_write_byte_count_i=32'(bytes);
 program_command_write_target_kind_i=target;program_command_write_format_i=fmt;
 program_command_write_image_first_i=1;program_command_write_image_last_i=1;program_command_write_expected_word_count_i=16'(words);
 do @(posedge clk_i);while(!program_command_write_ready_o);
 @(negedge clk_i);program_command_write_valid_i=0;
endtask
task automatic respond(input integer addr,input logic [383:0] img,input integer length=48);
 for (integer aligned=(addr/32)*32; aligned<addr+length; aligned+=32) begin
   logic [7:0] id;
   while(!m_axi_arvalid_o) @(negedge clk_i);
   id=m_axi_arid_o;
   repeat(3) begin
     ck(m_axi_arvalid_o && m_axi_araddr_o==64'(aligned) && m_axi_arid_o==id &&
        m_axi_arlen_o==0 && m_axi_arsize_o==5 && m_axi_arburst_o==1,"AXI AR shape/stability");
     @(negedge clk_i);
   end
   m_axi_arready_i=1;
   @(posedge clk_i); @(negedge clk_i);m_axi_arready_i=0;ar_count++;
   repeat(5) @(negedge clk_i);
   for(integer b=0;b<32;b++)
     m_axi_rdata_i[b*8+:8]=(aligned+b>=addr && aligned+b<addr+length)
                          ? img[(aligned+b-addr)*8+:8] : 8'hd5;
   m_axi_rid_i=id;m_axi_rresp_i=0;m_axi_rlast_i=1;m_axi_rvalid_i=1;
   do @(posedge clk_i);while(!m_axi_rready_o);
   @(negedge clk_i);m_axi_rvalid_i=0;
 end
endtask
initial begin
rst_ni='0;
program_reset_i='0;
program_command_write_valid_i='0;
program_command_write_address_i='0;
program_command_write_opcode_i='0;
program_command_write_source_address_i='0;
program_command_write_byte_count_i='0;
program_command_write_target_kind_i='0;
program_command_write_global_queue_id_i='0;
program_command_write_format_i='0;
program_command_write_encoding_mode_i='0;
program_command_write_imem_base_address_i='0;
program_command_write_image_first_i='0;
program_command_write_image_last_i='0;
program_command_write_expected_word_count_i='0;
program_command_write_jump_address_i='0;
program_load_start_valid_i='0;
program_load_start_command_count_i='0;
m_axi_arready_i='0;
m_axi_rvalid_i='0;
m_axi_rdata_i='0;
m_axi_rlast_i='0;
m_axi_rid_i='0;
m_axi_rresp_i='0;
program_start_request_i='0;
program_dependencies_ready_i='0;
qctl_load_mode_i='0;
qctl_partition_valid_i='0;
qctl_partition_queue_i='0;
qctl_partition_base_i='0;
qctl_partition_count_i='0;
qctl_partition_generation_i='0;
qctl_load_valid_i='0;
qctl_load_address_i='0;
qctl_load_data_i='0;
qctl_event_valid_i='0;qctl_event_mask_i='0;qctl_event_generation_i=0;qctl_event_phase_i=0;qctl_receipt_ready_i=1;
qctl_event_tag_i='0;
qctl_sync_valid_i='0;
qctl_notify_ready_i='0;
qctl_mem_packet_retired_i='0;
mem_east_edge_valid_i='0;
mem_east_edge_data_i='0;
mem_west_edge_valid_i='0;
mem_west_edge_data_i='0;
 repeat(4)@(negedge clk_i);rst_ni=1;
 if ($value$plusargs("CASE=%d",mode)) begin end
 for(page=0;page<3;page++) begin
   if(PHASE_TEST)setup_phase(100+page);
   native0=32'((3+page)<<15);
   native1=32'h40000008 | 32'((4+page)<<15);
   image0=(mode==1&&page==0)?mem_long_image(native0):mem_image(native0); image1=mem_image(native1);
   program_dependencies_ready_i=0;issue_last=0;done_at=0;
   cmd(0,PROGRAM_LOADER_LOAD_IMEM,0,A0,48,4);
   cmd(1,PROGRAM_LOADER_WAIT_DMA,0,0,0,0);
   cmd(2,PROGRAM_LOADER_COMMIT_QUEUE,0,0,0,0);
   cmd(3,PROGRAM_LOADER_LOAD_IMEM,1,A1,48,4);
   cmd(4,PROGRAM_LOADER_WAIT_DMA,1,0,0,0);
   cmd(5,PROGRAM_LOADER_COMMIT_QUEUE,1,0,0,0);
   cmd(6,PROGRAM_LOADER_LOAD_IMEM,0,AX,32,2,PROGRAM_TARGET_MXM_COMPUTE,PROGRAM_FORMAT_128);
   cmd(7,PROGRAM_LOADER_WAIT_DMA,0,0,0,0,PROGRAM_TARGET_MXM_COMPUTE,PROGRAM_FORMAT_128);
   cmd(8,PROGRAM_LOADER_COMMIT_QUEUE,0,0,0,0,PROGRAM_TARGET_MXM_COMPUTE,PROGRAM_FORMAT_128);
   cmd(9,PROGRAM_LOADER_END,0,0,0,0);
   @(negedge clk_i);program_start_request_i=1;program_load_start_valid_i=1;program_load_start_command_count_i=10;
   do @(posedge clk_i);while(!program_load_start_ready_o);
   @(negedge clk_i);program_load_start_valid_i=0;program_start_request_i=0;
   respond(A0,image0);respond(A1,image1);respond(AX,mxm_read_image(),32);
   while(!program_ready_o) @(negedge clk_i);repeat(8)@(negedge clk_i);
   ck(!program_running_o&&program_schedule_cycle_o==0,"dependency gate");
   program_dependencies_ready_i=1;
   while(!program_running_o) @(negedge clk_i);
   if(PHASE_TEST)begin
     while(!qctl_wait_event_blocked_o[0])@(negedge clk_i);
     phase_event(99+page);repeat(6)@(negedge clk_i);
     ck(phase_edge<0 && qctl_wait_event_blocked_o[MQ] && seen1==page+1,"old gen or unrelated MEM bank did not progress");
     qctl_receipt_ready_i=0;phase_event(100+page);while(!qctl_receipt_valid_o)@(negedge clk_i);
     ck(phase_edge>=0 && qctl_receipt_generation_o==100+page && qctl_receipt_tag_o==63,"missing phase receipt");
     qctl_receipt_ready_i=1;
   end
   if (mode==1 && page==0)
     ck(!dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.gen_bank_frontend[0].u_frontend.decoder_done,
        "long image unexpectedly fully decoded at START");
   ck(program_reload_ready_o && !program_done_o,"early reload must be accepted as a request");
   if (page<2) begin
     program_reset_i=1;
     @(posedge clk_i);@(negedge clk_i);program_reset_i=0;
     while(!program_reload_ack_o) begin
       ck(!program_command_write_ready_o && !program_load_start_ready_o,"active image overwrite admission");
       @(negedge clk_i);
     end
     ck(program_done_o && dut.endpoint_execution_drained && done_at!=0,"reload before physical drain");
     @(posedge clk_i);@(negedge clk_i);
     ck(!program_running_o && !program_done_o && program_schedule_cycle_o==0,"retired scheduler state");
   end else while (!program_done_o) @(negedge clk_i);
   ck(seen0==page+((mode==1)?LONG_CONTEXTS:1)&&seen1==page+1,"no duplicate/missing issues");
   ck(mxm_seen==page+1 && mxm_rows==4*(page+1),"legacy MXM execution did not retire all rows");
   ck(mem_fault_o=='0,"native MEM fault");
 end
 ck(ar_count==21,"fresh DDR reads on every generation");
 retired_cycle=program_schedule_cycle_o;
 repeat(6)@(negedge clk_i);
 ck(program_schedule_cycle_o==retired_cycle && !program_running_o,"retired timebase kept advancing");
 if (mode==2) begin
   program_reset_i=1;
   @(posedge clk_i);@(negedge clk_i);program_reset_i=0;
   while(!program_reload_ack_o) @(negedge clk_i);
   @(posedge clk_i);@(negedge clk_i);
   ck(program_load_start_ready_o,"new generation did not re-arm");
   // Do not rewrite descriptor 0, despite old bytes remaining in RAM.
   expect_stale_fault=1;
   program_load_start_command_count_i=1;program_load_start_valid_i=1;
   @(posedge clk_i);@(negedge clk_i);program_load_start_valid_i=0;
   repeat(6)@(negedge clk_i);
   ck(program_fault_o && program_fault_code_o==PROGRAM_FAULT_COMMAND &&
      !program_start_ack_o,"stale descriptor not rejected");
 end
 $display("PASS AXI DDR -> iMEM -> MEM/MXM, 3 segments, %0d AR, MEM %0d+%0d issues, MXM %0d rows, mode=%0d",
          ar_count,seen0,seen1,mxm_rows,mode);$finish;
end
endmodule

