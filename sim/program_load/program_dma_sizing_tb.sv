`timescale 1ns/1ps
module program_dma_sizing_tb;
parameter integer P = 80;
localparam integer WINDOW = 4;
logic clk_i = 0, rst_ni = 0;
always #5 clk_i = ~clk_i;
logic command_valid_i, command_ready_o;
logic [63:0] command_address_i;
logic [31:0] command_length_i;
logic [7:0] command_id_i;
logic dma_cmd_valid_o, dma_cmd_ready_i;
logic [63:0] dma_cmd_address_o;
logic [31:0] dma_cmd_length_o;
logic [7:0] dma_cmd_id_o;
logic dma_rsp_valid_i, dma_rsp_ready_o, dma_rsp_last_i, dma_rsp_error_i;
logic [255:0] dma_rsp_data_i;
logic [31:0] dma_rsp_keep_i;
logic [7:0] dma_rsp_id_i;
logic response_valid_o, response_ready_i, response_last_o, response_error_o;
logic [255:0] response_data_o;
logic [31:0] response_keep_o;
logic [7:0] response_id_o;
logic [$clog2(WINDOW+1)-1:0] outstanding_o;
logic idle_o, fault_o;
logic [5:0] fault_code_o;
lpu_instruction_dma #(.OUTSTANDING_DEPTH(WINDOW), .RX_FIFO_DEPTH(P)) dut (.*);

integer commands = 0, words = 0;
integer stalled = 0;
function automatic logic [255:0] payload(input integer n);
  return {8{32'hcd659312 ^ 32'(n)}};
endfunction
always @(posedge clk_i) if (rst_ni) begin
  if (fault_o) $fatal(1, "unexpected ordering fault %0d", fault_code_o);
  if (dma_cmd_valid_o && dma_cmd_ready_i) begin
    if (dma_cmd_id_o != 8'(commands) || dma_cmd_address_o != 64'h1000 + 64'(commands)*4096
        || dma_cmd_length_o != 32'(2*P*32)) $fatal(1, "command mismatch");
    commands++;
  end
  if (dma_rsp_valid_i && !dma_rsp_ready_o) stalled++;
  if (response_valid_o && response_ready_i) begin
    if (response_data_o != payload(words) || response_keep_o != 32'hffffffff
        || response_id_o != 8'(words/(2*P)) || response_error_o
        || response_last_o != (words%(2*P)==2*P-1))
      $fatal(1, "lost, overwritten or reordered response at %0d", words);
    words++;
  end
end

task automatic command(input integer id);
  command_valid_i=1;
  command_id_i=8'(id);
  command_address_i=64'h1000+64'(id)*4096;
  do @(posedge clk_i); while(!command_ready_o);
  @(negedge clk_i); command_valid_i=0;
endtask

task automatic data(input integer n);
  dma_rsp_valid_i=1;
  dma_rsp_data_i=payload(n);
  dma_rsp_id_i=8'(n/(2*P));
  dma_rsp_last_i=(n%(2*P)==2*P-1);
  do @(posedge clk_i); while(!dma_rsp_ready_o);
  @(negedge clk_i); dma_rsp_valid_i=0;
endtask

initial begin
  command_valid_i=0; command_address_i=0; command_id_i=0;
  command_length_i=32'(2*P*32); dma_cmd_ready_i=1;
  dma_rsp_valid_i=0; dma_rsp_keep_i='1; dma_rsp_error_i=0;
  dma_rsp_data_i=0; dma_rsp_id_i=0; dma_rsp_last_i=0;
  response_ready_i=0;
  repeat (3) @(negedge clk_i);
  rst_ni=1;
  for (integer id=0;id<WINDOW;id++) command(id);
  command_valid_i=1; command_id_i=8'(WINDOW);
  command_address_i=64'h1000+64'(WINDOW)*4096;
  repeat (3) begin
    @(posedge clk_i);
    if (command_ready_o || dma_cmd_valid_o || outstanding_o!=WINDOW)
      $fatal(1,"fifth command accepted without a slot");
    @(negedge clk_i);
  end
  for (integer n=0;n<P;n++) data(n);
  if (dut.response_level != P || dma_rsp_ready_o || !response_valid_o)
    $fatal(1,"response FIFO did not stop at exactly P");
  dma_rsp_valid_i=1; dma_rsp_data_i=payload(P);
  repeat(600) begin
    @(posedge clk_i);
    if (dma_rsp_ready_o || response_data_o != payload(0))
      $fatal(1,"RX changed while full and consumer was paused");
  end
  @(negedge clk_i);
  response_ready_i=1;
  // A simultaneous pop makes room for the beat held upstream. The fifth
  // command can handshake when the first command's LAST retires an ID slot.
  fork
    begin
      do @(posedge clk_i); while(!command_ready_o);
      @(negedge clk_i); command_valid_i=0;
    end
    begin
      for (integer n=P;n<(WINDOW+1)*2*P;n++) data(n);
    end
  join
  wait(idle_o);
  @(negedge clk_i);
  if(words!=(WINDOW+1)*2*P || commands!=WINDOW+1 || stalled!=600)
    $fatal(1,"incomplete drain");
  $display("PASS FIFO entries=%0d window=%0d beats=%0d blocked_cycles=%0d",P,WINDOW,words,stalled);
  $finish;
end
initial begin
  repeat (3000) @(posedge clk_i);
  $fatal(1,"program DMA sizing timeout");
end
endmodule
