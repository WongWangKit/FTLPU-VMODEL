// Vector IW/Compute path. A different activation may enter every cycle.
// Tile r,c consumes its local row's command delayed by c horizontal hops;
// the partial sum for that activation arrives from row r-1 one cycle later.
module lpu_mxm_vector_array #(
  parameter integer T=4, ACC_BLOCKS=32,
  localparam integer ROWS=T*8, DEPTH=ACC_BLOCKS*ROWS
)(
  input logic clk_i,rst_ni,run_i,
  input logic discard_partial_sums_i,
  input logic issue_valid_i,input logic [48:0] issue_word_i,
  input logic [3:0] valid_i, bf16_i,
  input logic [191:0] words_i,
  input logic [127:0] east_valid_i,
  input logic [8191:0] east_data_i,
  input logic [2*4*4*8*8*16-1:0] weights_i,
  input logic [31:0] cell_valid_i,
  output wire [127:0] consumed_o, west_valid_o,
  output wire [8191:0] west_data_o,
  output wire busy_o,fault_o
);
  import lpu_vxm_math_pkg::*;
  localparam integer RB=$clog2(ROWS);
  typedef struct packed {
    logic valid,fmt;
    logic [47:0] w;
    logic [RB-1:0] row_num;
    logic [127:0] act;
  } operation_t;
  operation_t source[T], op[T][T];
  wire [255:0] sum[T][T];
  wire valid_dot[T][T];
  wire [T-1:0] input_bad, output_bad,column_busy;
  logic [1:0] prev,active;
  logic [RB-1:0] next_row[2], row_pipe[T];
  wire [RB-1:0] row0 = !prev[words_i[2]] ? '0 : next_row[words_i[2]];
  always_comb begin
    active='0;
    for(integer r=0;r<T;r++) if(source[r].valid) active[source[r].w[2]]=1'b1;
  end
  always_ff @(posedge clk_i) begin
    if(!rst_ni || !run_i) begin
      prev<='0;next_row[0]<='0;next_row[1]<='0;
      for(integer r=0;r<T;r++)row_pipe[r]<='0;
    end else begin
      prev<=active;
      if(source[0].valid)next_row[words_i[2]]<=row0+1'b1;
      row_pipe[0]<=row0;
      for(integer r=1;r<T;r++)row_pipe[r]<=row_pipe[r-1];
    end
  end
  for(genvar r=0;r<4;r++)begin: gen_row
    if(r<T)begin
      wire [47:0] w=words_i[48*r+:48];
      wire fire=run_i && valid_i[r] && !w[46] && w[1:0]==1;
      wire [5:0] base=w[8:3];
      assign source[r].row_num=(r==0)?row0:row_pipe[(r==0)?0:r-1];
      assign source[r].valid=fire;
      assign source[r].w=w;
      assign source[r].fmt=bf16_i[r];
      assign consumed_o[32*r+:32]=fire?(32'h3<<base):32'd0;
      assign input_bad[r]=fire && (base>30 || !east_valid_i[32*r+base] ||
                          !east_valid_i[32*r+base+1] || w[43:28]==0);
      for(genvar k=0;k<8;k++)begin
        assign source[r].act[16*k+:16]={east_data_i[(32*r+base+1)*64+k*8+:8],
                                         east_data_i[(32*r+base)*64+k*8+:8]};
      end
      for(genvar c=0;c<T;c++)begin: gen_col
        if(c==0) assign op[r][c]=source[r];
        else always_ff @(posedge clk_i)
          if(!rst_ni || !run_i)op[r][c]<='0;else op[r][c]<=op[r][c-1];
        wire [255:0] incoming;
        if(r==0)assign incoming='0;
        else begin
          logic [255:0] partial_q;
          always_ff @(posedge clk_i)if(op[r-1][c].valid)partial_q<=sum[r-1][c];
          assign incoming=partial_q;
        end
        assign valid_dot[r][c]=!op[r][c].valid ||
                     cell_valid_i[(op[r][c].w[2]*T+r)*T+c];
        for(genvar n=0;n<8;n++)begin: gen_lane
          logic [31:0] value;
          always_comb begin
            value=incoming[n*32+:32];
            if(op[r][c].valid)for(integer k=0;k<8;k++)begin
              logic [15:0] a,b;
              a=op[r][c].act[k*16+:16];
              b=weights_i[(((((op[r][c].w[2]*T+r)*T+c)*8+k)*8+n)*16)+:16];
              value=fp32_add_rne(value,fp32_multiply_rne(
                op[r][c].w[45]?{a,16'b0}:fp16_to_fp32(a),
                op[r][c].w[45]?{b,16'b0}:fp16_to_fp32(b)));
            end
          end
          assign sum[r][c][n*32+:32]=value;
        end
      end
    end else assign consumed_o[r*32+:32]='0;
  end
  for(genvar c=0;c<4;c++)begin: gen_bank
    if(c<T)begin: active_bank
      operation_t tail;
      assign tail=op[T-1][c];
      wire [47:0] rd=words_i[48*c+:48];
      wire reading=run_i && valid_i[c] && !rd[46] && rd[1:0]==2;
      wire writing=tail.valid;
      wire [31:0] addr=writing?tail.w[27:15]+tail.row_num*tail.w[43:28]:rd[27:15];
      wire fmt=writing?tail.fmt:bf16_i[c];
      wire [5:0] base=writing?tail.w[14:9]:rd[14:9];
      wire emit_result=writing?tail.w[44]:(reading && rd[44]);
      wire clear_value=writing?(!tail.w[47] && tail.w[44]):rd[28];
      logic [255:0] out_value;
      logic [DEPTH-1:0] present;
      wire [T-1:0] in_flight,cell_ok;
      for(genvar r=0;r<T;r++)begin
        assign in_flight[r]=op[r][c].valid;
        assign cell_ok[r]=valid_dot[r][c];
      end
      assign column_busy[c]=|in_flight || reading;
      assign output_bad[c]=!(&cell_ok) || (writing && reading) ||
           ((writing || reading) && (addr>=DEPTH || (emit_result && base>(fmt?30:28)))) ||
           (reading && (rd[8:2]!=0 || rd[43:29]!=0 || rd[45] || rd[47]));
      wire ok=(writing || reading) && !output_bad[c];
      wire [255:0] ram_value;
`ifdef FTLPU_USE_SRAM128X512_MACRO
      operation_t ahead;
      if(c==0) assign ahead=op[T-2][0]; else assign ahead=op[T-1][c-1];
      wire [47:0] next_rd;wire next_valid;
      if(c==0)begin assign next_rd=issue_word_i[47:0];assign next_valid=issue_valid_i;end
      else begin assign next_rd=words_i[(c-1)*48+:48];assign next_valid=valid_i[c-1];end
      wire next_read=next_valid && !next_rd[46] && next_rd[1:0]==2;
      wire [31:0] pre_addr=ahead.valid?ahead.w[27:15]+ahead.row_num*ahead.w[43:28]:next_rd[27:15];
      wire pre=run_i && (ahead.valid || next_read) && pre_addr<DEPTH;
      lpu_mxm_vector_acc_bank #(.DEPTH(DEPTH)) u_bank(.clk_i,.rst_ni,.pre_i(pre),
        .pre_addr_i(pre_addr[$clog2(DEPTH)-1:0]),.write_i(run_i && writing && ok && !clear_value),
        .write_addr_i(addr[$clog2(DEPTH)-1:0]),.write_data_i(out_value),.read_data_o(ram_value));
`else
      logic [255:0] data[DEPTH];
      assign ram_value=data[addr];
      always_ff @(posedge clk_i)if(rst_ni && run_i && writing && ok && !clear_value)data[addr]<=out_value;
`endif
      wire [255:0] old_value=(addr<DEPTH && present[addr])?ram_value:256'b0;
      always_comb begin
        out_value=old_value;
        if(writing)for(integer n=0;n<8;n++)
          out_value[32*n+:32]=fp32_add_rne(old_value[32*n+:32],sum[T-1][c][32*n+:32]);
      end
      always_ff @(posedge clk_i)begin
        // A failed generation can end after a partial accumulation and
        // before its ACC_READ/clear. Clean segment changes preserve sums.
        if(!rst_ni || discard_partial_sums_i)present<='0;
        else if(run_i && ok)begin
          if(clear_value)present[addr]<=0;
          else if(writing)present[addr]<=1;
        end
      end
      logic [2047:0] packed_data;
      always_comb begin
        packed_data='0;
        if(ok && emit_result)for(integer n=0;n<8;n++)begin
          logic [31:0] v;
          v=fmt?{16'b0,fp32_to_bf16(out_value[n*32+:32])}:out_value[n*32+:32];
          for(integer b=0;b<4;b++)if(!fmt || b<2)
            packed_data[(base+b)*64+n*8+:8]=v[b*8+:8];
        end
      end
      assign west_data_o[c*2048+:2048]=packed_data;
      assign west_valid_o[c*32+:32]=ok && emit_result?((fmt?32'h3:32'hf)<<base):0;
    end else begin assign west_valid_o[c*32+:32]='0;assign west_data_o[c*2048+:2048]='0;end
  end
  logic fault_q;
  always_ff @(posedge clk_i)if(!rst_ni || !run_i)fault_q<=0;
    else if((|input_bad)||(|output_bad))fault_q<=1;
  assign fault_o=fault_q;
  assign busy_o=|column_busy;
endmodule
