`timescale 1ns/1ps
module srf_p1_lane_compare_tb;
  localparam H=2,C=16,T=4,S=32,L=8,P=2,K=2;
  localparam NB=H*2*T*S,NS=H*2*C*T*S,NF=H*2*C*T;
  logic clk=0,rst_n=0;
  logic [NB*L-1:0] bv,bo,expected_bo;
  logic [NB*64-1:0] bd,bod,expected_bod;
  logic [NS*P*L-1:0] iv;
  logic [NS*P*64-1:0] idata;
  logic [NS*K*L-1:0] consume;
  logic [NS*L-1:0] sv,expected_sv;
  logic [NS*64-1:0] sd,expected_sd;
  logic [NF-1:0] collision,invalid,expected_col,expected_inv;
  integer fd,rc,seq,rst,nb,ni,nc,nbo,npost,h,d,c,t,s,slot,api,idx,cycles=0;
  integer valid_bytes=0,boundary_bytes=0,negative_cycles=0;
  integer active_state[0:NS-1],active_boundary[0:NB-1];
  logic [7:0] mask;
  logic [63:0] payload;
  string file_name,error_kind;
  always #5 clk=~clk;
  ftlpu_sr_fabric_lane dut(.clk_i(clk),.rst_ni(rst_n),.boundary_valid_i(bv),.boundary_data_i(bd),
    .boundary_valid_o(bo),.boundary_data_o(bod),.inject_valid_i(iv),.inject_data_i(idata),
    .consume_i(consume),.collision_o(collision),.invalid_consume_o(invalid),.state_valid_o(sv),.state_data_o(sd));
  task clear_inputs;
    begin bv='0;bd='x;iv='0;idata='x;consume='0; end
  endtask
  initial begin
    clear_inputs();
    if(!$value$plusargs("VECTORS=%s",file_name))$fatal(1,"missing VECTORS");
    fd=$fopen(file_name,"r");if(!fd)$fatal(1,"open vectors failed");
    repeat(2)@(negedge clk);
    rc=$fscanf(fd,"%d %d %d %d %d %d %d %h %h %s",seq,rst,nb,ni,nc,nbo,npost,expected_col,expected_inv,error_kind);
    while(rc==10)begin
      if(seq!=cycles)$fatal(1,"nonsequential cycle");
      @(negedge clk);clear_inputs();
      if(rst)begin rst_n=0;#1;if(sv!=='0)$fatal(1,"reset state cycle=%0d",seq);@(negedge clk);end
      rst_n=1;
      for(integer j=0;j<nb;j=j+1)begin
        rc=$fscanf(fd,"%d %d %d %d %h %h %d",h,d,t,s,mask,payload,api);if(rc!=7)$fatal(1,"boundary input format");
        idx=((h*2+d)*T+t)*S+s;bv[idx*8+:8]=mask;bd[idx*64+:64]=payload;
      end
      for(integer j=0;j<ni;j=j+1)begin
        rc=$fscanf(fd,"%d %d %d %d %d %d %h %h %d",h,d,c,t,slot,s,mask,payload,api);if(rc!=9)$fatal(1,"injection format");
        idx=(((((h*2+d)*C+c)*T+t)*P+slot)*S+s);iv[idx*8+:8]=mask;idata[idx*64+:64]=payload;
      end
      for(integer j=0;j<nc;j=j+1)begin
        rc=$fscanf(fd,"%d %d %d %d %d %d %h %d",h,d,c,t,slot,s,mask,api);if(rc!=8)$fatal(1,"consume format");
        idx=(((((h*2+d)*C+c)*T+t)*K+slot)*S+s);
        if(api==2)mask=mask & sv[(((((h*2+d)*C+c)*T+t)*S+s)*8)+:8];
        consume[idx*8+:8]=mask;
      end
      expected_bo='0;expected_bod='x;expected_sv='0;expected_sd='x;
      for(integer j=0;j<nbo;j=j+1)begin
        rc=$fscanf(fd,"%d %d %d %d %h %h",h,d,t,s,mask,payload);if(rc!=6)$fatal(1,"boundary expected format");
        idx=((h*2+d)*T+t)*S+s;expected_bo[idx*8+:8]=mask;expected_bod[idx*64+:64]=payload;active_boundary[j]=idx;
      end
      for(integer j=0;j<npost;j=j+1)begin
        rc=$fscanf(fd,"%d %d %d %d %d %h %h",h,d,c,t,s,mask,payload);if(rc!=7)$fatal(1,"state expected format");
        idx=((((h*2+d)*C+c)*T+t)*S+s);expected_sv[idx*8+:8]=mask;expected_sd[idx*64+:64]=payload;active_state[j]=idx;
      end
      #1;
      if(bo!==expected_bo)$fatal(1,"boundary valid mismatch cycle=%0d actual=%h expected=%h",seq,bo,expected_bo);
      if(collision!==expected_col || invalid!==expected_inv)$fatal(1,"fault mismatch cycle=%0d col=%h/%h inv=%h/%h",seq,collision,expected_col,invalid,expected_inv);
      for(integer j=0;j<nbo;j=j+1)begin
        idx=active_boundary[j];
        for(integer l=0;l<L;l=l+1)if(expected_bo[idx*L+l])begin
          if(bod[(idx*L+l)*8+:8]!==expected_bod[(idx*L+l)*8+:8])$fatal(1,"boundary byte cycle=%0d segment=%0d lane=%0d",seq,idx,l);
          boundary_bytes=boundary_bytes+1;
        end
      end
      @(posedge clk);#1;
      if(sv!==expected_sv)$fatal(1,"state valid mismatch cycle=%0d actual=%h expected=%h",seq,sv,expected_sv);
      for(integer j=0;j<npost;j=j+1)begin
        idx=active_state[j];
        for(integer l=0;l<L;l=l+1)if(expected_sv[idx*L+l])begin
          if(sd[(idx*L+l)*8+:8]!==expected_sd[(idx*L+l)*8+:8])$fatal(1,"state byte mismatch cycle=%0d segment=%0d lane=%0d actual=%h expected=%h",seq,idx,l,sd[(idx*L+l)*8+:8],expected_sd[(idx*L+l)*8+:8]);
          valid_bytes=valid_bytes+1;
        end
      end
      if(error_kind!="none")negative_cycles=negative_cycles+1;
      cycles=cycles+1;
      if(cycles%1000==0)$display("LANE_PROGRESS cycles=%0d",cycles);
      rc=$fscanf(fd,"%d %d %d %d %d %d %d %h %h %s",seq,rst,nb,ni,nc,nbo,npost,expected_col,expected_inv,error_kind);
    end
    if(rc!=-1)$fatal(1,"truncated cycle header rc=%0d",rc);
    $fclose(fd);$display("SRF_LANE TEST_PASS cycles=%0d negative=%0d state_bytes=%0d boundary_bytes=%0d",cycles,negative_cycles,valid_bytes,boundary_bytes);$finish;
  end
  initial begin #10000000;$fatal(1,"lane watchdog");end
endmodule
