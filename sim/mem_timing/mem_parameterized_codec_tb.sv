`timescale 1ns/1ps

// Extended raw ABI properties plus byte-for-byte frozen-c7 compatibility.
module mem_parameterized_codec_tb #(
  parameter integer DEPTH=2048,
  parameter integer ACTIVE=DEPTH
);
  logic valid=0;
  logic [31:0] word=0;
  wire nv,nf,sv,sf,ov,ofault;
  wire [31:0] normalized,strict_word,old_word;
  integer checked=0;
  logic [31:0] random_state=32'h72617731;
  mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(DEPTH),.P_MEM_ACTIVE_ROWS(ACTIVE)) current_abi(
    .issue_valid_i(valid),.issue_instruction_i(word),.native_valid_o(nv),.native_command_o(normalized),.command_fault_o(nf));
  mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(DEPTH),.P_MEM_ACTIVE_ROWS(ACTIVE),.P_ALLOW_DELAY3(0)) strict_c7(
    .issue_valid_i(valid),.issue_instruction_i(word),.native_valid_o(sv),.native_command_o(strict_word),.command_fault_o(sf));
  mem_c7_primitive_adapter_before #(.P_MEM_BANK_DEPTH_ROWS(DEPTH),.P_MEM_ACTIVE_ROWS(ACTIVE)) old_c7(
    .issue_valid_i(valid),.issue_instruction_i(word),.native_valid_o(ov),.native_command_o(old_word),.command_fault_o(ofault));

  task automatic check(input logic [31:0] raw,input bit accept,input logic [31:0] canonical);
    valid=1;word=raw;#1;
    if(nv!==accept || nf!==!accept || normalized!==(accept?canonical:32'b0))
      $fatal(1,"parameterized codec DEPTH=%0d ACTIVE=%0d raw=%h expected_valid=%b actual_valid=%b expected=%h actual=%h",DEPTH,ACTIVE,raw,accept,nv,canonical,normalized);
    if(sv!==ov || sf!==ofault || strict_word!==old_word)$fatal(1,"frozen c7 compatibility raw=%h",raw);
    checked=checked+1;
  endtask

  initial begin : exercise
    logic [31:0] raw,canonical;
    integer address;
    // All stream IDs, both modes, all input map values, Read/Write/WriteTap.
    for(integer mode=0;mode<2;mode=mode+1)
      for(integer stream=0;stream<64;stream=stream+1)
        for(integer map=0;map<64;map=map+1)
          for(integer op=0;op<2;op=op+1)
            for(integer tap=0;tap<2;tap=tap+1)begin
              address=(map%2)?ACTIVE-1:0;
              canonical=(tap<<31)|(mode<<30)|(address<<15)|(stream<<3)|op;
              raw=canonical|(map<<9);
              check(raw,!(op==0 && tap),canonical);
            end
    // Legal highest row and out-of-range rows in both propagation modes.
    for(integer mode=0;mode<2;mode=mode+1)begin
      check((mode<<30)|((ACTIVE-1)<<15),1,(mode<<30)|((ACTIVE-1)<<15));
      if(ACTIVE<32768)check((mode<<30)|(ACTIVE<<15),0,0);
      if(DEPTH<32768)check((mode<<30)|(DEPTH<<15),0,0);
      for(integer op=2;op<8;op=op+1)check((mode<<30)|op,0,0);
    end
    // Random legal/illegal words: semantic fields define the expected result.
    repeat(10000)begin
      random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
      raw=random_state;
      canonical=(32'(raw[31])<<31)|(32'(raw[30])<<30)|(32'(raw[29:15])<<15)|(32'(raw[8:3])<<3)|32'(raw[2:0]);
      check(raw,raw[2:0]<2 && !(raw[2:0]==0 && raw[31]) && raw[29:15]<ACTIVE,canonical);
    end
    valid=0;word='x;#1;
    if(nv || nf || normalized!==0 || sv || sf || strict_word!==0)$fatal(1,"inactive raw input");
    $display("MEM_PARAMETERIZED_CODEC TEST_PASS depth=%0d active=%0d cases=%0d frozen_c7_equal=1",DEPTH,ACTIVE,checked);
    $finish;
  end
endmodule
