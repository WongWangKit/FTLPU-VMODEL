`timescale 1ns/1ps
// Exhaustive raw frontend encodings and full-rate compute relay/tag wrap.
// Compiler scheduling granularity is a contract, not an ISA legality check.
module lpu_mxm_compact_isa_tb;
  import lpu_mxm_isa_pkg::*;
  localparam integer R=4,CB=COMPUTE_INSTRUCTION_BITS,BEATS=66048,LIMIT=70000;
  logic clk=0,rst_n=0,run=0,enq=0,launch=0;
  logic [CB-1:0] word=0;
  wire ready,launch_ready,fault;
  wire [R-1:0] valid,update;
  wire [R*CB-1:0] commands;
  wire [R*16-1:0] tags;
  integer cycle=0,issued=0,checked=0;
  bit scoring=1;
  bit expected[0:R-1][0:LIMIT];
  integer expected_tag[0:R-1][0:LIMIT];
  always #5 clk=~clk;
  function automatic logic [CB-1:0] raw_word(input integer beat);
    raw_word=CB'(((beat/32)%64)*2+(beat/32)%2);
  endfunction
  lpu_mxm_control dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.compute_enqueue_valid_i(enq),.compute_enqueue_ready_o(ready),
    .compute_instruction_i(word),.compute_launch_i(launch),.compute_launch_ready_o(launch_ready),
    .load_enqueue_valid_i(1'b0),.load_enqueue_ready_o(),.load_instruction_i(8'b0),.load_launch_i(1'b0),.load_launch_ready_o(),
    .compute_row_valid_o(valid),.compute_row_update_o(update),.compute_row_instruction_o(commands),.compute_row_tag_o(tags),
    .load_row_valid_o(),.load_row_update_o(),.load_row_instruction_o(),.load_row_index_o(),.fault_o(fault));
  always @(posedge clk) if(run && scoring) begin
    cycle++;
    if(launch) begin
      if(!launch_ready || (enq && !ready)) $fatal(1,"count-free full-rate launch blocked");
      for(integer r=0;r<R;r++) begin expected[r][cycle+3*r]=1;expected_tag[r][cycle+3*r]=issued;end
      issued++;
    end
    #1;
    if(fault) $fatal(1,"count-free stream fault");
    for(integer r=0;r<R;r++) begin
      if(valid[r]!==expected[r][cycle] || update[r]!==expected[r][cycle]) $fatal(1,"relay bubble/valid mismatch");
      if(valid[r]) begin
        if(commands[r*CB+:CB]!==raw_word(expected_tag[r][cycle]) || tags[r*16+:16]!==16'(expected_tag[r][cycle]))
          $fatal(1,"same-word relay or tag wrap corrupted");
        checked++;
      end
    end
  end
  compute_instruction_t probe;
  load_instruction_t load_probe;
  initial begin
    if(CB!=7 || LOAD_INSTRUCTION_BITS!=8 || $bits(probe)!=7 || $bits(load_probe)!=8) $fatal(1,"count field still present");
    for(integer n=0;n<128;n++) begin
      probe=7'(n);
      if(probe.activation_stream!==6'(n>>1) || probe.weight_buffer!==1'(n)) $fatal(1,"compute fields misplaced");
    end
    for(integer n=0;n<256;n++) begin
      load_probe=8'(n);
      if(load_probe.weight_stream!==6'(n>>2) || load_probe.weight_buffer!==1'(n>>1) || load_probe.column_mode!==1'(n))
        $fatal(1,"load fields misplaced");
    end
    for(integer r=0;r<R;r++) for(integer t=0;t<=LIMIT;t++) expected[r][t]=0;
    repeat(3) @(negedge clk);rst_n=1;
    @(negedge clk);enq=1;word=raw_word(0);
    @(negedge clk);enq=0;run=1;
    // 32-beat compiler groups, one deliberately empty cycle between groups.
    for(integer t=0;t<BEATS+BEATS/32+30;t++) begin
      @(negedge clk);launch=issued<BEATS && t%33!=32;
      enq=launch && issued+1<BEATS;if(enq) word=raw_word(issued+1);
    end
    @(negedge clk);launch=0;enq=0;
    if(checked!=BEATS*R || issued!=BEATS) $fatal(1,"missing count-free relay checks");
    $display("MXM_COMPACT_ISA_PASS compute_bits=7 load_bits=8 encodings=384 compute_beats=%0d row_checks=%0d tag_wrap=1 compiler_group=32",issued,checked);
    // Cancel a command in flight; no residual valid may appear on restart.
    scoring=0;enq=1;word=raw_word(0);
    @(negedge clk);enq=0;launch=1;
    @(negedge clk);launch=0;
    run=0;repeat(2) @(negedge clk);run=1;
    repeat(15) begin @(negedge clk);if(valid || fault) $fatal(1,"count-free run flush failed");end
    $finish;
  end
  initial begin #1000000;$fatal(1,"count-free compact test timeout");end
endmodule
