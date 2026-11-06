module ftlpu_sr_superlane_col_dir_lane #(
  parameter integer STREAMS=32, LANES=8, DATA_BITS=8,
  parameter integer LOCAL_PRODUCERS=2, LOCAL_CONSUMERS=2
)(
  input logic clk_i,rst_ni,
  input logic [STREAMS*LANES-1:0] upstream_valid_i,
  input logic [STREAMS*LANES*DATA_BITS-1:0] upstream_data_i,
  output logic [STREAMS*LANES-1:0] state_valid_o,
  output logic [STREAMS*LANES*DATA_BITS-1:0] state_data_o,
  input logic [LOCAL_CONSUMERS*STREAMS*LANES-1:0] consume_i,
  output logic [STREAMS*LANES-1:0] downstream_valid_o,
  output logic [STREAMS*LANES*DATA_BITS-1:0] downstream_data_o,
  input logic [LOCAL_PRODUCERS*STREAMS*LANES-1:0] inject_valid_i,
  input logic [LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0] inject_data_i,
  output logic collision_o,invalid_consume_o
);
  localparam integer CELLS=STREAMS*LANES, SOURCES=LOCAL_PRODUCERS+1;
  wire [CELLS-1:0] collisions,invalid_consumes;
  for(genvar c=0;c<CELLS;c++) begin:g_cell
    wire [SOURCES-1:0] requests,unique_source;
    wire [LOCAL_CONSUMERS-1:0] consume_requests;
    wire [DATA_BITS-1:0] selected[SOURCES:0];
    assign requests[0]=upstream_valid_i[c];
    assign selected[0]='0;
    for(genvar s=0;s<SOURCES;s++) begin:g_source
      localparam [SOURCES-1:0] MASK=~(1<<s);
      wire [DATA_BITS-1:0] value;
      if(s==0) assign value=upstream_data_i[c*DATA_BITS+:DATA_BITS];
      else begin
        assign requests[s]=inject_valid_i[(s-1)*CELLS+c];
        assign value=inject_data_i[((s-1)*CELLS+c)*DATA_BITS+:DATA_BITS];
      end
      assign unique_source[s]=requests[s] && !(|(requests&MASK));
      assign selected[s+1]=selected[s] | (value&{DATA_BITS{unique_source[s]}});
    end
    for(genvar s=0;s<LOCAL_CONSUMERS;s++) begin:g_consume
      assign consume_requests[s]=consume_i[s*CELLS+c];
    end
    assign collisions[c]=(|requests)&&!(|unique_source);
    assign invalid_consumes[c]=(|consume_requests)&&!state_valid_o[c];
    assign downstream_valid_o[c]=state_valid_o[c]&&!(|consume_requests);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if(!rst_ni) begin state_valid_o[c]<=0;state_data_o[c*DATA_BITS+:DATA_BITS]<='0;end
      else begin state_valid_o[c]<=|unique_source;state_data_o[c*DATA_BITS+:DATA_BITS]<=selected[SOURCES];end
    end
  end
  assign downstream_data_o=state_data_o;
  assign collision_o=|collisions;
  assign invalid_consume_o=|invalid_consumes;
endmodule
