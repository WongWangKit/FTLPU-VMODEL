// Native SXM selector: bit 5 = East, bits 4:0 = stream in that direction.
// Capture reads this cycle's inputs. Unconsumed inputs advance one register;
// Permute injects at the output of that register, on its scheduled cycle.
module lpu_sxm_stream_boundary #(
  parameter integer T = 4, PORTS = 16
) (
  input wire clk_i, rst_ni, run_i,
  input wire [T*32-1:0] east_valid_i, west_valid_i,
  input wire [T*32*64-1:0] east_data_i, west_data_i,
  output logic [T*32-1:0] east_valid_o, west_valid_o,
  output logic [T*32*64-1:0] east_data_o, west_data_o,
  input wire [T*PORTS*6-1:0] read_sel_i, write_sel_i,
  output wire [T*PORTS-1:0] read_valid_o,
  output wire [T*PORTS*64-1:0] read_data_o,
  input wire [T*PORTS-1:0] consume_i, write_valid_i,
  input wire [T*PORTS*64-1:0] write_data_i,
  output wire conflict_o
);
  wire [T-1:0] collision;
  assign conflict_o = |collision;
  for (genvar t=0; t<T; t++) begin : g_tile
    logic [31:0] east_consumed, west_consumed, ev, wv;
    logic [2047:0] ed, wd;
    logic clash;
    assign collision[t] = clash;
    for (genvar p=0; p<PORTS; p++) begin : g_read
      localparam integer N=t*PORTS+p;
      wire [5:0] sel=read_sel_i[N*6+:6];
      wire [4:0] s=sel[4:0];
      assign read_valid_o[N]=run_i && (sel[5]?east_valid_i[t*32+s]:west_valid_i[t*32+s]);
      assign read_data_o[N*64+:64]=sel[5]?east_data_i[(t*32+s)*64+:64]:west_data_i[(t*32+s)*64+:64];
    end
    always_comb begin
      east_consumed='0; west_consumed='0;
      for (int p=0; p<PORTS; p++) if(consume_i[t*PORTS+p]) begin
        if(read_sel_i[(t*PORTS+p)*6+5])
          east_consumed[read_sel_i[(t*PORTS+p)*6+:5]]=1;
        else west_consumed[read_sel_i[(t*PORTS+p)*6+:5]]=1;
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if(!rst_ni) begin ev<='0; wv<='0; end
      else begin
        ev<=run_i?(east_valid_i[t*32+:32]&~east_consumed):'0;
        wv<=run_i?(west_valid_i[t*32+:32]&~west_consumed):'0;
      end
    end
    always_ff @(posedge clk_i) begin
      ed<=east_data_i[t*2048+:2048]; wd<=west_data_i[t*2048+:2048];
    end
    always_comb begin
      logic [31:0] e,w;
      logic [2047:0] de,dw;
      logic [5:0] sel;
      e=ev; w=wv; de=ed; dw=wd; clash=0; sel='0;
      for(int p=0; p<PORTS; p++) if(rst_ni && run_i && write_valid_i[t*PORTS+p]) begin
        sel=write_sel_i[(t*PORTS+p)*6+:6];
        if(sel[5]) begin
          if(e[sel[4:0]]) clash=1;
          else begin e[sel[4:0]]=1; de[sel[4:0]*64+:64]=write_data_i[(t*PORTS+p)*64+:64]; end
        end else begin
          if(w[sel[4:0]]) clash=1;
          else begin w[sel[4:0]]=1; dw[sel[4:0]*64+:64]=write_data_i[(t*PORTS+p)*64+:64]; end
        end
      end
      east_valid_o[t*32+:32]=e; west_valid_o[t*32+:32]=w;
      east_data_o[t*2048+:2048]=de; west_data_o[t*2048+:2048]=dw;
    end
  end
endmodule
