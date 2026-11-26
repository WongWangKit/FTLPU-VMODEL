`timescale 1ns/1ps
module native_chain_tb #(parameter integer PROBE_BYTES=32,parameter bit TAP_TEST=0,parameter bit PROBE_PRODUCT_GEOMETRY=0,parameter bit PRODUCT_RUN=0);
import lpu_program_load_pkg::*;

localparam PROGRAM_COMMAND_DEPTH=32, PROGRAM_COMMAND_ADDRESS_WIDTH=5, PROGRAM_DMA_DATA_WIDTH=8*PROBE_BYTES;
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
bit input_valid;wire input_ready,input_result,input_err;wire [31:0] input_result_tag;
logic [31:0] input_tag=0,input_count=0;logic input_hem=0;logic [6:0] input_bank=0;
logic [2:0] input_lane=0;logic [14:0] input_row=0;logic [63:0] input_addr=0;
lpu_top #(
.T(PROBE_BYTES/8),.PRODUCT_PROFILE(PRODUCT_RUN),.ENABLE_QCTL(PRODUCT_RUN), .PROGRAM_COMMAND_DEPTH(32),
.PROGRAM_MEM_IMEM_DEPTH(PROBE_PRODUCT_GEOMETRY?lpu_pkg::dma_mixed_mem_imem_depth(PROBE_BYTES):16),
.PROGRAM_MXM_IMEM_DEPTH(PROBE_PRODUCT_GEOMETRY?lpu_pkg::dma_mixed_mxm_imem_depth(PROBE_BYTES):16),
.MEM_DEPTH_ROWS(PROBE_PRODUCT_GEOMETRY?0:32), .ACTIVE_MEM_COLUMNS(PROBE_PRODUCT_GEOMETRY?52:(TAP_TEST?16:4)),
.ENABLE_SXM_VXM_EXECUTION(1'b1), .PROGRAM_ACTIVE_CONTEXTS(PRODUCT_RUN?4:2),
.MXM_ACCUMULATOR_BLOCK_COUNT(PRODUCT_RUN?lpu_pkg::MXM_ACCUMULATOR_BLOCK_COUNT:1)
) dut (.dma_page_last_i(1'b0),.dma_page_event_tag_i('0),.dma_page_generation_i('0),.dma_page_mask_i('0),.dma_desc_valid_i(input_valid),.dma_desc_ready_o(input_ready),.dma_store_i(1'b0),.dma_hem_i(input_hem),
 .dma_indexed_i(1'b0),.dma_index_addr_i('0),.dma_row_limit_i('0),
 .expert_clear_i(1'b0),.expert_word_valid_i(1'b0),.expert_word_i('0),.expert_count_i('0),
 .expert_segment_count_i('0),.expert_config_ready_o(),.expert_valid_i(1'b0),.expert_ready_o(),
 .expert_id_i('0),.expert_bank_xor_i(1'b0),.expert_stream_mask_i('0),
 .expert_done_o(),.expert_error_o(),.expert_done_ready_i(1'b0),
 .dma_bank_i(input_bank),.dma_lane_i(input_lane),.dma_row_i(input_row),.dma_addr_i(input_addr),.dma_count_i(input_count),.dma_stride_i(32'(PROBE_BYTES)),.dma_tag_i(input_tag),
 .dma_busy_o(),.dma_result_valid_o(input_result),.dma_result_error_o(input_err),.dma_result_ready_i(1'b1),.dma_result_tag_o(input_result_tag),.dma_isolated_o(),
 .dma_bg_load_i('0),.dma_bg_cancel_i('0),.dma_bg_command_i('0),.dma_bg_epoch_i(PRODUCT_RUN?64'd1:64'd0),.dma_bg_bank_mask_i('0),
 .dma_bg_reject_o(),.dma_bg_cycle_o(),.dma_bg_image_o(),.dma_bg_wave_valid_o(),.dma_bg_wave_fire_o(),.dma_bg_resident_o(),
 .dma_bg_retire_i('0),.dma_bg_retire_slot_i('0),.dma_bg_retire_page_i('0),.dma_bg_retire_epoch_i('0),.dma_bg_retire_ready_o(),
 .dma_start_needs_page_i('0),.dma_start_slot_i('0),.dma_start_generation_i('0),.dma_start_page_i('0),.m_axi_awaddr_o(),.m_axi_awid_o(),.m_axi_awlen_o(),.m_axi_awsize_o(),.m_axi_awburst_o(),
 .m_axi_awvalid_o(),.m_axi_awready_i(1'b0),.m_axi_wvalid_o(),.m_axi_wready_i(1'b0),
 .m_axi_wlast_o(),.m_axi_wdata_o(),.m_axi_wstrb_o(),.m_axi_bid_i('0),.m_axi_bvalid_i(1'b0),.m_axi_bresp_i('0),.m_axi_bready_o(),.*);
initial clk_i=0; always #5 clk_i=~clk_i;


localparam P=24,L=32,C=80,B=C+23,CAP=B+7,PO=120,RUN=130;
logic [255:0] ddr[0:1023]; integer n[12];integer ix=0;
// Optional admission-only diagnostic: feed an actual compiler queue unchanged
// through the product AXI reader. Never START with a partial workload.
bit file_probe=0;integer image_kind,image_q,image_bytes,image_word,image_mode,file_ar=0;
bit vector_probe=0; integer image_base=0, raw_issues=0,raw_inputs=0,raw_outputs=0,raw_edges=0;
localparam RAW_ISSUE_CYCLE=PROBE_PRODUCT_GEOMETRY?12:0;
bit bad_vector=0;
logic [15:0] vector_in[64],vector_gold[64];
logic [255:0] external_ddr[0:65535];
task automatic event_at(input int k,cy,input logic [127:0] payload,input logic [31:0] aux=0);
 ddr[k*64+n[k]]={64'b0,aux,32'(cy),payload};n[k]++;
endtask
bit macro_test;bit tap_fp32,tap_drop;
function automatic [31:0] test_value(input int row,col);
 return 32'h56781200+32'(row*32+col)*259;
endfunction
function automatic [255:0] macro_beat(input int k);
 int kind,pos,nb; logic [127:0] bits;
 kind=k==7?0:k==8?3:k==9?2:k==10?1:4;
 nb=lpu_mxm_isa_pkg::macro_native_bits(kind);
 bits=128'(ddr[k*64][159:128])<<3; // empty dictionary, absolute cycle, operand 0
 pos=3+32+lpu_mxm_isa_pkg::macro_operand_bits(kind)+2; // single run, compact template
 bits|=128'(ddr[k*64][127:0])<<pos;
 if(n[k]>1)begin bits|=128'(1)<<(pos+nb);bits|=128'(n[k]-1)<<(pos+nb+4);end
 if(k==9 && $test$plusargs("STREAM_MXM"))begin
   // Four contexts of eight consecutive issues. Two fit before START.
   // Dictionary[0] advances the absolute start by eight, leaving the operand fixed.
   bits=128'd1 | (128'd8<<3) | (128'(L)<<39) | (128'd1<<72) | (128'd3<<73) | (128'd1<<91) | (128'd7<<95);
   return {bits,128'h45};
 end
 return {bits,128'h15};
endfunction
task automatic cmd(input int op,k);
 @(negedge clk_i);program_command_write_valid_i=1;program_command_write_address_i=5'(ix++);program_command_write_opcode_i=3'(op);
 program_command_write_source_address_i=64'(k*2048);program_command_write_byte_count_i=32*n[k];
 program_command_write_target_kind_i=4'(k);program_command_write_format_i=PROGRAM_FORMAT_128;
 program_command_write_image_first_i=1;program_command_write_image_last_i=1;program_command_write_expected_word_count_i=2*n[k];
 if(macro_test && k>=7)begin
   program_command_write_target_kind_i=k==7?1:k==8?7:k==9?2:k==10?3:8;
   program_command_write_encoding_mode_i=0;
   program_command_write_byte_count_i=32;program_command_write_expected_word_count_i=2;
 end else program_command_write_encoding_mode_i=1;
 if(file_probe)begin
   program_command_write_source_address_i=image_base;program_command_write_target_kind_i=image_kind;
   program_command_write_global_queue_id_i=image_q;program_command_write_byte_count_i=image_bytes;
   program_command_write_format_i=image_word==12?PROGRAM_FORMAT_96:PROGRAM_FORMAT_128;
   program_command_write_encoding_mode_i=$test$plusargs("MAP_NATIVE_MODE") && image_mode==0 ?
       PROGRAM_ENCODING_NATIVE : image_mode;
   program_command_write_expected_word_count_i=image_bytes/image_word;
 end
 do @(posedge clk_i);while(!program_command_write_ready_o);
 @(negedge clk_i);program_command_write_valid_i=0;
endtask
bit afire,rfire;logic [63:0] araddr;logic [7:0] arlen,arid;
integer addr=0,beats=0;
integer results=0;
always @(negedge clk_i)if(rst_ni)begin
 if(m_axi_rvalid_i && rfire)begin beats--;addr++;m_axi_rvalid_i=0;end
 if(afire)begin addr=int'(araddr/PROBE_BYTES);beats=arlen+1;m_axi_rid_i=arid;if(file_probe)file_ar++;end
 m_axi_arready_i=(beats==0);
 if(beats>0)begin m_axi_rvalid_i=1;m_axi_rlast_i=beats==1;m_axi_rdata_i=file_probe?
   (external_ddr[addr/(32/PROBE_BYTES)] >> ((addr%(32/PROBE_BYTES))*8*PROBE_BYTES)):(macro_test && addr/64>=7?macro_beat(addr/64):ddr[addr]);end
end

always @(posedge clk_i)begin afire=m_axi_arvalid_o&&m_axi_arready_i;rfire=m_axi_rvalid_i&&m_axi_rready_o;
 araddr=m_axi_araddr_o;arlen=m_axi_arlen_o;arid=m_axi_arid_o;end
logic [127:0] w; lpu_pkg::vxm_global_config_t vf;
initial begin
 for(int k=0;k<12;k++)n[k]=0;
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
program_command_write_encoding_mode_i=1;
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
 if($test$plusargs("PRODUCT_IMAGE"))begin
   integer f,total,beats32,op,nread,accepted; bit submitted;
   if(!PRODUCT_RUN || !PROBE_PRODUCT_GEOMETRY)$fatal(1,"use the product configuration");
   file_probe=1; accepted=0;submitted=0;
   f=$fopen("work.cfg","r");
   if(!f || $fscanf(f,"%d%d",total,beats32)!=2 || total%32 || beats32<1 || beats32>65536)
     $fatal(1,"invalid workload header");
   $readmemh("work.hex",external_ddr,0,beats32-1);
   $display("PRODUCT T=%0d P=%0d RT=%0d Q=%0d MEM=%0d MXM=%0d VXM=%0d QCTL=%0d BG=%0d NATIVE=%0d commands=%0d",dut.T,dut.PROGRAM_DMA_RX_FIFO_DEPTH,dut.DMA_RT,dut.DMA_Q,dut.PROGRAM_MEM_IMEM_DEPTH,dut.PROGRAM_MXM_IMEM_DEPTH,dut.PROGRAM_VXM_IMEM_DEPTH,dut.ENABLE_QCTL,dut.ENABLE_STATIC_WEIGHTS,!dut.LEGACY_MXM,total);
   for(int i=0;i<total;i++)begin
     nread=$fscanf(f,"%d%d%d%d%d%d%d",op,image_kind,image_q,image_bytes,image_word,image_mode,image_base);
     if(nread!=7)$fatal(1,"truncated workload at %0d",i);
     cmd(op,0);accepted++;
     if(accepted==32 && !submitted)begin
       @(negedge clk_i);program_load_start_valid_i=1;program_load_start_command_count_i=32;
       for(int w=0;!program_load_start_ready_o;w++)begin
         if(w>=32)$fatal(1,"program bind: allowed=%b calendar_ready=%b drained=%b",dut.load_permitted,dut.sc_bind_ready,dut.endpoint_execution_drained);
         @(negedge clk_i);
       end
       @(posedge clk_i);
       @(negedge clk_i);program_load_start_valid_i=0;submitted=1;
     end
   end
   $fclose(f);wait(program_ready_o);
   if($test$plusargs("GRAPH_INPUTS"))begin
     int fd,fields;
     $readmemh("inputs.hex",external_ddr,32768);
     fd=$fopen("inputs.cfg","r");if(!fd)$fatal(1,"missing program inputs");
     fields=$fscanf(fd,"%d%d%d%d%d%d",input_hem,input_bank,input_lane,input_row,input_addr,input_count);
     while(fields==6)begin
       @(negedge clk_i);input_tag++;input_valid=1;
       do @(posedge clk_i);while(!input_ready);
       @(negedge clk_i);input_valid=0;
       do @(posedge clk_i);while(!input_result);
       if(input_err || input_result_tag!==input_tag)$fatal(1,"input DMA %0d",input_tag);
       @(negedge clk_i);
       fields=$fscanf(fd,"%d%d%d%d%d%d",input_hem,input_bank,input_lane,input_row,input_addr,input_count);
     end
     if(!$feof(fd) || !input_tag)$fatal(1,"invalid input file");
     $fclose(fd);$display("PRODUCT input LOAD complete descriptors=%0d",input_tag);
   end
   @(negedge clk_i);program_dependencies_ready_i=1;program_start_request_i=1;
   do @(posedge clk_i);while(!program_start_ack_o);
   $display("PRODUCT START ar=%0d",file_ar);
   @(negedge clk_i);program_start_request_i=0;
   wait(program_done_o);
   $display("PRODUCT frontend DONE (not a numerical pass)");$finish;
 end
 if($test$plusargs("VXM_VECTOR"))begin
   int f; vector_probe=1; file_probe=1;
   $readmemh("queues.hex",external_ddr,0,1);
   bad_vector=$test$plusargs("BAD_VECTOR");
   // Negative fixture: request an unsupported operand; retain the good image on disk.
   if(bad_vector)external_ddr[0][(PROBE_PRODUCT_GEOMETRY?96:0)+6]=1;
   $readmemh("input.hex",vector_in);$readmemh("gold.hex",vector_gold);
   f=$fopen("queues.cfg","r");
   for(int q=0;q<2;q++)begin
     if(!f || $fscanf(f,"%d%d%d%d%d%d",image_kind,image_q,image_bytes,image_word,image_mode,image_base)!=6 ||
        image_kind!=4 || image_q!=q || image_bytes!=(PROBE_PRODUCT_GEOMETRY?24:12) || image_word!=12 || image_mode!=0 || image_base!=q*32)
       $fatal(1,"expected two compiler queue descriptors");
     cmd(PROGRAM_LOADER_LOAD_IMEM,4);cmd(PROGRAM_LOADER_WAIT_DMA,4);cmd(PROGRAM_LOADER_COMMIT_QUEUE,4);
   end
   $fclose(f);cmd(PROGRAM_LOADER_END,0);
   @(negedge clk_i);program_load_start_valid_i=1;program_load_start_command_count_i=ix;
   do @(posedge clk_i);while(!program_load_start_ready_o);
   @(negedge clk_i);program_load_start_valid_i=0;wait(program_ready_o);
   @(negedge clk_i);program_dependencies_ready_i=1;program_start_request_i=1;
   wait(program_start_ack_o);@(negedge clk_i);program_start_request_i=0;
   wait(program_done_o);@(negedge clk_i);
   if(raw_issues!=1 || raw_inputs!=4 || raw_outputs!=4 || raw_edges!=4)$fatal(1,"incomplete VXM trace");
   $display("PASS compiler FP16 vector: 2 queues, 4 tile inputs, 64 FP16 results at VXM and at top SRF");$finish;
 end
 if($test$plusargs("REMOTE_QUEUE"))begin
   int f;file_probe=1;f=$fopen("queue.cfg","r");
   if(!f || $fscanf(f,"%d%d%d%d%d",image_kind,image_q,image_bytes,image_word,image_mode)!=5)
     $fatal(1,"missing compiler image descriptor");
   $fclose(f);
   if(image_kind!=4 || !(image_word inside {12,16}) || image_bytes<=0 ||
      image_bytes%image_word || image_bytes/image_word>65535 || image_bytes>2097152)$fatal(1,"probe capacity");
   $readmemh("queue.hex",external_ddr,0,(image_bytes+31)/32-1);
   cmd(PROGRAM_LOADER_LOAD_IMEM,4);cmd(PROGRAM_LOADER_WAIT_DMA,4);
   cmd(PROGRAM_LOADER_COMMIT_QUEUE,4);cmd(PROGRAM_LOADER_END,0);
   @(negedge clk_i);program_load_start_valid_i=1;program_load_start_command_count_i=ix;
   do @(posedge clk_i);while(!program_load_start_ready_o);
   @(negedge clk_i);program_load_start_valid_i=0;
   wait(file_ar>0 && program_ready_o);
   if(image_word==12 && image_mode==0 && image_q==0)begin
     for(int i=0;i<image_bytes/12;i++)for(int b=0;b<12;b++)
       if(dut.u_fu_subsystems.g_raw[0].g_active.u_queue.u_imem.u_storage.memory_q[i][8*b+:8] !==
          external_ddr[(12*i+b)/32][8*((12*i+b)%32)+:8])$fatal(1,"raw iMEM mismatch word=%0d byte=%0d",i,b);
     $display("PASS raw AXI to local VXM iMEM: %0d words, %0d bytes checked, AR=%0d START=0",image_bytes/12,image_bytes,file_ar);
   end
   $display("ADMITTED remote VXM queue; no partial START");$finish;
 end

 macro_test=$test$plusargs("MACRO_MXM");
 tap_fp32=$test$plusargs("FP32");tap_drop=$test$plusargs("DROP_PLANE");
 if(TAP_TEST)begin
   for(int t=0;t<4;t++)begin w=t+((tap_fp32?3-t:t)<<3);
     for(int l=0;l<8;l++)w[6+3*l+:3]=3'(tap_fp32?(3*l+1)%8:l);
     event_at(5,1+t,w,32'h40);
   end
   event_at(5,6,128'd16+(128'd1<<15)+(128'(tap_fp32)<<31),32'h41);
 end else begin
 event_at(7,L,0);event_at(8,P,0);for(int i=0;i<32;i++)event_at(9,L+i,0);
 event_at(10,C,8);event_at(11,B,4096);
 w=0;w[112]=1;for(int j=0;j<16;j++)w[6*j+:6]=6'(j);event_at(5,1,w,1);
 for(int t=0;t<4;t++)begin
  w=0;w[122:120]=3'(t);for(int j=0;j<16;j++)w[6*j+:6]=6'(j);
  for(int j=0;j<8;j++)w[96+3*j+:3]=3'(7-j);event_at(5,2+t,w,2+8*t);
  // reserve only the source assigned to this destination
 end
 for(int t=0;t<4;t++)event_at(5,6+t,1<<t,3+8*t);
 for(int t=0;t<4;t++)event_at(6,CAP+t,1+(t<<2)+(t<<5));
 for(int t=0;t<4;t++)event_at(6,PO+t,(1<<12)+(t<<14)+(t<<17));
 for(int t=0;t<4;t++)event_at(6,RUN+t,(128'(1)<<(32+t))+(128'(2)<<53)+(128'(1)<<69));
 vf='0;vf.compute_dtype=lpu_pkg::VXM_FORMAT_BF16;vf.lhs_dtype=lpu_pkg::VXM_FORMAT_BF16;
 vf.rhs_dtype=lpu_pkg::VXM_FORMAT_BF16;
 event_at(4,2,128'd3+(128'hbc00<<2)+(128'h3c00<<18),1);
 event_at(4,3,128'd3+(128'd13<<2)+(128'h3123456789abc<<40),2);
 event_at(4,10,(128'(vf)<<65)+(128'(1)<<64));
 event_at(4,RUN,3+(4<<8)); // Q0 negate, Q1 bypass
 end
 for(int k=4;k<=11;k++)if(n[k]>0)begin cmd(PROGRAM_LOADER_LOAD_IMEM,k);cmd(PROGRAM_LOADER_WAIT_DMA,k);cmd(PROGRAM_LOADER_COMMIT_QUEUE,k);end
 cmd(PROGRAM_LOADER_END,0);
 @(negedge clk_i);program_load_start_valid_i=1;program_load_start_command_count_i=ix;
 do @(posedge clk_i);while(!program_load_start_ready_o);
 @(negedge clk_i);program_load_start_valid_i=0;wait(program_ready_o);
 @(negedge clk_i);program_dependencies_ready_i=1;program_start_request_i=1;
 wait(program_start_ack_o);@(negedge clk_i);program_start_request_i=0;
 wait(program_done_o);
 if(TAP_TEST)begin
   if(dut.u_fu_subsystems.gen_hemisphere[0].gen_sxm_execution.u_sxm_subsystem.committed_segments!==(tap_fp32?512:256))
     $fatal(1,"WriteTap completion count");
   @(negedge clk_i);#1;
   $display("PASS top WriteTap: AXI image -> SXM ICU -> transpose -> SRF -> MEM, 1024 elements, %0d byte planes checked",tap_fp32?4:2);$finish;
 end
 @(negedge clk_i);
 if(results!=4)$fatal(1,"missing VXM vectors %d",results);
 if(macro_test)$display("PASS all five packed MXM queues: same issue cycles, SRF values and VXM results as native events");
 $display("PASS native chain: 4 tiles x 8 lanes reached the opposite top-level SRF boundary");$finish;
end
function automatic logic [15:0] bf(input integer val);
 int e;begin e=$clog2(val+1)-1;return 16'(((127+e)<<7)+((val-(1<<e))*128/(1<<e)));end
endfunction
always @(negedge clk_i)begin
 mem_east_edge_valid_i=0;mem_west_edge_valid_i=0;
 if(vector_probe && program_running_o)begin
   for(int t=0;t<4;t++)if(program_schedule_cycle_o==t)for(int h=0;h<2;h++)for(int j=0;j<4;j++)begin
     mem_west_edge_valid_i[t*32+h*16+j]=1;
     for(int l=0;l<8;l++)mem_west_edge_data_i[(t*32+h*16+j)*64+8*l+:8]=vector_in[16*t+8*h+l][8*(j%2)+:8];
   end
 end else if(TAP_TEST && program_running_o)begin
   for(int t=0;t<4;t++)begin
     int row;row=int'(program_schedule_cycle_o)-7-t;
     if(row>=0 && row<32)begin
       for(int b=0;b<(tap_fp32?4:2);b++)begin
         mem_west_edge_valid_i[t*32+b]=!(tap_drop && t==0 && row==0 && b==1);
         for(int l=0;l<8;l++)mem_west_edge_data_i[(t*32+b)*64+8*l+:8]=8'(test_value(row,t*8+l)>>(8*b));
       end
     end
   end
 end else if(program_running_o)for(int t=0;t<4;t++)begin
 int c,j; c=int'(program_schedule_cycle_o);j=c+17-(L+1+3*t);
 if(c+17==P+1+3*t)begin
 mem_east_edge_valid_i[t*32+1+:3]=7;mem_east_edge_data_i[(t*32+1)*64+:192]={64'd0,{8{8'h3f}},{8{8'h80}}};end
 if(j>=0&&j<32)begin mem_east_edge_valid_i[t*32]=1;mem_east_edge_data_i[t*2048+:64]={8{8'(32-j)}};end
 if(c+17==C+1+3*t)begin mem_east_edge_valid_i[t*32+4+:2]=3;mem_east_edge_data_i[(t*32+4)*64+:128]={{8{8'h3f}},{8{8'h80}}};end
 if(c==RUN+t)begin // companion operands for the two physical VXM halves
 for(int j=0;j<32;j++)if(j==2||j==3||(j>=16&&j<=19))mem_west_edge_valid_i[t*32+j]=1;
 end
 end
end
`define H dut.u_fu_subsystems.gen_hemisphere[0]
`define V dut.u_fu_subsystems.gen_vxm_execution.u_vxm_subsystem.u_execution
`define M `H.gen_mxm[0].g_native.u_execution.u_core
// Inspect the RAM after the program drains, independently of the writer's accounting.
if(TAP_TEST)for(genvar g=0;g<4;g++)for(genvar b=0;b<8;b++)for(genvar t=0;t<4;t++)begin:g_check_ram
  wire [63:0] rows[0:5];
  for(genvar r=0;r<6;r++)
    assign rows[r]=`H.u_mem_subsystem.u_native_mem.u_mem.gen_group[3-g].u_group.gen_slice[b/2].u_slice.gen_bank[b%2].u_logical_bank.gen_leaf[t].u_leaf.mem_array[15+r];
  always @(posedge program_done_o)begin
    int bytes,st;logic [63:0] expected;
    bytes=tap_fp32?4:2;st=g*8+b;
    for(int r=0;r<6;r++)begin
      expected=0;
      if(r>=1 && r<=4 && st<8*bytes)for(int l=0;l<8;l++)
        expected[8*l+:8]=8'(test_value(8*(tap_fp32?3-t:t)+(tap_fp32?(3*l+1)%8:l),(r-1)*8+st/bytes)>>(8*(st%bytes)));
      if(rows[r]!==expected)$fatal(1,"MEM WriteTap group=%0d bank=%0d tile=%0d row=%0d got=%h expected=%h",g,b,t,15+r,rows[r],expected);
    end
  end
end
for(genvar t=0;t<PROBE_BYTES/8;t++)for(genvar l=0;l<8;l++)begin:g_check_lut
  always @(posedge program_done_o)if(!TAP_TEST && !file_probe)begin
    if(`V.gen_lut_tile[t].u_tile_lut.g_function[3].g_lane_sram[l].u_sram.coefficient_memory[13]!==50'h3123456789abc ||
       !`V.tile_lut_configured[t*4+3] || `V.tile_lut_input_min[(t*4+3)*16+:16]!==16'hbc00 ||
       `V.tile_lut_segment_width[(t*4+3)*16+:16]!==16'h3c00)$fatal(1,"LUT programming tile=%0d lane=%0d",t,l);
  end
end
// Golden SRF contents, independent of the DUT's interconnect or producer valids.
// bin is the edge on which the corresponding external input was supplied.
for(genvar h=0;h<2;h++)begin:check_hem_srf
 wire [4095:0] valid=dut.u_fu_subsystems.gen_hemisphere[h].u_mem_subsystem.u_native_mem.state_valid_o;
 wire [262143:0] data=dut.u_fu_subsystems.gen_hemisphere[h].u_mem_subsystem.u_native_mem.state_data_o;
 always @(posedge clk_i)if(!TAP_TEST && !file_probe && program_running_o)begin
  int c,idx,bin,shift;logic [31:0] mask; logic [63:0] segment; logic [15:0] value;
  c=int'(program_schedule_cycle_o);
  for(int dir=0;dir<2;dir++)for(int col=0;col<16;col++)for(int t=0;t<4;t++)begin
    idx=((dir*16+col)*4+t)*32;mask='0;bin=c-col-1;
    shift=bin+17-(L+1+3*t);
    if(h==0 && dir==0)begin
      if(bin+17==P+1+3*t)mask=14;
      if(shift>=0 && shift<32)mask=1;
      if(bin+17==C+1+3*t)mask=48;
    end
    if(h==0 && dir==1 && col<=1 && c==RUN+3+t-col)mask=32'hf000f;
    if(h==1 && dir==0 && bin==RUN+8+t)mask=32'h303;
    if(valid[idx+:32]!==mask)$fatal(1,"SRF valid C%0d h%0d dir%0d col%0d tile%0d got %h expected %h",c,h,dir,col,t,valid[idx+:32],mask);
    for(int j=0;j<32;j++)if(mask[j])begin
      segment=0;
      if(h==0 && dir==0)begin
        case(j)
         0:segment={8{8'(32-shift)}};
         1,4:segment={8{8'h80}};
         2,5:segment={8{8'h3f}};
        endcase
      end else for(int l=0;l<8;l++)begin
        value=(j<2)?bf(32*(8*t+8-l)):16'h0000;
        if(h==1)value=value|16'h8000;
        segment[l*8+:8]=j[0]?value[15:8]:value[7:0];
      end
      if(data[(idx+j)*64+:64]!==segment)
        $fatal(1,"SRF data C%0d h%0d dir%0d col%0d tile%0d S%0d got %h expected %h",c,h,dir,col,t,j,data[(idx+j)*64+:64],segment);
    end
  end
 end
end
// Independent timeline: these checks run on every scheduled edge, including idle edges.
integer next_push[5]='{default:0};
always @(posedge clk_i)if(program_running_o || program_start_ack_o)begin
 for(int k=0;k<5;k++)if(dut.u_fu_subsystems.enqueue[0][3+k])begin
   if(next_push[k]>=n[7+k] || dut.u_fu_subsystems.word_q[0][3+k]!==ddr[(7+k)*64+next_push[k]][127:0])
     $fatal(1,"wrong FIFO payload kind=%0d",7+k);
   next_push[k]++;
 end
end
always @(posedge clk_i)if(!TAP_TEST && !file_probe && program_running_o)begin
 int c;logic [12:0] expected_issue;
 c=int'(program_schedule_cycle_o);
 expected_issue='0;
 for(int k=4;k<=11;k++)for(int i=0;i<n[k];i++)if(c==ddr[k*64+i][159:128])begin
   int q;logic [127:0] issued; q=k==4?2:k==5?0:k==6?1:k-4;
   expected_issue[q]=1;
   case(k)
     7:issued=`M.u_frontend.u_control.load_head;
     8:issued=`M.u_frontend.u_dequant_control.param_head;
     9:issued=`M.u_frontend.u_dequant_control.dequant_head;
    10:issued=`M.u_frontend.u_control.compute_head;
    11:issued=`M.u_backend.head;
    default:issued=dut.u_fu_subsystems.word_q[0][q];
   endcase
   if(issued!==ddr[k*64+i][127:0])$fatal(1,"wrong issued command at cycle=%0d target=%0d",c,k);
   $display("issued cycle=%0d target=%0d word=%032h aux=%08h",c,k,issued,ddr[k*64+i][191:160]);
   if(k<=6 && (dut.u_fu_subsystems.word_q[0][q]!==ddr[k*64+i][127:0] ||
                dut.u_fu_subsystems.aux_q[0][q]!==ddr[k*64+i][191:160]))
     $fatal(1,"wrong issue payload cycle=%0d kind=%0d",c,k);
 end
 if(dut.u_fu_subsystems.launch[0]!==expected_issue || dut.u_fu_subsystems.launch[1]!==0)
   $fatal(1,"instruction mask cycle=%0d expected=%h",c,expected_issue);
 $display("cycle=%0d issue=%h mxm=%h sxm=%h srf_to_vxm=%h vxm_out=%h",c,dut.u_fu_subsystems.launch[0],`H.mxm_west_valid,`H.sxm_west_valid,`H.mem_west_valid,`V.produced_valid);
 for(int t=0;t<4;t++)begin
  logic [31:0] mx, sx, sr, vx, input_mask;
  logic [127:0] d;
  mx=c==CAP+t?3:c==RUN+t?32'h000f000c:0;
  sx=c==RUN+1+t?32'h000f000f:0;
  sr=c==RUN+3+t?32'h000f000f:0;
  vx=c==RUN+8+t?32'h303:0;
  if(`H.mxm_west_valid[t*32+:32]!==mx || `H.sxm_west_valid[t*32+:32]!==sx ||
     `H.mem_west_valid[t*32+:32]!==sr || `V.produced_valid[(4+t)*32+:32]!==vx ||
     `V.produced_valid[t*32+:32]!==0 ||
     mem_east_edge_valid_o[(4+t)*32+:32] !== ((c==RUN+25+t)?32'h303:0))
    $fatal(1,"SRF valid mismatch at %0d tile %0d",c,t);
  input_mask=0;
  if(c==P+1+3*t)input_mask=14;
  if(c>=L+1+3*t && c<L+33+3*t)input_mask=1;
  if(c==C+1+3*t)input_mask=48;
  if(`H.sxm_east_valid[t*32+:32]!==input_mask)$fatal(1,"MXM input mask %0d tile %0d",c,t);
  for(int j=0;j<32;j++)if(input_mask[j])begin
    logic [7:0] datum; datum=0;
    case(j)
     0:datum=8'(32-(c-(L+1+3*t)));
     1,4:datum=8'h80;
     2,5:datum=8'h3f;
    endcase
    if(`H.sxm_east_data[(t*32+j)*64+:64]!=={8{datum}})$fatal(1,"MXM input data at %0d",c);
  end
  for(int j=0;j<32;j++)if(sr[j] && j>=2 && `H.mem_west_data[(t*32+j)*64+:64]!==0)
    $fatal(1,"companion VXM input at %0d",c);
  if(c==CAP+t || c==RUN+1+t || c==RUN+3+t || c==RUN+8+t || c==RUN+25+t)begin
    if(c==CAP+t)d=`H.mxm_west_data[t*2048+:128];
    else if(c==RUN+1+t)d=`H.sxm_west_data[t*2048+:128];
    else if(c==RUN+3+t)d=`H.mem_west_data[t*2048+:128];
    else if(c==RUN+8+t)d=`V.produced_data[(4+t)*2048+:128];
    else d=mem_east_edge_data_o[(4+t)*2048+:128];
    $display("data cycle=%0d tile=%0d S01=%016h S00=%016h",c,t,d[127:64],d[63:0]);
    if(c==RUN+25+t)for(int l=0;l<8;l++)
      if({d[64+l*8+:8],d[l*8+:8]}!==(16'h8000|bf(32*(8*t+8-l))))
        $fatal(1,"top output cycle=%0d tile=%0d lane=%0d",c,t,l);
  end
  if(c==CAP+t)for(int l=0;l<8;l++)if({`H.mxm_west_data[(t*32+1)*64+l*8+:8],`H.mxm_west_data[t*2048+l*8+:8]}!==bf(32*(8*t+l+1)))$fatal(1,"MXM at %0d",c);
  if(c==RUN+1+t || c==RUN+3+t)for(int l=0;l<8;l++)begin
   logic [15:0] actual;
   if(c==RUN+1+t)actual={`H.sxm_west_data[(t*32+1)*64+l*8+:8],`H.sxm_west_data[t*2048+l*8+:8]};
   else actual={`H.mem_west_data[(t*32+1)*64+l*8+:8],`H.mem_west_data[t*2048+l*8+:8]};
   if(actual!==bf(32*(8*t+8-l)))$fatal(1,"SXM/SRF at %0d",c);
  end
  if(`V.produced_valid[(4+t)*32])begin
   for(int l=0;l<8;l++)if({`V.produced_data[((4+t)*32+1)*64+l*8+:8],`V.produced_data[(4+t)*2048+l*8+:8]}!==(16'h8000|bf(32*(8*t+8-l))))$fatal(1,"VXM data");
   results++;
  end
 end
end
always @(posedge clk_i)if(rst_ni && (program_fault_o || dut.data_fault))begin
 if(bad_vector && vxm_fault_o && program_fault_o && program_fault_code_o==20 && !raw_issues && !raw_outputs && !program_done_o)begin
   $display("PASS unsupported raw VXM operand rejected before ALU issue/output");$finish;
 end else if(TAP_TEST && tap_drop && sxm_fault_o===2'b01 && program_fault_o && program_fault_code_o==20 &&
    program_schedule_cycle_o==8 && !program_done_o && `H.gen_sxm_execution.u_sxm_subsystem.committed_segments==0)begin
   $display("PASS missing high byte plane at cycle 7: SXM and top fault at cycle 8, zero MEM commits");$finish;
 end else $fatal(1,"fault %0d at %0d: mem=%h mxm=%b sxm=%b vxm=%b clash=%b",program_fault_code_o,program_schedule_cycle_o,mem_fault_o,mxm_fault_o,sxm_fault_o,vxm_fault_o,stream_conflict_o);
end
always @(posedge clk_i) if(file_probe && rst_ni)begin
 if(vector_probe && `V.global_issue_valid_i)begin
   if(`V.global_issue_instruction_i!==0 || !program_start_ack_o)$fatal(1,"unexpected raw global configuration");
   $display("VECTOR global at START: depth=2 FP16 streams, east input / west output");
 end
 if(bad_vector && (|`V.local_issue_valid_i || |`V.produced_valid))$fatal(1,"partial issue for unsupported operand");
 if(vector_probe && !bad_vector && program_running_o)begin
   int c; c=program_schedule_cycle_o;
   if(`V.local_issue_valid_i !== ((c==RAW_ISSUE_CYCLE)?8'h03:8'h00))$fatal(1,"VXM issue at %0d = %h",c,`V.local_issue_valid_i);
   if(c==RAW_ISSUE_CYCLE)begin
     if(`V.local_issue_instruction_i!==56'h4)$fatal(1,"decoded VXM ops");
     raw_issues++;$display("VECTOR issue cycle=%0d mask=03 head=NEG tail=BYPASS",c);
   end
   for(int t=0;t<4;t++)begin
     logic [31:0] sr,vo,edge_mask;
     sr=`H.mem_west_valid[t*32+:32];vo=`V.produced_valid[(4+t)*32+:32];edge_mask=mem_east_edge_valid_o[(4+t)*32+:32];
     if(sr!==((c==RAW_ISSUE_CYCLE+3+t)?32'hf000f:0) || vo!==((c==RAW_ISSUE_CYCLE+8+t)?32'h303:0) ||
        edge_mask!==((c==RAW_ISSUE_CYCLE+25+t)?32'h303:0) || `V.tile_stream_consumed[t*32+:32]!==sr)
       $fatal(1,"VXM timing C%0d tile%0d SRF=%h out=%h edge=%h",c,t,sr,vo,edge_mask);
     if(sr!=0)begin raw_inputs++;$display("VECTOR input cycle=%0d tile=%0d mask=%h",c,t,sr);end
     if(vo!=0)raw_outputs++;
     if(edge_mask!=0)raw_edges++;
     for(int h=0;h<2;h++)for(int l=0;l<8;l++)begin
       logic [15:0] value;int a;a=t*16+h*8+l;
       if(sr!=0)for(int j=0;j<4;j++)
         if(`H.mem_west_data[(t*32+h*16+j)*64+8*l+:8]!==vector_in[a][8*(j%2)+:8])$fatal(1,"SRF input C%0d index%0d",c,a);
       if(vo!=0 || edge_mask!=0)begin
         for(int b=0;b<2;b++)
           value[b*8+:8]=vo!=0?`V.produced_data[((4+t)*32+h*8+b)*64+8*l+:8]:
                               mem_east_edge_data_o[((4+t)*32+h*8+b)*64+8*l+:8];
         if(value!==vector_gold[a])$fatal(1,"CModel mismatch C%0d index%0d got=%h expected=%h",c,a,value,vector_gold[a]);
         $display("VECTOR %s C%0d tile=%0d half=%0d lane=%0d fp16=%h",vo!=0?"vxm":"srf",c,t,h,l,value);
       end
     end
   end
 end
 if(program_command_write_ready_o && program_command_write_valid_i && program_command_write_opcode_i==PROGRAM_LOADER_LOAD_IMEM)
   $display("REMOTE_DESCRIPTOR bytes=%0d word=%0d mode=%0d AR=%0d",image_bytes,image_word,program_command_write_encoding_mode_i,file_ar);
 if(PRODUCT_RUN && dut.u_fu_subsystems.raw_issue!=0)
   $display("PRODUCT raw issue C%0d mask=%h q0=%h",program_schedule_cycle_o,dut.u_fu_subsystems.raw_issue,dut.u_fu_subsystems.raw_word[0]);
 if(PRODUCT_RUN && program_running_o && (|dut.local_mem_issue_valid) && program_schedule_cycle_o<103)
   $display("PRODUCT MEM issue C%0d mask=%h",program_schedule_cycle_o,dut.local_mem_issue_valid);
 if(program_fault_o)
   $display("REMOTE_FAULT code=%0d edge=%0t ar=%0d schedule=%0d",program_fault_code_o,$time,file_ar,program_schedule_cycle_o);
 if(dut.u_fu_subsystems.g_native_sched[0].g_queue[2].g_icu.u_issue_frontend.write_i)
   $display("REMOTE_VXM_WRITE edge=%0t addr=%0d strb=%h data=%h",$time,
    dut.u_fu_subsystems.g_native_sched[0].g_queue[2].g_icu.u_issue_frontend.addr_i,
    dut.u_fu_subsystems.g_native_sched[0].g_queue[2].g_icu.u_issue_frontend.strb_i,
    dut.u_fu_subsystems.g_native_sched[0].g_queue[2].g_icu.u_issue_frontend.data_i);
 if(dut.u_fu_subsystems.g_native_sched[0].g_queue[2].g_icu.u_issue_frontend.fault_o)
   $fatal(1,"REMOTE_VXM_REJECT edge=%0t ar_accepted=%0d starts=0",$time,file_ar);
end
initial begin if(PRODUCT_RUN)begin #3000000;end else begin #100000;end
 $fatal(1,"timeout: cmd=%0d AR=%0d load_done=%0d ready=%0d run=%0d cycle=%0d",ix,file_ar,program_load_complete_o,program_ready_o,program_running_o,program_schedule_cycle_o);end
if(PRODUCT_RUN)begin:g_image_monitor
  integer quiet=0,last_ar=-1,last_ix=-1,last_pr=-1;
  `define EAST0 dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[0].u_slice
  `define WEST0 dut.u_fu_subsystems.gen_hemisphere[1].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.gen_slice[0].u_slice
  always @(posedge clk_i)if(program_running_o && program_schedule_cycle_o>=94 && program_schedule_cycle_o<=138)
    $display("PATH C%0d read=%b Wgroup0_rd_valid=%b Wedge20=%b Eedge20=%b E_left20=%b E_right20=%b Ecmd=%h Etap=%b Ecode=%h",
      program_schedule_cycle_o,dut.local_mem_issue_valid[105],`WEST0.bank_read_valid[PROBE_BYTES/8],
      dut.u_fu_subsystems.gen_hemisphere[1].mem_west_valid[20],dut.u_fu_subsystems.vxm_to_mem_east_valid[20],
      dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.left_boundary_state_valid_i[20*(PROBE_BYTES/8)],
      dut.u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.u_native_mem.u_mem.gen_group[0].u_group.right_boundary_state_valid_i[20*(PROBE_BYTES/8)],
      dut.local_mem_issue_instruction[31:0],`EAST0.selected_stream_valid[0],`EAST0.mem_fault_code_o);
  always @(posedge clk_i)if($test$plusargs("READ_PATH_ONLY") && program_running_o && program_schedule_cycle_o==140)begin
    $display("END diagnostic read path (no consumer program)");$finish;
  end
  `undef WEST0
  `undef EAST0
  `define LO dut.u_program_control.u_program_loader
  always @(posedge clk_i)if(rst_ni && file_probe && !program_running_o)begin
    if(last_ar!=file_ar || last_ix!=ix || last_pr!=int'(`LO.prime_fifo_level))quiet=0;else quiet++;
    last_ar=file_ar;last_ix=ix;last_pr=int'(`LO.prime_fifo_level);
    if(quiet==1024)$fatal(1,"product stalled (always-served DDR) cmds=%0d pc=%0d refill=%b sealed=%b AR=%0d words=%0d commits=%0d primes=%0d done=%b ready=%b mem_ready=%b raw_ready=%h qctl=%b data=%0d",
      ix,`LO.u_loader.command_pc_o,`LO.command_refill_o,`LO.writes_sealed,file_ar,`LO.generated_word_count_o,`LO.committed_word_count_o,
      last_pr,program_load_complete_o,program_ready_o,dut.u_fu_subsystems.mem_frontends_ready,dut.u_fu_subsystems.raw_ready,dut.u_fu_subsystems.qctl_all_primed,input_tag);
  end
  `undef LO
end
endmodule
