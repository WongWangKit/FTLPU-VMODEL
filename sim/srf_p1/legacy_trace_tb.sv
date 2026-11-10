`timescale 1ns/1ps
module srf_p1_legacy_trace_tb;
  localparam H=2,C=16,T=4,S=32,L=8,P=2,K=2;
  localparam NB=H*2*T*S, NS=H*2*C*T*S, NF=H*2*C*T;
  logic clk=0, rst_n=0;
  logic [NB-1:0] bv,bo;
  logic [NB*64-1:0] bd,bod;
  logic [NS*P-1:0] iv;
  logic [NS*P*64-1:0] idata;
  logic [NS*K-1:0] consume;
  logic [NS-1:0] sv;
  logic [NS*64-1:0] sd;
  logic [NF-1:0] collision,invalid;
  integer fd,ft,rc,seq,rst,nb,ni,nc,h,d,c,t,s,slot,idx,cycles=0;
  reg [63:0] word_data;
  reg [NB-1:0] pre_bv;
  reg [NB*64-1:0] pre_bd;
  reg [NF-1:0] pre_col,pre_inv;
  string vectors,trace_file;
  always #5 clk=~clk;
  ftlpu_sr_fabric #(.HEMISPHERES(H),.COLUMNS(C),.SUPERLANES(T),.STREAMS(S),
    .LANES(L),.DATA_BITS(8),.LOCAL_PRODUCERS(P),.LOCAL_CONSUMERS(K)) dut (
    .clk_i(clk),.rst_ni(rst_n),.boundary_valid_i(bv),.boundary_data_i(bd),
    .boundary_valid_o(bo),.boundary_data_o(bod),.inject_valid_i(iv),.inject_data_i(idata),
    .consume_i(consume),.collision_o(collision),.invalid_consume_o(invalid),
    .state_valid_o(sv),.state_data_o(sd));
  task clear_inputs;
    begin bv='0;bd='0;iv='0;idata='0;consume='0; end
  endtask
  initial begin
    clear_inputs();
    if (!$value$plusargs("VECTORS=%s",vectors)) $fatal(1,"missing VECTORS");
    if (!$value$plusargs("TRACE=%s",trace_file)) $fatal(1,"missing TRACE");
    fd=$fopen(vectors,"r"); ft=$fopen(trace_file,"w");
    if (!fd || !ft) $fatal(1,"file open failed");
    repeat(2) @(negedge clk);
    rc=$fscanf(fd,"%d %d %d %d %d",seq,rst,nb,ni,nc);
    while(rc==5) begin
      @(negedge clk); clear_inputs();
      if (rst) begin
        rst_n=0; #1;
        if(sv!=='0) $fatal(1,"reset state not empty seq=%0d",seq);
        @(negedge clk);
      end
      rst_n=1;
      for(integer j=0;j<nb;j=j+1) begin
        rc=$fscanf(fd,"%d %d %d %d %h",h,d,t,s,word_data);
        if(rc!=5) $fatal(1,"bad boundary record");
        idx=((h*2+d)*T+t)*S+s; bv[idx]=1; bd[idx*64+:64]=word_data;
      end
      for(integer j=0;j<ni;j=j+1) begin
        rc=$fscanf(fd,"%d %d %d %d %d %d %h",h,d,c,t,slot,s,word_data);
        if(rc!=7) $fatal(1,"bad inject record");
        idx=(((((h*2+d)*C+c)*T+t)*P+slot)*S+s);
        iv[idx]=1; idata[idx*64+:64]=word_data;
      end
      for(integer j=0;j<nc;j=j+1) begin
        rc=$fscanf(fd,"%d %d %d %d %d %d",h,d,c,t,slot,s);
        if(rc!=6) $fatal(1,"bad consume record");
        idx=(((((h*2+d)*C+c)*T+t)*K+slot)*S+s); consume[idx]=1;
      end
      #1; pre_bv=bo; pre_bd=bod; pre_col=collision; pre_inv=invalid;
      @(posedge clk); #1;
      $fdisplay(ft,"%0d %h %h %h %h %h %h",seq,pre_bv,pre_bd,pre_col,pre_inv,sv,sd);
      cycles=cycles+1;
      rc=$fscanf(fd,"%d %d %d %d %d",seq,rst,nb,ni,nc);
    end
    if(rc!=-1) $fatal(1,"truncated cycle header rc=%0d",rc);
    $fclose(fd); $fclose(ft);
    $display("SRF_P1_LEGACY_TRACE PASS cycles=%0d",cycles); $finish;
  end
  initial begin #1000000; $fatal(1,"watchdog"); end
endmodule
