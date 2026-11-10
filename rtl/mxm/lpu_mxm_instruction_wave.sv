// Neighbor-to-neighbor relay. Each nonterminal row has a local short counter
// restarted only when its own instruction is replaced. No global wave lock.
module lpu_mxm_instruction_wave #(
  parameter integer WIDTH=64,ROWS=4,INTERVAL=3,COUNT_BITS=16,
  localparam integer AGE_BITS=INTERVAL>1?$clog2(INTERVAL):1
) (
  input logic clk_i,rst_ni,run_i,
  input logic launch_i,
  input logic [WIDTH-1:0] instruction_i,
  input logic [COUNT_BITS-1:0] duration_i,
  output wire launch_ready_o,
  output wire [ROWS-1:0] row_valid_o,
  output logic [ROWS-1:0] row_update_o,
  output logic [ROWS*WIDTH-1:0] row_instruction_o,
  output wire [ROWS*COUNT_BITS-1:0] row_index_o
);
  logic [ROWS-1:0] pending_q;
  wire [ROWS-1:0] forward_now;
  logic [COUNT_BITS-1:0] duration_q[0:ROWS-1];
  logic [COUNT_BITS-1:0] remaining_q[0:ROWS-1],index_q[0:ROWS-1];
  // Release the bottom as soon as its immediate neighbor captures the old
  // command. Upper rows relay that old command without retaining a global lock.
  assign launch_ready_o=run_i && (!pending_q[0] || forward_now[0]) && remaining_q[0]<=1;
  for(genvar r=0;r<ROWS;r++) begin : g_row
    wire replaced;
    if(r==0) begin : g_bottom
      assign replaced=launch_i && launch_ready_o;
    end else begin : g_upper
      assign replaced=forward_now[r-1];
    end
    if(r<ROWS-1) begin : g_local_timer
      logic [AGE_BITS-1:0] age_q;
      assign forward_now[r]=run_i && pending_q[r] && age_q==AGE_BITS'(INTERVAL-1);
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) age_q<=0;
        else if(!run_i || replaced || forward_now[r]) age_q<=0;
        else if(pending_q[r]) age_q<=age_q+1'b1;
      end
    end else begin : g_top
      // The final Superlane executes its command but has nobody to forward to.
      assign forward_now[r]=1'b0;
    end
    assign row_valid_o[r]=run_i && remaining_q[r]!=0;
    assign row_index_o[r*COUNT_BITS+:COUNT_BITS]=index_q[r];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      pending_q<=0;
      row_update_o<=0;row_instruction_o<=0;
      for(integer r=0;r<ROWS;r++) begin
        remaining_q[r]<=0;index_q[r]<=0;duration_q[r]<=0;
      end
    end else if(!run_i) begin
      pending_q<=0;row_update_o<=0;row_instruction_o<=0;
      for(integer r=0;r<ROWS;r++) begin
        remaining_q[r]<=0;index_q[r]<=0;duration_q[r]<=0;
      end
    end else begin
      row_update_o<=0;
      for(integer r=0;r<ROWS;r++) begin
        if(remaining_q[r]!=0) begin
          remaining_q[r]<=remaining_q[r]-1'b1;
          if(remaining_q[r]>1) index_q[r]<=index_q[r]+1'b1;
        end
        if(forward_now[r]) pending_q[r]<=0;
        if(r>0) begin
          if(forward_now[r-1]) begin
            // Nonblocking assignments capture the predecessor's OLD command,
            // even if it is replaced by another command on this same edge.
            row_instruction_o[r*WIDTH+:WIDTH]<=row_instruction_o[(r-1)*WIDTH+:WIDTH];
            duration_q[r]<=duration_q[r-1];remaining_q[r]<=duration_q[r-1];
            index_q[r]<=0;row_update_o[r]<=1;
            pending_q[r]<=r<ROWS-1;
          end
        end
      end
      if(launch_i && launch_ready_o) begin
        row_instruction_o[0+:WIDTH]<=instruction_i;
        remaining_q[0]<=duration_i;index_q[0]<=0;row_update_o[0]<=1;
        duration_q[0]<=duration_i;
        pending_q[0]<=ROWS>1;
      end
    end
  end
  initial if(ROWS<1 || INTERVAL<1 || COUNT_BITS<1)
    $fatal(1,"Invalid MXM instruction wave");
endmodule
