`timescale 1ns/1ps
module native_chain_tb #(parameter integer PROBE_BYTES=32,parameter bit PROBE_PRODUCT_GEOMETRY=0);
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
lpu_top #(
.T(PROBE_BYTES/8),.ENABLE_QCTL(0), .PROGRAM_COMMAND_DEPTH(32),
.PROGRAM_MEM_IMEM_DEPTH(PROBE_PRODUCT_GEOMETRY?lpu_pkg::dma_mixed_mem_imem_depth(PROBE_BYTES):16),
.PROGRAM_MXM_IMEM_DEPTH(PROBE_PRODUCT_GEOMETRY?lpu_pkg::dma_mixed_mxm_imem_depth(PROBE_BYTES):16),
.MEM_DEPTH_ROWS(PROBE_PRODUCT_GEOMETRY?0:32), .ACTIVE_MEM_COLUMNS(PROBE_PRODUCT_GEOMETRY?52:4),
.ENABLE_SXM_VXM_EXECUTION(1'b1), .PROGRAM_ACTIVE_CONTEXTS(2),
.MXM_ACCUMULATOR_BLOCK_COUNT(1)
) dut (.dma_page_last_i(1'b0),.dma_page_event_tag_i('0),.dma_page_generation_i('0),.dma_page_mask_i('0),.dma_desc_valid_i(1'b0),.dma_desc_ready_o(),.dma_store_i(1'b0),.dma_hem_i(1'b0),
 .dma_indexed_i(1'b0),.dma_index_addr_i('0),.dma_row_limit_i('0),
 .expert_clear_i(1'b0),.expert_word_valid_i(1'b0),.expert_word_i('0),.expert_count_i('0),
 .expert_segment_count_i('0),.expert_config_ready_o(),.expert_valid_i(1'b0),.expert_ready_o(),
 .expert_id_i('0),.expert_bank_xor_i(1'b0),.expert_stream_mask_i('0),
 .expert_done_o(),.expert_error_o(),.expert_done_ready_i(1'b0),
 .dma_bank_i('0),.dma_lane_i('0),.dma_row_i('0),.dma_addr_i('0),.dma_count_i('0),.dma_stride_i('0),.dma_tag_i('0),
 .dma_busy_o(),.dma_result_valid_o(),.dma_result_error_o(),.dma_result_ready_i(1'b1),.dma_result_tag_o(),.dma_isolated_o(),
 .dma_bg_load_i('0),.dma_bg_cancel_i('0),.dma_bg_command_i('0),.dma_bg_epoch_i('0),.dma_bg_bank_mask_i('0),
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
logic [255:0] external_ddr[0:65535];
task automatic event_at(input int k,cy,input logic [127:0] payload,input logic [31:0] aux=0);
 ddr[k*64+n[k]]={64'b0,aux,32'(cy),payload};n[k]++;
endtask
task automatic cmd(input int op,k);
 @(negedge clk_i);program_command_write_valid_i=1;program_command_write_address_i=5'(ix++);program_command_write_opcode_i=3'(op);
 program_command_write_source_address_i=64'(k*2048);program_command_write_byte_count_i=32*n[k];
 program_command_write_target_kind_i=4'(k);program_command_write_format_i=PROGRAM_FORMAT_128;
 program_command_write_image_first_i=1;program_command_write_image_last_i=1;program_command_write_expected_word_count_i=2*n[k];
 if(file_probe)begin
   program_command_write_source_address_i=0;program_command_write_target_kind_i=image_kind;
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
   (external_ddr[addr/(32/PROBE_BYTES)] >> ((addr%(32/PROBE_BYTES))*8*PROBE_BYTES)):ddr[addr];end
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
   $display("ADMITTED remote VXM queue; no partial START");$finish;
 end

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
 event_at(4,10,(128'(vf)<<65)+(128'(1)<<64));
 event_at(4,RUN,3+(4<<8)); // Q0 negate, Q1 bypass
 for(int k=4;k<=11;k++)begin cmd(PROGRAM_LOADER_LOAD_IMEM,k);cmd(PROGRAM_LOADER_WAIT_DMA,k);cmd(PROGRAM_LOADER_COMMIT_QUEUE,k);end
 cmd(PROGRAM_LOADER_END,0);
 @(negedge clk_i);program_load_start_valid_i=1;program_load_start_command_count_i=ix;
 do @(posedge clk_i);while(!program_load_start_ready_o);
 @(negedge clk_i);program_load_start_valid_i=0;wait(program_ready_o);
 @(negedge clk_i);program_dependencies_ready_i=1;program_start_request_i=1;
 wait(program_start_ack_o);@(negedge clk_i);program_start_request_i=0;
 wait(program_done_o);if(results!=4)$fatal(1,"missing VXM vectors %d",results);
 $display("PASS native chain: 4 tiles x 8 lanes reached the opposite top-level SRF boundary");$finish;
end
function automatic logic [15:0] bf(input integer val);
 int e;begin e=$clog2(val+1)-1;return 16'(((127+e)<<7)+((val-(1<<e))*128/(1<<e)));end
endfunction
always @(negedge clk_i)begin
 mem_east_edge_valid_i=0;mem_west_edge_valid_i=0;
 if(program_running_o)for(int t=0;t<4;t++)begin
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
// Golden SRF contents, independent of the DUT's interconnect or producer valids.
// bin is the edge on which the corresponding external input was supplied.
for(genvar h=0;h<2;h++)begin:check_hem_srf
 wire [4095:0] valid=dut.u_fu_subsystems.gen_hemisphere[h].u_mem_subsystem.u_native_mem.state_valid_o;
 wire [262143:0] data=dut.u_fu_subsystems.gen_hemisphere[h].u_mem_subsystem.u_native_mem.state_data_o;
 always @(posedge clk_i)if(program_running_o)begin
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
always @(posedge clk_i)if(program_running_o)begin
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
always @(posedge clk_i)if(rst_ni && (program_fault_o || dut.data_fault))$fatal(1,"fault %0d at %0d: mem=%h mxm=%b sxm=%b vxm=%b clash=%b",program_fault_code_o,program_schedule_cycle_o,mem_fault_o,mxm_fault_o,sxm_fault_o,vxm_fault_o,stream_conflict_o);
always @(posedge clk_i) if(file_probe && rst_ni)begin
 if(program_command_write_ready_o && program_command_write_valid_i && program_command_write_opcode_i==PROGRAM_LOADER_LOAD_IMEM)
   $display("REMOTE_DESCRIPTOR bytes=%0d word=%0d mode=%0d AR=%0d",image_bytes,image_word,program_command_write_encoding_mode_i,file_ar);
 if(program_fault_o)
   $display("REMOTE_FAULT code=%0d edge=%0t ar=%0d schedule=%0d",program_fault_code_o,$time,file_ar,program_schedule_cycle_o);
 if(dut.u_fu_subsystems.g_native_sched[0].g_queue[2].u_calendar.write_i)
   $display("REMOTE_VXM_WRITE edge=%0t addr=%0d strb=%h data=%h",$time,
    dut.u_fu_subsystems.g_native_sched[0].g_queue[2].u_calendar.addr_i,
    dut.u_fu_subsystems.g_native_sched[0].g_queue[2].u_calendar.strb_i,
    dut.u_fu_subsystems.g_native_sched[0].g_queue[2].u_calendar.data_i);
 if(dut.u_fu_subsystems.g_native_sched[0].g_queue[2].u_calendar.fault_o)
   $fatal(1,"REMOTE_VXM_REJECT edge=%0t ar_accepted=%0d starts=0",$time,file_ar);
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
