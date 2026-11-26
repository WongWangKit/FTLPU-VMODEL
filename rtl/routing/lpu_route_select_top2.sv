// ROUTE_SELECT, K=2. Scores arrive in increasing expert-id order for one token.
// The MEM view reader, descriptor sequencer and downstream task planner are separate.
module lpu_route_select_top2 #(parameter integer ID_BITS=10)(
  input logic clk_i,rst_ni,clear_i,
  input logic score_valid_i,last_i,eligible_i,
  output logic score_ready_o,
  input logic [31:0] choice_i,raw_i,
  output logic pair_valid_o,fault_o,input logic pair_ready_i,
  output logic [ID_BITS-1:0] first_id_o,second_id_o,
  output logic [31:0] first_raw_o,second_raw_o
);
  typedef struct packed {logic valid; logic [31:0] key,raw; logic [ID_BITS-1:0] id;} candidate;
  candidate a,b,na,nb,incoming;
  logic [ID_BITS-1:0] id;
  function automatic logic nan32(input logic [31:0] x);
    return (&x[30:23]) && (|x[22:0]);
  endfunction
  function automatic logic [31:0] order_key(input logic [31:0] x);
    if(x[30:0]==0)return 32'h80000000; // +0 and -0 tie
    return x[31] ? ~x : (x^32'h80000000);
  endfunction
  always_comb begin
    incoming={eligible_i,order_key(choice_i),raw_i,id};
    na=a;nb=b;
    // Strict comparison retains the earlier (lower) expert on a tie.
    if(eligible_i && (!a.valid || incoming.key>a.key))begin na=incoming;nb=a;end
    else if(eligible_i && (!b.valid || incoming.key>b.key))nb=incoming;
  end
  assign score_ready_o=rst_ni && !clear_i && !fault_o && !pair_valid_o;
  assign {first_id_o,second_id_o,first_raw_o,second_raw_o}={a.id,b.id,a.raw,b.raw};
  always_ff @(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin a<='0;b<='0;id<='0;fault_o<=0;pair_valid_o<=0;end
    else if(clear_i || (pair_valid_o && pair_ready_i))begin
      a<='0;b<='0;id<='0;fault_o<=0;pair_valid_o<=0;
    end else if(score_valid_i && score_ready_o)begin
      if((eligible_i && (nan32(choice_i)||nan32(raw_i))) || (last_i && !nb.valid) ||
         (!last_i && (&id)))fault_o<=1;
      else begin a<=na;b<=nb;id<=id+1'b1;pair_valid_o<=last_i;end
    end
  end
endmodule
