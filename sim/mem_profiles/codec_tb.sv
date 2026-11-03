`timescale 1ns/1ps
module mem_profiles_codec_tb #(parameter integer DEPTH=1024,ACTIVE=DEPTH);
  logic valid=0;
  logic [31:0] word=0;
  wire native_valid,fault;
  wire [31:0] native_word;
  mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(DEPTH),.P_MEM_ACTIVE_ROWS(ACTIVE)) dut(
    .issue_valid_i(valid),.issue_instruction_i(word),.native_valid_o(native_valid),
    .native_command_o(native_word),.command_fault_o(fault));
  integer fd,rc,version,p,e,expected,count=0;
  logic [31:0] expected_word;
  string path,magic;
  initial begin
    if(!$value$plusargs("VECTORS=%s",path))$fatal(1,"missing codec vectors");
    fd=$fopen(path,"r");if(!fd)$fatal(1,"cannot open codec vectors");
    rc=$fscanf(fd,"%s %d %d %d",magic,version,p,e);
    if(rc!=4 || magic!="MEM_PROFILE_CODEC" || version!=1 || p!=DEPTH || e!=ACTIVE)$fatal(1,"codec profile identity");
    valid=1;
    while(!$feof(fd))begin
      rc=$fscanf(fd,"%h %d %h",word,expected,expected_word);
      if(rc==-1)break;if(rc!=3)$fatal(1,"truncated codec vector");
      #1;
      if(native_valid !== 1'(expected) || fault !== 1'(!expected) || native_word !== expected_word)
        $fatal(1,"codec mismatch P=%0d E=%0d word=%h expected=%h actual=%h",DEPTH,ACTIVE,word,expected_word,native_word);
      count=count+1;
    end
    valid=0;word='x;#1;
    if(native_valid || fault || native_word !== 0)$fatal(1,"inactive codec output");
    $display("MEM_PROFILE_CODEC TEST_PASS P=%0d E=%0d cases=%0d",DEPTH,ACTIVE,count);$finish;
  end
endmodule
