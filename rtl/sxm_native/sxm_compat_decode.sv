`timescale 1ns/1ps
// Effective-instruction boundary (no root register). Explicit wire families:
// 0: fixed VMODEL T4 raw (block T/P, output tile at bit 208);
// 1: fixed CModel raw (geometry-dependent, rows restricted to 0..8);
// 2: local API transport using CModel field locations, plus broadcast/consume.
// Family 2 is NOT a new ICU encoding. Family 3 is rejected.
module sxm_compat_decode #(
  parameter integer T=4,
  localparam integer LB=(T<4?5:$clog2(8*T)), TB=(T<4?3:$clog2(T)+1),
  localparam integer ROW=240+8*T*LB, USED=ROW+8+TB,
  localparam integer RAW_BITS=((USED+31)/32)*32
)(
  input wire [RAW_BITS-1:0] raw_i,
  input wire [1:0] family_i,
  input wire permute_i,
  output reg ok_o,
  output reg [95:0] src_o, dst_o,
  output reg [3:0] input_row_o, output_row_o,
  output reg [TB-1:0] tile_o,
  output wire [8*T*LB-1:0] map_o
);
  integer n,j,ns,nd;
  assign map_o=raw_i[240+:8*T*LB];
  always @* begin
    ns=int'(raw_i[10:6]); nd=int'(raw_i[15:11]);
    src_o=0; dst_o=0;
    // Raw uses East=0/West=1; inherited native adapter uses the reverse.
    for(n=0;n<16;n=n+1) begin
      src_o[n*6+:6]=raw_i[16+n*6+:6]^6'd32;
      dst_o[n*6+:6]=raw_i[112+n*6+:6]^6'd32;
    end
    input_row_o=raw_i[ROW+4+:4]; output_row_o=raw_i[ROW+:4];
    tile_o=raw_i[ROW+8+:TB];
    if(family_i==0) begin
      input_row_o=8; output_row_o=8; tile_o=TB'(raw_i[208+:3]);
    end
    ok_o=(raw_i[1:0]==(permute_i?2'd3:2'd2)) && family_i!=3 && nd==16;
    if(family_i==0 && T!=4) ok_o=0;
    if(family_i!=0) begin
      if(raw_i[RAW_BITS-1:USED]!=0 || int'(tile_o)>T) ok_o=0;
      for(n=0;n<8;n=n+1) if(raw_i[208+n*4+:4]>8) ok_o=0;
      for(n=0;n<8*T;n=n+1) if(int'(map_o[n*LB+:LB])>=8*T) ok_o=0;
      if(family_i==1 && (input_row_o>8 || output_row_o>8)) ok_o=0;
    end
    if(int'(tile_o)>T || input_row_o>9) ok_o=0;
    if(permute_i) begin
      if(ns!=16) ok_o=0;
    end else if(input_row_o>=8 || ns!=2) ok_o=0;
    // Product profile accepts ROW capture only. Keep P encodings and timing;
    // reject legacy block T and API broadcast T, never serialize them silently.
    // Reject aliases in stream lists: the target cannot consume/produce twice
    // at one physical selector. Arbitrary unique, non-contiguous lists work.
    for(n=0;n<16;n=n+1) begin
      if(n<ns) begin
        if(src_o[n*6+5]!=src_o[5]) ok_o=0;
        for(j=0;j<n;j=j+1) if(src_o[n*6+:6]==src_o[j*6+:6]) ok_o=0;
      end
      if(dst_o[n*6+5]!=dst_o[5]) ok_o=0;
      for(j=0;j<n;j=j+1) if(dst_o[n*6+:6]==dst_o[j*6+:6]) ok_o=0;
    end
  end
endmodule
