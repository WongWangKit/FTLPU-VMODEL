`timescale 1ns/1ps
module sxm_stream_boundary_tb;
  localparam T=4,P=32;
  bit clk_i,rst_ni,run_i;
  always #5 clk_i=~clk_i;
  logic [T*32-1:0] east_valid_i,west_valid_i,east_valid_o,west_valid_o;
  logic [T*2048-1:0] east_data_i,west_data_i,east_data_o,west_data_o;
  logic [T*P*6-1:0] read_sel_i,write_sel_i;
  logic [T*P-1:0] consume_i,write_valid_i,read_valid_o;
  logic [T*P*64-1:0] write_data_i,read_data_o;
  logic conflict_o;
  lpu_sxm_stream_boundary #(.T(T),.PORTS(P)) dut(.*);
  localparam E=2*32+31, W=2*32+1, PASS=1*32+31, R=2*P+3;
  initial begin
    run_i=0; east_valid_i='0; west_valid_i='0; east_data_i='0; west_data_i='0;
    read_sel_i='0; write_sel_i='0; consume_i='0; write_valid_i='0; write_data_i='0;
    @(negedge clk_i); rst_ni=1; run_i=1;
    east_valid_i[E]=1; east_valid_i[PASS]=1; west_valid_i[W]=1;
    east_data_i[E*64+:64]=64'h0123456789abcdef;
    east_data_i[PASS*64+:64]=64'h7777; west_data_i[W*64+:64]=64'h4444;
    read_sel_i[R*6+:6]=63; read_sel_i[(R+1)*6+:6]=1;
    consume_i[R+:2]=3;
    #1;
    if(read_valid_o[R+:2]!==3 || read_data_o[R*64+:64]!==64'h0123456789abcdef ||
       read_data_o[(R+1)*64+:64]!==64'h4444 || (|east_valid_o) || (|west_valid_o))
      $fatal(1,"capture selectors or pass latency");
    @(posedge clk_i); #1;
    if(east_valid_o !== (128'd1<<PASS) || east_data_o[PASS*64+:64]!==64'h7777 || west_valid_o!=='0)
      $fatal(1,"consume suppressed another tile or leaked data");
    east_valid_i='0; west_valid_i='0; consume_i='0;
    write_valid_i[R+:2]=3; write_sel_i[R*6+:6]=63; write_sel_i[(R+1)*6+:6]=1;
    write_data_i[R*64+:64]=64'h5555; write_data_i[(R+1)*64+:64]=64'h6666;
    #1;
    if(!east_valid_o[E] || !west_valid_o[W] || east_data_o[E*64+:64]!==64'h5555 ||
       west_data_o[W*64+:64]!==64'h6666 || conflict_o) $fatal(1,"inject routing/latency");
    write_valid_i[P]=1; write_sel_i[P*6+:6]=63;
    #1;
    if(!conflict_o || east_data_o[PASS*64+:64]!==64'h7777) $fatal(1,"pass collision");
    write_valid_i[P]=0; write_sel_i[(R+1)*6+:6]=63;
    #1;
    if(!conflict_o || east_data_o[E*64+:64]!==64'h5555) $fatal(1,"duplicate injection");
    run_i=0; @(posedge clk_i); #1;
    if((|east_valid_o)||(|west_valid_o)||conflict_o) $fatal(1,"stop");
    $display("SXM_STREAM_BOUNDARY_PASS"); $finish;
  end
endmodule
