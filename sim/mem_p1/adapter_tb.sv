`timescale 1ns/1ps

module mem_p1_adapter_tb;
  logic clk=0,rst_n=0,valid=0;
  logic[31:0] word=0;
  wire[3:0] native_valid,fault;
  wire[31:0] native_word[0:3];
  wire legacy_valid,legacy_fault;
  wire[31:0] legacy_word;
  logic[46:0] legacy_instruction;
  integer fd,rc,p,e,expected_valid,selected=0,count=0;
  logic[31:0] expected_word;
  string path;
  for(genvar n=0;n<4;n=n+1)begin:gen_adapter
    localparam integer P=n==0?64:n==2?32768:8192;
    localparam integer E=n==3?64:P;
    // This fixture checks the frozen c7 codec, before the delay3 extension.
    mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(P),.P_MEM_ACTIVE_ROWS(E),.P_ALLOW_DELAY3(0)) dut(
      .issue_valid_i(valid),.issue_instruction_i(word),.native_valid_o(native_valid[n]),
      .native_command_o(native_word[n]),.command_fault_o(fault[n]));
  end
  mem_p1_command_checker u_input_checker(.clk_i(clk),.rst_ni(rst_n),.valid_i(valid),.command_i(word));
  lpu_mem_command_adapter legacy(.issue_valid_i(valid),.issue_instruction_i(legacy_instruction),
    .native_valid_o(legacy_valid),.native_command_o(legacy_word),.command_fault_o(legacy_fault));
  initial begin
    #1;clk=1;#1;clk=0;rst_n=1;
    if(!$value$plusargs("SELECT=%d",selected))selected=0;
    if(!$value$plusargs("VECTORS=%s",path))$fatal(1,"VECTORS missing");
    fd=$fopen(path,"r");if(!fd)$fatal(1,"cannot open codec vectors");
    rc=$fscanf(fd,"%d %d",p,e);
    if(rc!=2 || p!=(selected==0?64:selected==2?32768:8192) || e!=(selected==3?64:p))
      $fatal(1,"codec config identity mismatch");
    valid=1;legacy_instruction=0;
    while(!$feof(fd))begin
      rc=$fscanf(fd,"%h %d %h",word,expected_valid,expected_word);
      if(rc==-1)break;
      if(rc!=3)$fatal(1,"truncated codec vector");
      #1;clk=1;#1;
      if(native_valid[selected]!==1'(expected_valid) || fault[selected]!==1'(!expected_valid) ||
         native_word[selected]!==expected_word)
        $fatal(1,"c7 adapter word=%h P=%0d E=%0d expected_valid=%0d actual_valid=%b expected=%h actual=%h",word,p,e,expected_valid,native_valid[selected],expected_word,native_word[selected]);
      clk=0;count=count+1;
    end
    $fclose(fd);
    // Independent legacy-format checks; never decode this packet as c7 raw.
    for(integer op=0;op<8;op=op+1)for(integer s=0;s<64;s=s+1)begin
      legacy_instruction=47'(op)|(47'(s)<<3)|(47'(15)<<15)|(47'(63)<<9);
      #1;
      if(legacy_valid!==(op<2) || legacy_fault!==(op>=2))$fatal(1,"legacy opcode behavior changed");
      if(op<2 && legacy_word!==(32'(op)|(32'(s)<<3)|(32'(15)<<15)))$fatal(1,"legacy normalization changed");
    end
    legacy_instruction=47'h1<<31;#1;
    if(legacy_valid || !legacy_fault)$fatal(1,"legacy write-address rejected incorrectly");
    legacy_instruction=47'h1<<30;#1;
    if(legacy_valid || !legacy_fault)$fatal(1,"legacy high address not rejected");
    valid=0;word='x;legacy_instruction='x;#1;clk=1;#1;
    if(native_valid!==0 || fault!==0 || legacy_valid || legacy_fault)$fatal(1,"inactive adapter output");
    $display("MEM_ADAPTER TEST_PASS P=%0d E=%0d cases=%0d legacy_cases=514",p,e,count);
    $finish;
  end
endmodule
