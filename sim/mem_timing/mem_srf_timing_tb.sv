`timescale 1ns/1ps

// Actual MEM/SRF integration, with an absolute-cycle public-port oracle.
// A Read at E_t reaches row r's response at t+r*hop and SR column c at
// t+r*hop+c (East injection is at column 1). All reads use cold row 0.
module mem_srf_timing_tb #(
  parameter integer ROWS=4,
  parameter integer RAW_INGRESS=0,
  parameter integer PHYSICAL_ROWS=32
);
  localparam integer COLUMNS=16, STREAMS=32, ENTRIES=8*ROWS;
  localparam integer STATES=2*COLUMNS*ROWS*STREAMS;
  logic clk=0,rst_n=0;
  logic [7:0] issue_valid=0;
  logic [255:0] issue=0;
  wire [7:0] native_valid,adapter_fault;
  wire [255:0] native_issue;
  wire [STATES-1:0] state_valid;
  wire [STATES*64-1:0] state_data;
  wire [ENTRIES-1:0] response_valid,internal_collision;
  wire [ENTRIES*64-1:0] response_data;
  wire [ENTRIES*5-1:0] response_stream;
  wire [ENTRIES-1:0] response_direction;
  wire [2*COLUMNS*ROWS-1:0] collision,invalid_consume;
  wire fault;
  integer issued_at[0:255],issued_hop[0:255];
  integer count=0,cycles=0,checked_states=0;

  if(RAW_INGRESS)begin:gen_raw_ingress
    for(genvar b=0;b<8;b=b+1)begin:gen_adapter
      mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(PHYSICAL_ROWS)) adapter(
        .issue_valid_i(issue_valid[b]),.issue_instruction_i(issue[b*32+:32]),
        .native_valid_o(native_valid[b]),.native_command_o(native_issue[b*32+:32]),
        .command_fault_o(adapter_fault[b]));
    end
  end else begin:gen_direct_ingress
    assign native_valid=issue_valid;assign native_issue=issue;assign adapter_fault=0;
  end
  lpu_mem_srf_integration #(.MEM_SLICES(4),.MEM_DEPTH_ROWS(PHYSICAL_ROWS),.SUPERLANES(ROWS)) dut(
    .clk_i(clk),.rst_ni(rst_n),.bank_issue_valid_i(native_valid),.bank_issue_i(native_issue),
    .boundary_valid_i({2*ROWS*STREAMS{1'b0}}),.boundary_data_i({2*ROWS*STREAMS*64{1'b0}}),
    .state_valid_o(state_valid),.state_data_o(state_data),
    .mem_producer_valid_o(response_valid),.mem_producer_data_o(response_data),
    .mem_producer_direction_o(response_direction),.mem_producer_stream_o(response_stream),
    .srf_collision_o(collision),.srf_invalid_consume_o(invalid_consume),
    .mem_internal_collision_o(internal_collision),.mem_fault_valid_o(fault));

  task automatic step(input bit valid, input bit delay3);
    logic [STATES-1:0] want_state;
    logic [ENTRIES-1:0] want_response;
    integer slot;
    issue_valid=valid?8'b1:8'b0;
    issue=0;issue[31:0]=(delay3?32'h40000000:32'b0)|(7<<3);
    if(RAW_INGRESS)issue[14:9]=6'd37;
    if(!rst_n)count=0;
    else if(valid)begin
      issued_at[count]=cycles;issued_hop[count]=delay3?3:1;count=count+1;
    end
    want_state=0;want_response=0;
    for(integer i=0;i<count;i=i+1)for(integer r=0;r<ROWS;r=r+1)begin
      if(issued_at[i]+r*issued_hop[i]==cycles)want_response[r]=1;
      for(integer c=1;c<COLUMNS;c=c+1)
        if(issued_at[i]+r*issued_hop[i]+c==cycles)want_state[(c*ROWS+r)*STREAMS+7]=1;
    end
    #2;clk=1;#1;
    if(response_valid!==want_response)$fatal(1,"MEM/SRF response phase E%0d actual=%h expected=%h",cycles,response_valid,want_response);
    if(state_valid!==want_state)$fatal(1,"MEM/SRF data edge E%0d rows=%0d",cycles,ROWS);
    for(integer e=0;e<ENTRIES;e=e+1)if(want_response[e])
      if(response_data[e*64+:64]!==64'b0 || response_stream[e*5+:5]!==5'd7 || response_direction[e]!==1'b0)
        $fatal(1,"MEM/SRF response metadata");
    for(integer s=0;s<STATES;s=s+1)if(want_state[s])begin
      if(state_data[s*64+:64]!==64'b0)$fatal(1,"MEM/SRF state payload");
      checked_states=checked_states+1;
    end
    if(fault || |adapter_fault || |collision || |invalid_consume || |internal_collision)$fatal(1,"MEM/SRF unexpected fault");
    clk=0;#1;cycles=cycles+1;
  endtask

  initial begin
    rst_n=1;#1;rst_n=0;#1;step(0,0);rst_n=1;
    repeat(8)step(1,0);
    repeat(8)step(1,1);
    repeat(2*(ROWS-1))step(0,0);
    repeat(8)step(1,0);
    repeat(3*(ROWS-1)+COLUMNS+4)step(0,0);
    step(1,1);step(0,0);rst_n=0;step(0,0);rst_n=1;
    repeat(4)step(1,1);
    repeat(3*(ROWS-1)+COLUMNS+4)step(0,0);
    $display("MEM_SRF_TIMING TEST_PASS rows=%0d cycles=%0d checked_states=%0d raw_ingress=%0d physical_rows=%0d",ROWS,cycles,checked_states,RAW_INGRESS,PHYSICAL_ROWS);
    $finish;
  end
endmodule
