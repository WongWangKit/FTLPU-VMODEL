`timescale 1ns/1ps
// Independent rational vectors; public ports and an actual D3 sink register.
// Each accepted weight overwrites the PREVIOUS weight's parameter buffer:
// D2 must use D1's captured scale, never reread the changed parameter store.
module lpu_mxm_weight_dequant_tb #(parameter integer LANES=8,parameter bit ZERO_ENABLE=1);
  localparam integer STREAMS=32,COUNT=524288,PACKETS=(COUNT+LANES-1)/LANES,LIMIT=PACKETS+(PACKETS+35)/36+100;
  localparam integer Q=5,SL=9,SH=12,Z=17;
  logic clk=0,rst_n=0,run=1,request=0,buffer=0,param_write=0,param_write_buffer=0,param_buffer=0;
  logic [STREAMS*LANES-1:0] stream_valid='0;
  logic [STREAMS*LANES*8-1:0] streams='0;
  wire [STREAMS*LANES-1:0] consume;
  wire accepted,valid,out_buffer,fault,param_accepted;
  wire [1:0] param_ready;
  wire [LANES*16-1:0] weight;
  logic sink_valid,sink_buffer;
  logic [LANES*16-1:0] sink_weight;
  logic [63:0] vectors[0:COUNT-1];
  bit due[0:LIMIT];
  integer due_index[0:LIMIT];
  bit due_buffer[0:LIMIT];
  integer cursor=0,cycle=0,checked=0,packets=0,active_count=COUNT;
  integer trace_fd=0,trace_cycles=0;
  string trace_path,vcd_path,path;
  bit scoring=1;
  always #5 clk=~clk;
  lpu_mxm_weight_dequant_pipe #(.LANES(LANES),.STREAMS(STREAMS),.Q_STREAM(Q),
    .SCALE_LO_STREAM(SL),.SCALE_HI_STREAM(SH),.ZERO_STREAM(Z),.ZERO_ENABLE(ZERO_ENABLE)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.request_i(request),.buffer_i(buffer),
    .param_write_i(param_write),.param_write_buffer_i(param_write_buffer),.param_buffer_i(param_buffer),
    .param_accepted_o(param_accepted),.param_ready_o(param_ready),
    .stream_valid_i(stream_valid),.stream_i(streams),.consume_o(consume),
    .accepted_o(accepted),.valid_o(valid),.buffer_o(out_buffer),.weight_bf16_o(weight),.fault_o(fault));
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin sink_valid<=0;sink_buffer<=0;sink_weight<=0;end
    else if(!run) sink_valid<=0;
    else begin sink_valid<=valid;if(valid) begin sink_weight<=weight;sink_buffer<=out_buffer;end end
  end
  initial begin
    if($value$plusargs("trace_path=%s",trace_path)) begin
      trace_fd=$fopen(trace_path,"w");
      $fdisplay(trace_fd,"sample_ns,lane,request,accepted,weight_buffer,param_read_buffer,param_write,param_write_buffer,param_accepted,param_ready,q,loaded_zero,loaded_scale,d2_valid,d2_bf16,d3_valid,d3_bf16,fault,d2_buffer,d3_buffer");
    end
    if($value$plusargs("vcd_path=%s",vcd_path)) begin
      $dumpfile(vcd_path);$dumpvars(0,clk,rst_n,run,request,buffer,param_write,param_write_buffer,param_buffer,param_accepted,param_ready,streams,consume,accepted,valid,out_buffer,weight,sink_valid,sink_buffer,sink_weight,fault);
    end
  end
  always @(posedge clk) begin : public_trace
    logic sampled_request,sampled_accepted,sampled_buffer,sampled_pw,sampled_pwb,sampled_pb,sampled_pa;
    logic [STREAMS*LANES*8-1:0] sampled_streams;
    sampled_request=request;sampled_accepted=accepted;sampled_buffer=buffer;sampled_streams=streams;
    sampled_pw=param_write;sampled_pwb=param_write_buffer;sampled_pb=param_buffer;sampled_pa=param_accepted;
    #2;
    if(trace_fd && rst_n && trace_cycles<64) begin
      trace_cycles++;
      for(integer lane=0;lane<LANES;lane++)
        $fdisplay(trace_fd,"%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%02h,%02h,%04h,%0d,%04h,%0d,%04h,%0d,%0d,%0d",
          $realtime,lane,sampled_request,sampled_accepted,sampled_buffer,sampled_pb,sampled_pw,sampled_pwb,sampled_pa,param_ready,
          sampled_streams[(Q*LANES+lane)*8+:8],sampled_streams[(Z*LANES+lane)*8+:8],
          {sampled_streams[(SH*LANES+lane)*8+:8],sampled_streams[(SL*LANES+lane)*8+:8]},
          valid,weight[lane*16+:16],sink_valid,sink_weight[lane*16+:16],fault,out_buffer,sink_buffer);
    end
  end
  final if(trace_fd) $fclose(trace_fd);
  task automatic drive_packet(input integer weight_start,input integer parameter_start);
    streams='1;stream_valid='0;
    for(integer lane=0;lane<LANES;lane++) begin
      integer wi,pi;
      wi=(weight_start+lane)%active_count;pi=(parameter_start+lane)%active_count;
      streams[(Q*LANES+lane)*8+:8]=vectors[wi][63:56];
      streams[(Z*LANES+lane)*8+:8]=vectors[pi][55:48];
      streams[(SL*LANES+lane)*8+:8]=vectors[pi][39:32];
      streams[(SH*LANES+lane)*8+:8]=vectors[pi][47:40];
      stream_valid[Q*LANES+lane]=request;
      stream_valid[SL*LANES+lane]=param_write;stream_valid[SH*LANES+lane]=param_write;
      stream_valid[Z*LANES+lane]=param_write && ZERO_ENABLE;
    end
  endtask
  always @(posedge clk) if(rst_n && scoring) begin
    logic [STREAMS*LANES-1:0] expected_consume;
    cycle++;
    if(request) begin due[cycle+2]=1;due_index[cycle+2]=cursor;due_buffer[cycle+2]=buffer;packets++;end
    if(accepted!==request || param_accepted!==param_write) $fatal(1,"legal dequant or parameter load blocked");
    expected_consume=0;
    for(integer lane=0;lane<LANES;lane++) begin
      expected_consume[Q*LANES+lane]=request;
      expected_consume[SL*LANES+lane]=param_write;expected_consume[SH*LANES+lane]=param_write;
      expected_consume[Z*LANES+lane]=param_write && ZERO_ENABLE;
    end
    if(consume!==expected_consume) $fatal(1,"dequant consumed wrong stream bytes");
    if(valid!==due[cycle]) $fatal(1,"dequant D3 write phase mismatch cycle=%0d",cycle);
    if(valid && out_buffer!==due_buffer[cycle]) $fatal(1,"weight Buffer ID changed in flight");
    #1;
    if(fault || sink_valid!==due[cycle]) $fatal(1,"dequant fault or hidden D4 register");
    if(sink_valid) begin
      if(sink_buffer!==due_buffer[cycle]) $fatal(1,"D3 destination metadata mismatch");
      for(integer lane=0;lane<LANES;lane++) if(due_index[cycle]+lane<active_count) begin
        logic [15:0] expected;
        expected=ZERO_ENABLE?vectors[due_index[cycle]+lane][31:16]:vectors[due_index[cycle]+lane][15:0];
        if(sink_weight[lane*16+:16]!==expected)
          $fatal(1,"D1 parameter snapshot/RNE mismatch item=%0d got=%h expected=%h",due_index[cycle]+lane,sink_weight[lane*16+:16],expected);
        checked++;
      end
    end
  end
  task automatic reset_unit;
    @(negedge clk);rst_n=0;run=1;request=0;param_write=0;stream_valid=0;
    @(negedge clk);rst_n=1;
  endtask
  task automatic load_fixed(input bit bank,input logic [15:0] scale,input logic [7:0] zero);
    param_write=1;param_write_buffer=bank;request=0;stream_valid=0;
    for(integer lane=0;lane<LANES;lane++) begin
      streams[(SL*LANES+lane)*8+:8]=scale[7:0];streams[(SH*LANES+lane)*8+:8]=scale[15:8];
      streams[(Z*LANES+lane)*8+:8]=zero;
      stream_valid[SL*LANES+lane]=1;stream_valid[SH*LANES+lane]=1;stream_valid[Z*LANES+lane]=ZERO_ENABLE;
    end
    #1;if(!param_accepted) $fatal(1,"parameter preload rejected");
    @(negedge clk);param_write=0;stream_valid=0;
  endtask
  task automatic fixed_weight(input bit bank);
    request=1;param_buffer=bank;stream_valid=0;
    for(integer lane=0;lane<LANES;lane++) begin
      streams[(Q*LANES+lane)*8+:8]=5;stream_valid[Q*LANES+lane]=1;
    end
  endtask
  initial begin
    if(!$value$plusargs("vectors=%s",path)) $fatal(1,"missing dequant vectors");
    if($value$plusargs("count=%d",active_count)) begin
      if(active_count<1 || active_count>COUNT) $fatal(1,"invalid dequant vector count");
    end
    $readmemh(path,vectors);
    for(integer t=0;t<=LIMIT;t++) due[t]=0;
    repeat(3) @(negedge clk);rst_n=1;
    @(negedge clk);param_write=1;param_write_buffer=0;drive_packet(0,0);
    for(integer tick=0;tick<(active_count+LANES-1)/LANES+((active_count+LANES-1)/LANES+35)/36+90;tick++) begin
      @(negedge clk);
      if(request) cursor=cursor+LANES;
      request=cursor<active_count && tick%37!=36;
      buffer=1'((cursor/LANES)/3);param_buffer=1'(cursor/LANES);
      param_write=request && cursor+LANES<active_count;param_write_buffer=~param_buffer;
      drive_packet(cursor,cursor+LANES);
    end
    @(negedge clk);request=0;param_write=0;stream_valid=0;
    repeat(4) @(negedge clk);
    if(checked!=active_count) $fatal(1,"dequant missing results %0d",checked);
    $display("MXM_WEIGHT_DEQUANT_PASS lanes=%0d zero_enable=%0d checked=%0d packets=%0d write_stages=3 II=1 D1_snapshot=1",LANES,ZERO_ENABLE,checked,packets);
    scoring=0;
    // Uninitialized parameter read.
    reset_unit();fixed_weight(0);
    #1;if(accepted || consume) $fatal(1,"uninitialized parameters accepted");
    @(negedge clk);request=0;if(!fault) $fatal(1,"uninitialized parameters not detected");
    // Parameter loading has no dependency on weight valid; missing one byte
    // rejects the whole parameter group, leaving its ready bit clear.
    for(integer source=0;source<(ZERO_ENABLE?3:2);source++) begin
      integer stream_number;
      reset_unit();param_write=1;param_write_buffer=1;drive_packet(0,17);
      case(source) 0:stream_number=SL;1:stream_number=SH;default:stream_number=Z;endcase
      stream_valid[stream_number*LANES+LANES-1]=0;
      #1;if(param_accepted || consume) $fatal(1,"partial parameter group consumed");
      @(negedge clk);param_write=0;
      if(!fault || param_ready!=0) $fatal(1,"invalid parameters committed");
    end
    reset_unit();load_fixed(0,16'h3f80,8'd1);fixed_weight(0);
    stream_valid[Q*LANES+LANES-1]=0;
    #1;if(accepted || consume) $fatal(1,"partial weight group consumed");
    @(negedge clk);request=0;if(!fault) $fatal(1,"missing weight byte not detected");
    // Illegal same-buffer update/read cannot replace either member of a pair.
    reset_unit();load_fixed(0,16'h3f80,8'd1);fixed_weight(0);param_write=1;param_write_buffer=0;
    for(integer lane=0;lane<LANES;lane++) begin
      stream_valid[SL*LANES+lane]=1;stream_valid[SH*LANES+lane]=1;stream_valid[Z*LANES+lane]=ZERO_ENABLE;
      streams[(SH*LANES+lane)*8+:8]=8'h40;streams[(Z*LANES+lane)*8+:8]=2;
    end
    #1;if(accepted || param_accepted || consume) $fatal(1,"same-buffer collision accepted");
    @(negedge clk);request=0;param_write=0;if(!fault) $fatal(1,"parameter collision not detected");
    // run=0 clears in-flight/fault while retaining initialized parameter pairs.
    run=0;@(negedge clk);if(fault || valid || sink_valid || param_ready!=1) $fatal(1,"run flush lost parameter state");
    run=1;fixed_weight(0);
    @(negedge clk);request=0;stream_valid=0;
    repeat(2) @(negedge clk);
    if(!sink_valid || fault) $fatal(1,"parameter reuse failed");
    for(integer lane=0;lane<LANES;lane++)
      if(sink_weight[lane*16+:16] !== (ZERO_ENABLE?16'h4080:16'h40a0)) $fatal(1,"parameter collision changed old scale/zero");
    // Reset cancels the pipeline and invalidates both parameter buffers.
    @(negedge clk);fixed_weight(0);
    @(negedge clk);request=0;rst_n=0;
    #1;if(valid || sink_valid || fault || param_ready) $fatal(1,"reset failed");
    @(negedge clk);rst_n=1;
    repeat(5) begin @(negedge clk);if(valid || sink_valid || fault || param_ready) $fatal(1,"stale transaction after reset");end
    $display("MXM_WEIGHT_DEQUANT_PARAM_FAULT_REUSE_RESET_PASS");$finish;
  end
  initial begin #8000000;$fatal(1,"dequant timeout");end
endmodule
