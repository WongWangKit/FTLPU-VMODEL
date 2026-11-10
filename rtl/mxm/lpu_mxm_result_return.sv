// Static diagonal result-return fabric. Row zero is bottom, column zero left.
// A top result from column c descends to row c, then travels left to that
// Superlane's accumulator. Only positions r>=c contain return registers.
// Off-diagonal positions have TWO independent streams, not an arbitrated mux.
// One register per visited position, including the diagonal/left endpoint:
// (ROWS-1-c) downward stages + (c+1) leftward stages = ROWS, for every c.
module lpu_mxm_result_return #(
  parameter integer ROWS=lpu_mxm_config_pkg::SC_ROWS,
  parameter integer COLS=lpu_mxm_config_pkg::SC_COLS,
  parameter integer LANES=lpu_mxm_config_pkg::CELL_N,
  parameter integer TAG_BITS=16,
  localparam integer WORD_BITS=LANES*32
) (
  input logic clk_i,rst_ni,run_i,
  input logic [COLS-1:0] top_valid_i,
  input logic [COLS*WORD_BITS-1:0] top_i,
  input logic [COLS*TAG_BITS-1:0] top_tag_i,
  output wire [ROWS-1:0] left_valid_o,
  output wire [ROWS*WORD_BITS-1:0] left_o,
  output wire [ROWS*TAG_BITS-1:0] left_tag_o,
  // Public per-position registered links, indexed r*COLS+c. Inactive links
  // are zero. They permit black-box checks of simultaneous crossing traffic.
  output wire [ROWS*COLS-1:0] down_valid_o,left_link_valid_o,
  output wire [ROWS*COLS*WORD_BITS-1:0] down_o,left_link_o,
  output wire [ROWS*COLS*TAG_BITS-1:0] down_tag_o,left_link_tag_o
);
  wire reset_n=rst_ni && run_i;
  if(ROWS==COLS && ROWS>0 && LANES>0 && TAG_BITS>0) begin : g_square
    for(genvar r=0;r<ROWS;r++) begin : g_row
      for(genvar c=0;c<COLS;c++) begin : g_cell
        localparam integer P=r*COLS+c;
        if(r>c) begin : g_down
          wire source_valid;
          wire [WORD_BITS-1:0] source_data;
          wire [TAG_BITS-1:0] source_tag;
          if(r==ROWS-1) begin : g_top
            assign source_valid=top_valid_i[c];
            assign source_data=top_i[c*WORD_BITS+:WORD_BITS];
            assign source_tag=top_tag_i[c*TAG_BITS+:TAG_BITS];
          end else begin : g_above
            assign source_valid=down_valid_o[P+COLS];
            assign source_data=down_o[(P+COLS)*WORD_BITS+:WORD_BITS];
            assign source_tag=down_tag_o[(P+COLS)*TAG_BITS+:TAG_BITS];
          end
          logic valid_q;
          logic [WORD_BITS-1:0] data_q;
          logic [TAG_BITS-1:0] tag_q;
          always_ff @(posedge clk_i or negedge reset_n) begin
            if(!reset_n) begin valid_q<=0;data_q<=0;tag_q<=0;end
            else begin
              valid_q<=source_valid;
              if(source_valid) begin data_q<=source_data;tag_q<=source_tag;end
            end
          end
          assign down_valid_o[P]=valid_q;
          assign down_o[P*WORD_BITS+:WORD_BITS]=data_q;
          assign down_tag_o[P*TAG_BITS+:TAG_BITS]=tag_q;
        end else begin : g_no_down
          assign down_valid_o[P]=0;
          assign down_o[P*WORD_BITS+:WORD_BITS]='0;
          assign down_tag_o[P*TAG_BITS+:TAG_BITS]='0;
        end
        if(r>=c) begin : g_left
          wire source_valid;
          wire [WORD_BITS-1:0] source_data;
          wire [TAG_BITS-1:0] source_tag;
          if(r==c) begin : g_turn
            if(r==ROWS-1) begin : g_top
              assign source_valid=top_valid_i[c];
              assign source_data=top_i[c*WORD_BITS+:WORD_BITS];
              assign source_tag=top_tag_i[c*TAG_BITS+:TAG_BITS];
            end else begin : g_above
              assign source_valid=down_valid_o[P+COLS];
              assign source_data=down_o[(P+COLS)*WORD_BITS+:WORD_BITS];
              assign source_tag=down_tag_o[(P+COLS)*TAG_BITS+:TAG_BITS];
            end
          end else begin : g_right
            assign source_valid=left_link_valid_o[P+1];
            assign source_data=left_link_o[(P+1)*WORD_BITS+:WORD_BITS];
            assign source_tag=left_link_tag_o[(P+1)*TAG_BITS+:TAG_BITS];
          end
          logic valid_q;
          logic [WORD_BITS-1:0] data_q;
          logic [TAG_BITS-1:0] tag_q;
          always_ff @(posedge clk_i or negedge reset_n) begin
            if(!reset_n) begin valid_q<=0;data_q<=0;tag_q<=0;end
            else begin
              valid_q<=source_valid;
              if(source_valid) begin data_q<=source_data;tag_q<=source_tag;end
            end
          end
          assign left_link_valid_o[P]=valid_q;
          assign left_link_o[P*WORD_BITS+:WORD_BITS]=data_q;
          assign left_link_tag_o[P*TAG_BITS+:TAG_BITS]=tag_q;
        end else begin : g_no_left
          assign left_link_valid_o[P]=0;
          assign left_link_o[P*WORD_BITS+:WORD_BITS]='0;
          assign left_link_tag_o[P*TAG_BITS+:TAG_BITS]='0;
        end
      end
      assign left_valid_o[r]=left_link_valid_o[r*COLS];
      assign left_o[r*WORD_BITS+:WORD_BITS]=left_link_o[r*COLS*WORD_BITS+:WORD_BITS];
      assign left_tag_o[r*TAG_BITS+:TAG_BITS]=left_link_tag_o[r*COLS*TAG_BITS+:TAG_BITS];
    end
  end else begin : g_unsupported
    assign left_valid_o='0;assign left_o='0;assign left_tag_o='0;
    assign down_valid_o='0;assign down_o='0;assign down_tag_o='0;
    assign left_link_valid_o='0;assign left_link_o='0;assign left_link_tag_o='0;
  end
  initial if(ROWS<1 || ROWS!=COLS || LANES<1 || TAG_BITS<1)
    $fatal(1,"MXM result return requires a positive square array and payload widths");
endmodule
