`timescale 1ns/1ps

module mem_p1_entry_tb;
  logic clk=0,rst_n=0,use_adapter=0;
  logic raw_valid=0;
  logic[31:0] raw_word=0;
  wire native_valid,command_fault;
  wire[31:0] native_word;
  logic[1:0] direct_valid=0;
  logic[63:0] direct_command=0;
  logic[255:0] sv=0;
  logic[16383:0] sd='x;
  wire[1:0] slice_valid=use_adapter?{1'b0,native_valid}:direct_valid;
  wire[63:0] slice_command=use_adapter?{32'b0,native_word}:direct_command;
  wire[511:0] consume;
  wire[7:0] rv;
  wire[511:0] data;
  wire[39:0] stream;
  logic[7:0] gv=0;
  logic[255:0] gc=0;
  logic[31:0] feedback=0;
  wire[31:0] group_response;
  integer which=0;
  mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_ACTIVE_ROWS(32)) adapter(
    .issue_valid_i(raw_valid),.issue_instruction_i(raw_word),.native_valid_o(native_valid),
    .native_command_o(native_word),.command_fault_o(command_fault));
  mem_p1_command_checker u_raw_checker(.clk_i(clk),.rst_ni(rst_n),.valid_i(raw_valid),.command_i(raw_word));
  mem_slice #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_ACTIVE_ROWS(32)) dut(
    .clk_i(clk),.rst_ni(rst_n),.bank_issue_valid_i(slice_valid),.bank_issue_i(slice_command),
    .sr_state_valid_i(sv),.sr_state_data_i(sd),.producer_collision_i(8'b0),
    .sr_consume_o(consume),.sr_inject_valid_o(rv),.sr_inject_data_o(data),.sr_inject_stream_idx_o(stream));
  mem_group #(.P_MEM_BANK_DEPTH_ROWS(64)) group_dut(.clk_i(clk),.rst_ni(rst_n),
    .group_issue_valid_i(gv),.group_issue_i(gc),.left_boundary_state_valid_i(256'b0),
    .left_boundary_state_data_i(16384'bx),.right_boundary_state_valid_i(256'b0),
    .right_boundary_state_data_i(16384'bx),.external_producer_collision_i(feedback),
    .right_boundary_inject_valid_o(group_response));
  task automatic tick;
    #3;clk=1;#1;clk=0;#1;
  endtask
  initial begin
    if(!$value$plusargs("CASE=%d",which))which=0;
    tick();rst_n=1;
    if(which!=0)begin
      case(which)
        1:direct_valid[0]=1'bx;
        2:begin direct_valid=1;direct_command[31:0]='x;direct_command[30]=1;end
        3:begin gv=1;tick();gv=0;feedback[0]=1'bx;end
        4:begin raw_valid=1;raw_word='x;end
        5:raw_valid=1'bx;
        6:direct_valid[0]=1'bz;
        7:begin direct_valid=1;direct_command[31:0]='z;direct_command[30]=1;end
        8:begin gv=1;tick();gv=0;feedback[0]=1'bz;end
      endcase
      tick();$fatal(1,"UNEXPECTED_ENTRY_SUCCESS case=%0d",which);
    end
    direct_command='x;feedback='x;tick();feedback=0;
    use_adapter=1;raw_valid=1;sv='1;
    for(integer c=0;c<256;c=c+1)sd[c*64+:64]=64'h0123456789abcdef^(64'h102030405060708*c);
    raw_word=32'h80000001|(1<<15)|(5<<3)|(63<<9);
    #1;
    if(!native_valid || command_fault || native_word[14:9]!=0 || consume!=0)$fatal(1,"c7 Tap path/normalization");
    tick();raw_valid=0;repeat(4)tick();
    raw_valid=1;raw_word=(1<<15)|(7<<3)|(42<<9);tick();
    for(integer t=0;t<4;t=t+1)begin
      if(t!=0)tick();
      if(rv!==8'(1<<t) || data[t*64+:64]!==(64'h0123456789abcdef^(64'h102030405060708*(5*4+t))) || stream[t*5+:5]!==5'd7)
        $fatal(1,"c7-to-native extra latency/metadata tile=%0d",t);
      // A new adapter-rejected request must not cancel the older Read wave.
      raw_word=32'h80000001|(32<<15);sv=0;sd='x;
      #1;if(!command_fault || native_valid)$fatal(1,"c7 active depth rejection");
    end
    raw_valid=0;tick();
    if(rv || consume)$fatal(1,"c7 tail response/consume");
    $display("MEM_ENTRY TEST_PASS c7_tap_read=1 zero_added_stages=1 rejected_issue_preserves_old_wave=1");
    $finish;
  end
endmodule
