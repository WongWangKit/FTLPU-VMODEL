// Fixed-delay, full-rate relay. A launch is a valid beat, including identical
// consecutive words. Each receiver local register is the final delay stage;
// INTERVAL=3 adds two intermediate registers between local registers.
module lpu_mxm_instruction_wave #(
  parameter integer WIDTH=64,ROWS=4,INTERVAL=3,
  localparam integer STAGES=1+(ROWS-1)*INTERVAL
) (
  input logic clk_i,rst_ni,run_i,launch_i,
  input logic [WIDTH-1:0] instruction_i,
  output wire launch_ready_o,
  output wire [ROWS-1:0] row_valid_o,row_update_o,
  output wire [ROWS*WIDTH-1:0] row_instruction_o
);
  logic [STAGES-1:0] valid_q;
  logic [WIDTH-1:0] payload_q[0:STAGES-1];
  assign launch_ready_o=run_i;
  for(genvar r=0;r<ROWS;r++) begin : g_row
    assign row_valid_o[r]=run_i && valid_q[r*INTERVAL];
    assign row_update_o[r]=row_valid_o[r];
    assign row_instruction_o[r*WIDTH+:WIDTH]=payload_q[r*INTERVAL];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      valid_q<=0;
      for(integer s=0;s<STAGES;s++) payload_q[s]<=0;
    end else if(!run_i) begin
      valid_q<=0;
      for(integer s=0;s<STAGES;s++) payload_q[s]<=0;
    end else begin
      valid_q[0]<=launch_i;
      if(launch_i) payload_q[0]<=instruction_i;
      for(integer s=1;s<STAGES;s++) begin
        valid_q[s]<=valid_q[s-1];
        if(valid_q[s-1]) payload_q[s]<=payload_q[s-1];
      end
    end
  end
  initial if(ROWS<1 || INTERVAL<1 || WIDTH<1)
    $fatal(1,"Invalid MXM instruction wave");
endmodule
