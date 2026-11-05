// Separate enqueue and compiler-timed launch; no autonomous rescheduling.
module lpu_mxm_command_queue #(
  parameter integer WIDTH=64, DEPTH=16,
  localparam integer PTR_BITS=DEPTH>1?$clog2(DEPTH):1
) (
  input logic clk_i,rst_ni,
  input logic enqueue_valid_i,
  output wire enqueue_ready_o,
  input logic [WIDTH-1:0] enqueue_data_i,
  input logic pop_i,
  output wire valid_o,
  output wire [WIDTH-1:0] data_o
);
  logic [WIDTH-1:0] memory_q[0:DEPTH-1];
  logic [PTR_BITS-1:0] read_q,write_q;
  integer unsigned count_q;
  wire pop=pop_i && valid_o;
  wire push=enqueue_valid_i && enqueue_ready_o;
  assign valid_o=count_q!=0;
  assign enqueue_ready_o=count_q<DEPTH || pop;
  assign data_o=valid_o?memory_q[read_q]:'0;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin read_q<=0;write_q<=0;count_q<=0;end
    else begin
      case({push,pop})
        2'b10:count_q<=count_q+1;
        2'b01:count_q<=count_q-1;
        default:begin end
      endcase
      if(push) begin
        memory_q[write_q]<=enqueue_data_i;
        write_q<=int'(write_q)==DEPTH-1?'0:write_q+1'b1;
      end
      if(pop) read_q<=int'(read_q)==DEPTH-1?'0:read_q+1'b1;
    end
  end
  initial if(DEPTH<1 || WIDTH<1) $fatal(1,"Invalid MXM queue configuration");
endmodule
