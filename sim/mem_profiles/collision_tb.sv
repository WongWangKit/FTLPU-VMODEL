`timescale 1ns/1ps
module mem_profiles_collision_tb #(parameter integer PROFILE=16);
  localparam integer T=lpu_native_config_pkg::tile_rows(PROFILE), M=104*T;
  logic clk=0,rst_n=0;
  logic [103:0] issue_valid='0;
  logic [3327:0] issue='0;
  logic [64*T-1:0] boundary_valid='0;
  logic [64*T*64-1:0] boundary_data='0;
  wire [2*16*T*32-1:0] state_valid;
  wire [2*16*T*32*64-1:0] state_data;
  wire [M-1:0] response_valid,internal_collision;
  wire [2*16*T-1:0] collision;
  wire busy;
  lpu_mem_srf_integration #(.P_LPU_PROFILE(PROFILE)) dut(
    .clk_i(clk),.rst_ni(rst_n),.bank_issue_valid_i(issue_valid),.bank_issue_i(issue),
    .boundary_valid_i(boundary_valid),.boundary_data_i(boundary_data),
    .boundary_valid_o(),.boundary_data_o(),.state_valid_o(state_valid),.state_data_o(state_data),
    .mem_boundary_consume_o(),.mem_producer_valid_o(response_valid),.mem_producer_data_o(),
    .mem_producer_direction_o(),.mem_producer_stream_o(),.mem_producer_boundary_o(),
    .srf_collision_o(collision),.srf_invalid_consume_o(),.mem_internal_collision_o(internal_collision),
    .mem_bank_fault_valid_o(),.mem_fault_valid_o(),.mem_busy_o(busy));
  function automatic integer state_cell(input integer column,tile,stream);
    state_cell=(column*T+tile)*32+stream;
  endfunction
  task automatic step;
    #4;clk=1;#1;clk=0;#1;
  endtask
  localparam integer I=(T>1)?$clog2(T):1;
  integer p,t,i,count,up,index,slot0,slot1,drain,checks=0,bad_case;
  reg expected;
  initial begin
    for(count=0;count<=3;count=count+1)for(up=0;up<=1;up=up+1)begin
      rst_n=0;issue_valid=0;boundary_valid=0;step();rst_n=1;
      for(i=0;i<=T;i=i+1)begin
        issue_valid=0;issue=0;boundary_valid=0;boundary_data=0;
        if(i==0)for(p=0;p<count;p=p+1)begin
          issue_valid[p]=1;issue[p*32+:32]=(7<<3); // cold Read row0 -> East7
        end
        if(i<T)begin
          if(up)begin boundary_valid[i*32+7]=1;boundary_data[(i*32+7)*64+:64]=64'h12340000+i;end
          boundary_valid[i*32+8]=1;boundary_data[(i*32+8)*64+:64]=64'hfedc0000+i;
        end
        step();
        if(i<T)begin
          for(p=0;p<count;p=p+1)if(response_valid[p*T+i]!==1)
            $fatal(1,"missing raw candidate count=%0d tile=%0d producer=%0d",count,i,p);
          // Packed SRF inject is ((column*T+tile)*Q+slot)*streams+stream.
          slot0=((1*T+i)*2)*32+7;slot1=slot0+32;
          if(dut.srf_inject_valid[slot0] !== (count>=1) || dut.srf_inject_valid[slot1] !== (count>=2))
            $fatal(1,"lost multiplicity count=%0d up=%0d tile=%0d",count,up,i);
          if(collision[T+i] !== (count+up>=2))
            $fatal(1,"collision count=%0d up=%0d tile=%0d",count,up,i);
          if(count>=2)for(p=0;p<count;p=p+1)begin
            if(!internal_collision[p*T+i])$fatal(1,"lost MEM diagnostic");
            if(!dut.mem_bank_fault_tile_valid[p] || dut.mem_bank_fault_tile_id[p*I+:I] !== I'(i))
              $fatal(1,"fault tile identity truncated producer=%0d tile=%0d",p,i);
          end
        end
        if(i>0)begin
          t=i-1;expected=(count+up==1);
          index=state_cell(1,t,7);
          if(state_valid[index] !== expected)$fatal(1,"wrong conflict commit count=%0d up=%0d tile=%0d",count,up,t);
          if(expected && state_data[index*64+:64] !== (up?64'h12340000+t:64'b0))$fatal(1,"unique payload");
          index=state_cell(1,t,8);
          if(!state_valid[index] || state_data[index*64+:64] !== 64'hfedc0000+t)begin
            $display("DEBUG leaf_col1_tile0=%h top_constant=%h boundary_input=%h",dut.u_srf.u_lane.gen_direction[0].u_direction.gen_column[1].u_column.gen_superlane[0].u_leaf.data_state_q[8*64+:64],state_data[(T*32+8)*64+:64],boundary_data[8*64+:64]);
            $fatal(1,"unrelated cell discarded count=%0d up=%0d tile=%0d valid=%b expected=%h actual=%h col0=%h",count,up,t,state_valid[index],64'hfedc0000+t,state_data[index*64+:64],state_data[(t*32+8)*64+:64]);
          end
          checks=checks+1;
        end
      end
      issue_valid=0;boundary_valid=0;drain=0;
      while(busy || |response_valid || |state_valid)begin
        step();drain=drain+1;if(drain>40+T)$fatal(1,"collision suite did not drain");
      end
    end
    // A new malformed issue must not cancel an older legal tile wave.
    for(bad_case=0;bad_case<3;bad_case=bad_case+1)begin
      rst_n=0;issue_valid=0;boundary_valid=0;step();rst_n=1;
      issue_valid=1;issue=0;issue[31:0]=(7<<3);step();
      if(!response_valid[0])$fatal(1,"missing initial safety Read");
      for(i=1;i<=T;i=i+1)begin
        issue_valid=0;issue=0;
        if(i==1)begin
          issue_valid=1;
          case(bad_case)
            0: issue[31:0]=(lpu_native_config_pkg::mem_depth_rows(PROFILE)<<15)|(7<<3);
            1: issue[31:0]=32'h40000000|(7<<3);
            2: issue[31:0]=(1<<9)|(7<<3);
          endcase
          #1;if(!dut.mem_bank_fault_valid_o[0])$fatal(1,"malformed native issue not rejected");
        end
        step();
        if(i<T && !response_valid[i])$fatal(1,"malformed issue killed old tile wave tile=%0d",i);
        if(!state_valid[state_cell(1,i-1,7)])$fatal(1,"malformed issue killed old SRF commit");
      end
      issue_valid=0;drain=0;
      while(busy || |response_valid || |state_valid)begin
        step();drain=drain+1;if(drain>40+T)$fatal(1,"safety wave did not drain");
      end
    end
    $display("MEM_PROFILES_COLLISION TEST_PASS profile=%0d checks=%0d cases=0/1/2/3_MEM_plus_0/1_upstream_equal_payload",PROFILE,checks);
    $finish;
  end
endmodule
