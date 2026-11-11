`timescale 1ns/1ps
// Legacy T/P control and routing, sharing sxm_row_core payload storage.
// T captures at root R + tile; P outputs in its effective instruction cycle.
// Missing ready tiles are skipped for diagonal head/tail, never queued.
module sxm_compat_engine #(
  parameter integer T=4,
  localparam integer TW=$clog2(T), LB=(T<4?5:TW+3), TB=(T<4?3:TW+1),
  localparam integer RAW_BITS=((240+8*T*LB+8+TB+31)/32)*32
)(
  input wire clk_i, rst_ni,
  input wire t_valid_i, p_valid_i,
  input wire [1:0] t_family_i, p_family_i,
  input wire [RAW_BITS-1:0] t_raw_i, p_raw_i,
  output wire [T*96-1:0] read_req_o,
  input wire [T*16-1:0] read_valid_i,
  input wire [T*1024-1:0] read_data_i,
  output reg [T*16-1:0] consume_o, write_valid_o,
  output reg [T*96-1:0] write_sel_o,
  output reg [T*1024-1:0] write_data_o,
  output reg [T*8-1:0] bank_write_rows_o,
  output reg [T*1024-1:0] bank_write_data_o,
  input wire [T*1024-1:0] bank_read_data_i,
  output reg [2:0] fault_o, // malformed T, capture, malformed/state P
  output wire busy_o
);
  wire tok,pok;
  wire [95:0] ts,td,ps,pd;
  wire [3:0] tr,pr,unused_tr,unused_pr;
  wire [TB-1:0] pt,unused_tt;
  wire [8*T*LB-1:0] pm,unused_tm;
  sxm_compat_decode #(.T(T)) dt(.raw_i(t_raw_i),.family_i(t_family_i),.permute_i(1'b0),
    .ok_o(tok),.src_o(ts),.dst_o(td),.input_row_o(tr),.output_row_o(unused_pr),.tile_o(unused_tt),.map_o(unused_tm));
  sxm_compat_decode #(.T(T)) dp(.raw_i(p_raw_i),.family_i(p_family_i),.permute_i(1'b1),
    .ok_o(pok),.src_o(ps),.dst_o(pd),.input_row_o(unused_tr),.output_row_o(pr),.tile_o(pt),.map_o(pm));
  // Only the existing northward T control hops. No payload pipeline/FIFO.
  reg [195:0] north_q[1:T-1];
  reg [T-1:1] north_valid_q;
  wire [195:0] tc[0:T-1];
  wire [T-1:0] tv;
  assign tc[0]={tr,td,ts}; assign tv[0]=t_valid_i && tok;
  for(genvar k=1;k<T;k=k+1) begin:g_north
    assign tc[k]=north_q[k]; assign tv[k]=north_valid_q[k];
  end
  for(genvar k=0;k<T;k=k+1) begin:g_req
    assign read_req_o[k*96+:96]=tc[k][95:0];
  end
  reg [7:0] rows_q[0:T-1];
  wire [T-1:0] occupied;
  for(genvar k=0;k<T;k=k+1) begin:g_occupied
    assign occupied[k]=|rows_q[k];
  end
  reg [95:0] metadata_q[0:T-1];
  reg [T-1:0] claimed_q;
  reg [TW-1:0] destination_q[0:T-1];
  reg [T-1:0] release_mask, capture_ok, p_fire;
  reg [T-1:0] seen_sources;
  reg map_ok, state_ok, present;
  integer d,s,l,q,b,k,j,row,first_row,last_row,ninputs,source_lane;
  always @* begin
    consume_o=0;write_valid_o=0;write_sel_o=0;write_data_o=0;
    bank_write_rows_o=0;bank_write_data_o=0;
    release_mask=0;capture_ok=0;p_fire=0;seen_sources=0;
    fault_o=0;fault_o[0]=t_valid_i && !tok;
    map_ok=pok;state_ok=1;present=0;
    s=0;row=0;first_row=0;last_row=0;ninputs=0;source_lane=0;
    for(d=0;d<T;d=d+1) begin
      s=int'(pm[d*8*LB+:LB])/8;
      if(s>=T) map_ok=0;
      else begin
        if(seen_sources[s]) map_ok=0;
        seen_sources[s]=1;
      end
      for(l=0;l<8;l=l+1) if(int'(pm[(d*8+l)*LB+:LB])/8!=s) map_ok=0;
      // The inherited native raw path faults an unavailable concrete tile;
      // CModel API/raw skip it. ALL skips absent diagonal tiles in both.
      if(s<T && p_family_i==0 && int'(pt)==d && rows_q[s]!=255) state_ok=0;
      if(s<T && (int'(pt)==T || int'(pt)==d) && rows_q[s]==255) begin
        if(metadata_q[s]!=ps || (claimed_q[s] && int'(destination_q[s])!=d)) state_ok=0;
      end
    end
    if(p_valid_i && (!map_ok || !state_ok)) fault_o[2]=1;
    if(p_valid_i && map_ok && state_ok) begin
      first_row=pr==8 ? 0 : (pr>=9 ? int'(pr)-9 : int'(pr));
      last_row=pr==8 ? 7 : first_row;
      for(d=0;d<T;d=d+1) begin
        s=int'(pm[d*8*LB+:LB])/8;
        if((int'(pt)==T || int'(pt)==d) && rows_q[s]==255) begin
          p_fire[d]=1;
          write_sel_o[d*96+:96]=pd;
          for(q=0;q<8;q=q+1) if(q>=first_row && q<=last_row)
            for(b=0;b<2;b=b+1) begin
              write_valid_o[d*16+q*2+b]=1;
              for(l=0;l<8;l=l+1) begin
                source_lane=int'(pm[(d*8+l)*LB+:LB])%8;
                write_data_o[(d*16+q*2+b)*64+l*8+:8]=
                  bank_read_data_i[(s*16+q*2+b)*64+source_lane*8+:8];
              end
            end
          if(pr>=7) release_mask[s]=1;
        end
      end
    end
    // Release old object and capture replacement at the SAME edge is legal.
    // P reads pre-edge storage, so last-row T has no same-edge bypass to P.
    for(k=0;k<T;k=k+1) if(tv[k]) begin
      row=int'(tc[k][195:192]); ninputs=2;
      present=1;
      for(j=0;j<16;j=j+1) if(j<ninputs && !read_valid_i[k*16+j]) present=0;
      capture_ok[k]=present && (rows_q[k]!=255 || release_mask[k]) &&
        (rows_q[k]==0 || release_mask[k] || metadata_q[k]==tc[k][191:96]) &&
        (!claimed_q[k] || release_mask[k]);
      if(!capture_ok[k]) fault_o[1]=1;
      else begin
        for(j=0;j<16;j=j+1) if(j<ninputs) consume_o[k*16+j]=1;
        for(q=0;q<8;q=q+1) if(row==q) begin
          bank_write_rows_o[k*8+q]=1;
          for(b=0;b<2;b=b+1)
            bank_write_data_o[(k*16+q*2+b)*64+:64]=read_data_i[(k*16+b)*64+:64];
        end
      end
    end
  end
  assign busy_o=(|occupied) || (|north_valid_q);
  integer n,ss;
  always @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      north_valid_q<=0;claimed_q<=0;
      for(n=1;n<T;n=n+1) north_q[n]<=0;
      for(n=0;n<T;n=n+1) begin rows_q[n]<=0;metadata_q[n]<=0;destination_q[n]<=0;end
    end else begin
      for(n=1;n<T;n=n+1) begin
        north_valid_q[n]<=tv[n-1];
        if(tv[n-1]) north_q[n]<=tc[n-1];
      end
      for(n=0;n<T;n=n+1) if(p_fire[n]) begin
        ss=int'(pm[n*8*LB+:LB])/8;
        claimed_q[ss]<=1;destination_q[ss]<=TW'(n);
      end
      for(n=0;n<T;n=n+1) begin
        if(release_mask[n]) begin rows_q[n]<=0;claimed_q[n]<=0;end
        if(capture_ok[n]) begin
          rows_q[n]<=(release_mask[n]?8'b0:rows_q[n]) | bank_write_rows_o[n*8+:8];
          metadata_q[n]<=tc[n][191:96];
        end
      end
    end
  end
endmodule
