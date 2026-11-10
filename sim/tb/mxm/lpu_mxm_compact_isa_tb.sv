`timescale 1ns/1ps
// An independent integer schedule drives compact raw bit patterns through the
// public controller. Maximum length, boundaries, adjacent commands, all stream
// IDs, buffer toggles and 16-bit transaction-tag wrap are checked end to end.
module lpu_mxm_compact_isa_tb;
  import lpu_mxm_isa_pkg::*;
  localparam integer R=4,CB=COMPUTE_INSTRUCTION_BITS,LB=LOAD_INSTRUCTION_BITS,COMMANDS=68;
  logic clk=0,rst_n=0,run=0,enqueue=0,launch=0;
  logic [CB-1:0] cmd='0;
  wire ready,launch_ready,fault;
  wire [R-1:0] valid,update;
  wire [R*CB-1:0] commands;
  wire [R*16-1:0] indexes,tags;
  integer tick=-1,seq=0,checks=0,base=0,next_launch=0;
  integer due[0:R-1],length[0:R-1],sequence_id[0:R-1],tag_base[0:R-1];
  always #5 clk=~clk;
  function automatic integer count_for(input integer s);
    case(s)
      0:count_for=32;
      1:count_for=33;
      2:count_for=1023;
      default:count_for=1024;
    endcase
  endfunction
  function automatic logic [CB-1:0] word_for(input integer s);
    word_for=(CB'(s%64)<<11) | (CB'(count_for(s)-1)<<1) | CB'(s%2);
  endfunction
  lpu_mxm_control #(.ROWS(R),.QUEUE_DEPTH(1)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.compute_enqueue_valid_i(enqueue),
    .compute_enqueue_ready_o(ready),.compute_instruction_i(cmd),.compute_launch_i(launch),
    .compute_launch_ready_o(launch_ready),.compute_row_valid_o(valid),.compute_row_update_o(update),
    .compute_row_instruction_o(commands),.compute_row_index_o(indexes),.compute_row_tag_o(tags),
    .load_enqueue_valid_i(1'b0),.load_enqueue_ready_o(),.load_instruction_i({LB{1'b0}}),
    .load_launch_i(1'b0),.load_launch_ready_o(),.load_row_valid_o(),.load_row_update_o(),
    .load_row_instruction_o(),.load_row_index_o(),.fault_o(fault));
  always @(posedge clk) begin
    if(!rst_n) begin
      tick=-1;seq=0;base=0;
      for(integer r=0;r<R;r++) begin due[r]=-10000;length[r]=0;sequence_id[r]=0;tag_base[r]=0;end
    end else if(run) begin
      tick=tick+1;
      if(launch) begin
        if(!launch_ready || (enqueue && !ready)) $fatal(1,"compact max command not launchable");
        for(integer r=0;r<R;r++) begin
          // Keep the old upper-row instruction until its own replacement.
          // Calendar for the arriving command is reconstructed below.
          if(r==0) begin due[r]=tick;length[r]=count_for(seq);sequence_id[r]=seq;tag_base[r]=base;end
        end
        seq=seq+1;base=base+count_for(seq-1);
      end
      #1;
      if(fault) $fatal(1,"compact legal sequence fault");
      for(integer r=0;r<R;r++) begin
        integer elapsed,expected_seq,expected_base,start;
        // Derive each row's position solely from the launch-independent
        // sequence lengths and its fixed three-cycle phase.
        elapsed=tick-3*r;expected_seq=0;expected_base=0;start=0;
        while(expected_seq<COMMANDS && elapsed>=start+count_for(expected_seq)) begin
          start=start+count_for(expected_seq);expected_base=expected_base+count_for(expected_seq);expected_seq=expected_seq+1;
        end
        if(valid[r] !== (elapsed>=0 && expected_seq<COMMANDS)) $fatal(1,"compact duration/off-by-one r=%0d tick=%0d",r,tick);
        if(update[r] !== (elapsed>=0 && expected_seq<COMMANDS && elapsed==start)) $fatal(1,"compact update phase");
        if(valid[r]) begin
          if(commands[r*CB+:CB]!==word_for(expected_seq) || indexes[r*16+:16]!==16'(elapsed-start) ||
             tags[r*16+:16]!==16'(expected_base+elapsed-start)) $fatal(1,"compact data/index/tag wrap mismatch");
          checks=checks+1;
        end
      end
    end
  end
  initial begin
    logic [CB-1:0] probe;
    logic [LB-1:0] load_probe;
    if(CB!=17 || LB!=8) $fatal(1,"unexpected default compact widths");
    // All encoded lengths and all source IDs, at both buffer selections.
    for(integer n=1;n<=1024;n++) for(integer source=0;source<64;source++) for(integer b=0;b<2;b++) begin
      probe=(CB'(source)<<11) | (CB'(n-1)<<1) | CB'(b);
      if(compute_legal(probe)!==(n>=32) || int'(compute_duration(probe))!=n) $fatal(1,"compact decoder boundary mismatch");
    end
    // There are no reserved or address encodings left in the load word.
    for(integer source=0;source<64;source++) for(integer b=0;b<2;b++) for(integer mode=0;mode<2;mode++) begin
      load_instruction_t decoded;
      load_probe=(LB'(source)<<2) | (LB'(b)<<1) | LB'(mode);
      decoded=load_probe;
      if(decoded.weight_stream!==6'(source) || decoded.weight_buffer!==1'(b) || decoded.column_mode!==1'(mode))
        $fatal(1,"8-bit load layout mismatch");
    end
    repeat(3) @(negedge clk);rst_n=1;
    @(negedge clk);enqueue=1;cmd=word_for(0);
    @(negedge clk);enqueue=0;run=1;
    // Bottom starts at tick zero, replacing instructions with no idle slot.
    launch=1;enqueue=1;cmd=word_for(1);next_launch=count_for(0);
    for(integer t=1;t<32+33+1023+65*1024+3*(R-1)+2;t++) begin
      @(negedge clk);launch=0;enqueue=0;
      if(t==next_launch && seq<COMMANDS) begin
        launch=1;enqueue=seq+1<COMMANDS;cmd=word_for(seq+1);next_launch=next_launch+count_for(seq);
      end
    end
    @(negedge clk);launch=0;enqueue=0;
    if(seq!=COMMANDS || checks!=R*(32+33+1023+65*1024)) $fatal(1,"compact missing beats checks=%0d",checks);
    run=0;#1;
    if(valid!=='0 || update!=='0) $fatal(1,"compact run flush failed");
    $display("MXM_COMPACT_ISA_PASS compute_bits=%0d load_bits=%0d commands=%0d beats=%0d decoder_patterns=131072 count_range=32..1024 tag_wrap=1",CB,LB,COMMANDS,checks);
    $finish;
  end
  initial begin #1000000;$fatal(1,"compact ISA timeout");end
endmodule
