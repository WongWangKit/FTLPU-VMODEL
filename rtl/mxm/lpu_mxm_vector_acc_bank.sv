// One logical column: a synchronous lookahead read and a result write per
// edge on two single-port bank sets. owner[row] locates the latest copy.
// If lookahead aliases this write, bypass its D; if it reads elsewhere,
// place the write on the other port. Neither stride nor parity is assumed.
module lpu_mxm_vector_acc_bank #(parameter integer DEPTH=512,
  localparam AW=$clog2(DEPTH), PAGES=(DEPTH+511)/512
) (input wire clk_i,rst_ni,pre_i,write_i,
   input wire [AW-1:0] pre_addr_i,write_addr_i,
   input wire [255:0] write_data_i,output wire [255:0] read_data_o);
  logic [DEPTH-1:0] owner;
  wire hit=pre_i && write_i && pre_addr_i==write_addr_i;
  wire rd=pre_i && !hit;
  wire rb=owner[pre_addr_i];
  // An uninitialised logical row is masked at the caller; still keep its
  // owner defined so that a first read cannot steer a concurrent write to X.
  wire wb=rd ? !rb : write_addr_i[0];
  logic forwarded,bank_q;
  logic [AW-1:0] address_q;
  logic [255:0] bypass_q;
  wire [255:0] out[2][PAGES];
  always_ff @(posedge clk_i)begin
    if(!rst_ni)begin owner<='0;forwarded<=0;bank_q<=0;address_q<='0;end
    else begin
      if(write_i)owner[write_addr_i]<=wb;
      if(pre_i)begin forwarded<=hit;bank_q<=rb;address_q<=pre_addr_i;end
      if(hit)bypass_q<=write_data_i;
    end
  end
  for(genvar b=0;b<2;b++)for(genvar p=0;p<PAGES;p++)begin: gen_mem
    wire re=rst_ni && rd && rb==b && (pre_addr_i>>9)==p;
    wire we=rst_ni && write_i && wb==b && (write_addr_i>>9)==p;
    lpu_mxm_accumulator_sram u_ram(.clk_i,.req_valid_i(re||we),.write_i(we),
      .address_i(we?9'(write_addr_i):9'(pre_addr_i)),.write_data_i,.write_mask_i({256{1'b1}}),
      .read_data_o(out[b][p]));
  end
  assign read_data_o=forwarded?bypass_q:out[bank_q][address_q>>9];
endmodule
