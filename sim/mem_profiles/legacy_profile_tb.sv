`timescale 1ns/1ps
// Exercise the existing 47-bit wrapper at each formal profile, without Tap
// or any added format port. Full c7/Tap is tested in integration_tb instead.
module mem_profiles_legacy_tb #(parameter integer PROFILE=16);
  localparam integer T=lpu_native_config_pkg::tile_rows(PROFILE),P=lpu_native_config_pkg::mem_depth_rows(PROFILE),M=104*T;
  logic clk=0,rst_n=0;
  logic [103:0] valid='0;
  logic [104*47-1:0] packet='0;
  wire [103:0] native_valid,command_fault,bank_fault;
  wire [3327:0] native_word;
  logic [64*T-1:0] boundary_valid='0;
  logic [64*T*64-1:0] boundary_data='0;
  wire [2*16*T*32-1:0] state_valid;
  wire [2*16*T*32*64-1:0] state_data;
  wire [M-1:0] response_valid;
  wire [M*64-1:0] response_data;
  wire [2*16*T-1:0] collision;
  wire mem_fault,busy;
  lpu_mem_srf_command_integration #(.P_LPU_PROFILE(PROFILE)) dut(
    .clk_i(clk),.rst_ni(rst_n),.vmodel_issue_valid_i(valid),.vmodel_issue_instruction_i(packet),
    .native_issue_valid_o(native_valid),.native_issue_o(native_word),.command_fault_o(command_fault),
    .boundary_valid_i(boundary_valid),.boundary_data_i(boundary_data),.boundary_valid_o(),.boundary_data_o(),
    .state_valid_o(state_valid),.state_data_o(state_data),.mem_boundary_consume_o(),
    .mem_producer_valid_o(response_valid),.mem_producer_data_o(response_data),.mem_producer_direction_o(),
    .mem_producer_stream_o(),.mem_producer_boundary_o(),.srf_collision_o(collision),.srf_invalid_consume_o(),
    .mem_internal_collision_o(),.mem_bank_fault_valid_o(bank_fault),.mem_fault_valid_o(mem_fault),.mem_busy_o(busy));
  function automatic [63:0] pattern(input integer tile);
    pattern=64'h1020304050607080 ^ (64'h0101010101010101*tile);
  endfunction
  task automatic step;
    #4;clk=1;#1;clk=0;#1;
  endtask
  integer i,index,drain;
  initial begin
    step();rst_n=1;
    for(i=0;i<=T;i=i+1)begin
      boundary_valid=0;boundary_data=0;valid=0;packet=0;
      if(i<T)begin boundary_valid[i*32]=1;boundary_data[i*32*64+:64]=pattern(i);end
      if(i==1)begin valid=1;packet[2:0]=1;packet[30:15]=P-1;packet[14:9]=63;end
      #1;
      if(i==1 && (!native_valid[0] || native_word[31:0]!==32'(((P-1)<<15)|1)))$fatal(1,"legacy normalization or issue latency");
      step();if(command_fault !== '0 || bank_fault !== '0 || mem_fault)$fatal(1,"legal legacy Write failed");
    end
    boundary_valid=0;valid=0;packet=0;step();
    for(i=0;i<=T;i=i+1)begin
      valid=0;packet=0;
      if(i==0)begin valid=1;packet[2:0]=0;packet[8:3]=7;packet[30:15]=P-1;end
      step();
      if(i<T && (!response_valid[i] || response_data[i*64+:64] !== pattern(i)))$fatal(1,"legacy profile Read data tile=%0d",i);
      if(i>0)begin
        index=(T+i-1)*32+7;
        if(!state_valid[index] || state_data[index*64+:64] !== pattern(i-1))$fatal(1,"legacy profile B commit tile=%0d",i-1);
      end
      if(command_fault !== '0 || bank_fault !== '0 || mem_fault || collision !== '0)$fatal(1,"legal legacy Read fault");
    end
    valid=0;drain=0;
    while(busy || |response_valid || |state_valid)begin step();drain=drain+1;if(drain>40+T)$fatal(1,"legacy profile did not drain");end
    valid=1;packet=0;packet[31]=1;#1;
    if(!command_fault[0] || native_valid[0])$fatal(1,"legacy bit31 must not become Tap");
    step();valid=0;packet=0;step();
    valid=1;packet[30:15]=P;#1;
    if(command_fault[0] || !native_valid[0] || !bank_fault[0])$fatal(1,"profile rowP not rejected at native boundary");
    step();valid=0;packet=0;step();
    if(|response_valid || busy)$fatal(1,"illegal legacy row entered command wave");
    $display("MEM_LEGACY_PROFILE TEST_PASS profile=%0d T=%0d P=%0d Read_Write_map_highbits_rowP",PROFILE,T,P);$finish;
  end
endmodule
