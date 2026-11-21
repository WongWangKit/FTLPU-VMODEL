`timescale 1ns/1ps
module program_control_sizing_tb;
import lpu_program_load_pkg::*;
logic clk=0, rst=0, cmd_valid=0, cmd_ready, start_valid=0, start_ready;
logic [1:0] cmd_pc=0;
logic [2:0] opcode=0;
logic [3:0] target=PROGRAM_TARGET_MXM_LOAD;
logic [1:0] fmt=PROGRAM_FORMAT_128;
logic [16:0] base=0;
logic [31:0] size=16;
logic req_valid, req_ready=0, rsp_valid=0, rsp_ready;
logic [63:0] address;
logic [31:0] length;
logic [7:0] req_id, rsp_id=0;
logic ready, fault;
logic [5:0] code;
logic [1:0] load_valid, commit_ready;
logic [5:0] load_ctl;
logic [255:0] load_data;
logic [7:0] load_strb, load_target;
logic [15:0] load_queue;
logic [33:0] load_addr;
logic [1:0] load_last, commit_valid=0;
localparam logic [127:0] IMAGE=128'hac712131a0f1a57e002142a340001234;
always #5 clk=~clk;

lpu_program_control_system #(.COMMAND_DEPTH(4),.DMA_RX_FIFO_DEPTH(80),
 .DMA_OUTSTANDING_DEPTH(4),.MEM_IMEM_DEPTH(128),.MXM_IMEM_DEPTH(2048)) dut (
 .clk_i(clk),.rst_ni(rst),.program_reset_i(1'b0),
 .command_write_valid_i(cmd_valid),.command_write_ready_o(cmd_ready),
 .command_write_address_i(cmd_pc),.command_write_opcode_i(opcode),
 .command_write_source_address_i(64'h8000),.command_write_byte_count_i(size),
 .command_write_target_kind_i(target),.command_write_global_queue_id_i(8'd0),
 .command_write_format_i(fmt),.command_write_encoding_mode_i(2'd0),
 .command_write_imem_base_address_i(base),.command_write_image_first_i(1'b1),
 .command_write_image_last_i(1'b1),.command_write_expected_word_count_i(16'd1),
 .command_write_jump_address_i(2'd0),.load_start_valid_i(start_valid),
 .load_start_ready_o(start_ready),.load_start_command_count_i(3'd3),
 .dma_cmd_valid_o(req_valid),.dma_cmd_ready_i(req_ready),
 .dma_cmd_address_o(address),.dma_cmd_length_o(length),.dma_cmd_id_o(req_id),
 .dma_rsp_valid_i(rsp_valid),.dma_rsp_ready_o(rsp_ready),.dma_rsp_data_i({128'd0,IMAGE}),
 .dma_rsp_keep_i(size==12 ? 32'hfff : 32'hffff),.dma_rsp_last_i(1'b1),
 .dma_rsp_id_i(rsp_id),.dma_rsp_error_i(1'b0),.program_start_request_i(1'b0),
 .dependencies_ready_i(1'b0),.program_start_ack_o(),.program_load_complete_o(ready),
 .program_ready_o(),.program_running_o(),.program_done_o(),
 .program_fault_o(fault),.program_fault_code_o(code),.schedule_cycle_o(),
 .endpoint_load_valid_o(load_valid),.endpoint_load_ready_i(2'b11),
 .endpoint_load_control_o(load_ctl),.endpoint_load_data_o(load_data),
 .endpoint_load_strb_o(load_strb),.endpoint_load_target_kind_o(load_target),
 .endpoint_load_queue_id_o(load_queue),.endpoint_load_imem_address_o(load_addr),
 .endpoint_load_last_o(load_last),.endpoint_commit_valid_i(commit_valid),
 .endpoint_commit_ready_o(commit_ready),.endpoint_commit_error_i(2'b0),
 .endpoint_program_start_o(),.endpoint_program_start_ready_i(1'b1),
 .endpoint_started_i(1'b0),.endpoint_frontends_ready_i(1'b0),.endpoint_frontends_idle_i(1'b1),
 .endpoint_execution_drained_i(1'b1),
 .endpoint_fault_i(1'b0),.endpoint_fault_code_i(6'd0),.endpoint_schedule_cycle_i(32'd0)
);

integer mode=0, writes=0;
always @(posedge clk) if (rst) begin
  if (load_valid!=0) begin
    if (mode%2 || load_valid!=2'b01 || load_ctl[2:0]!=PROGRAM_LOAD_WRITE ||
        load_addr[16:0]!=base || load_target[3:0]!=target || !load_last[0] ||
        load_queue[7:0]!=0 ||
        (target==PROGRAM_TARGET_MEM
          ? (load_strb[3:0]!=4'h7 || load_data[95:0]!=IMAGE[95:0])
          : (load_strb[3:0]!=4'hf || load_data[127:0]!=IMAGE)))
      $fatal(1,"wrong load target/address/word");
    writes++;
    commit_valid <= 2'b01;
  end else if (commit_ready[0]) commit_valid <= 2'b0;
  if (mode%2 && req_valid) $fatal(1,"invalid descriptor reached DMA");
  if (!(mode%2) && fault) $fatal(1,"admitted last-slot descriptor failed: code=%0d",code);
end

task automatic cmd(input logic [1:0] pc,input logic [2:0] op);
  cmd_pc=pc; opcode=op; cmd_valid=1;
  do @(posedge clk);while(!cmd_ready);
  @(negedge clk); cmd_valid=0;
endtask

initial begin
  if ($value$plusargs("CASE=%d",mode)) begin end
  if (mode>=2) begin target=PROGRAM_TARGET_MEM; fmt=PROGRAM_FORMAT_96; size=12; end
  base=17'((mode>=2?128:2048)-(1-mode%2));
  repeat(4) @(negedge clk); rst=1;
  cmd(0,PROGRAM_LOADER_LOAD_IMEM);
  if (mode%2) begin
    if (!fault || code!=PROGRAM_FAULT_DESCRIPTOR || start_ready)
      $fatal(1,"descriptor at capacity not rejected");
  end else begin
    cmd(1,PROGRAM_LOADER_WAIT_DMA); cmd(2,PROGRAM_LOADER_END);
    start_valid=1;
    do @(posedge clk);while(!start_ready);
    @(negedge clk); start_valid=0;
    while (!req_valid) @(negedge clk);
    if (address!=64'h8000 || length!=size) $fatal(1,"DDR command mismatch");
    rsp_id=req_id; req_ready=1;
    @(posedge clk); @(negedge clk); req_ready=0; rsp_valid=1;
    do @(posedge clk);while(!rsp_ready);
    @(negedge clk); rsp_valid=0;
    while(!ready) @(negedge clk);
    if(writes!=1 || commit_valid!=0) $fatal(1,"incorrect commit/drain");
  end
  $display("PASS program control target=%0d addr=%0d rejected=%0d",target,base,mode%2);
  $finish;
end
initial begin repeat(500) @(posedge clk); $fatal(1,"control test timeout"); end
endmodule
