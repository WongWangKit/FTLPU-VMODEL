`timescale 1ns/1ps

// Observe before native issue filtering, including malformed commands which
// would otherwise be rejected before reaching the control-column checker.
module mem_p1_slice_issue_checker (
  input logic clk_i,rst_ni,
  input logic[1:0] valid_i,
  input logic[63:0] command_i
);
  bit reset_seen=0;
  always @(negedge rst_ni)if(rst_ni===1'b0)reset_seen=1;
  always @(posedge clk_i)if(reset_seen && rst_ni===1'b1)begin
    if($isunknown(valid_i))$fatal(1,"%m unknown MEM command valid");
    for(integer b=0;b<2;b=b+1)
      if(valid_i[b] && $isunknown(command_i[b*32+:32]))$fatal(1,"%m unknown valid MEM command");
  end
endmodule

module mem_p1_feedback_checker #(
  parameter integer CANDIDATES=32
)(
  input logic clk_i,rst_ni,
  input logic[CANDIDATES-1:0] valid_i,feedback_i
);
  bit reset_seen=0;
  always @(negedge rst_ni)if(rst_ni===1'b0)reset_seen=1;
  always @(posedge clk_i)if(reset_seen && rst_ni===1'b1)
    for(integer p=0;p<CANDIDATES;p=p+1)
      if(valid_i[p] && $isunknown(feedback_i[p]))$fatal(1,"%m unknown valid MEM collision feedback");
endmodule

bind mem_slice mem_p1_slice_issue_checker u_mem_issue_checker(
  .clk_i(clk_i),.rst_ni(rst_ni),.valid_i(bank_issue_valid_i),.command_i(bank_issue_i));
bind mem_group mem_p1_feedback_checker #(.CANDIDATES(P_SLICES*P_BANKS_PER_SLICE*P_TILE_ROWS)) u_mem_feedback_checker(
  .clk_i(clk_i),.rst_ni(rst_ni),.valid_i(slice_inject_valid),.feedback_i(external_producer_collision_i));
