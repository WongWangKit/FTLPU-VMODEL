`timescale 1ns/1ps
// Fill both buffers using COLUMN instructions ONLY, with alternating buffer
// IDs and all 32 positions supplied in reverse order. No MATRIX or addressed
// write is available to rescue an incomplete shift-chain implementation.
module lpu_mxm_weight_shift_tb #(parameter integer LOAD_INTERVAL=3);
  import lpu_mxm_isa_pkg::*;
  localparam integer R=4,C=4,K=8,N=8,CB=COMPUTE_INSTRUCTION_BITS,LB=LOAD_INSTRUCTION_BITS,LIMIT=350;
  logic clk=0,rst_n=0,run=0,ce=0,cl=0,le=0,ll=0;
  logic [CB-1:0] ci='0;
  logic [LB-1:0] li='0;
  localparam integer WS=lpu_mxm_config_pkg::WEIGHT_STREAM_COUNT;
  localparam integer Q=lpu_mxm_config_pkg::WEIGHT_Q_STREAM,SL=lpu_mxm_config_pkg::WEIGHT_SCALE_LO_STREAM;
  localparam integer SH=lpu_mxm_config_pkg::WEIGHT_SCALE_HI_STREAM,Z=lpu_mxm_config_pkg::WEIGHT_ZERO_STREAM;
  logic [R*WS*K*8-1:0] weight_streams;
  logic [R*WS*K-1:0] weight_stream_valid='1;
  wire [R*WS*K-1:0] weight_consumed;
  integer row_load_seq[0:R-1];
  logic pe=0,pl=0,de=0,dl=0,pi=0,di=0;
  wire per,plr,der,dlr;
  wire [R-1:0] prv,drv,pri,dri;
  wire cr,clr,lr,llr,fault;
  wire [R-1:0] cv,lv;
  wire [R*CB-1:0] cp;
  wire [R*LB-1:0] lp;
  wire [R*16-1:0] cx,lx;
  logic [R*K*16-1:0] activation;
  wire [C-1:0] valid;
  wire [C*N*32-1:0] result;
  wire [C*16-1:0] tags;
  bit expected_valid[0:C-1][0:LIMIT];
  integer expected_tag[0:C-1][0:LIMIT];
  integer cycle=0,commands=0,computed=0,checked=0,source_beats=0;
  always @(posedge clk) if(rst_n && run) begin
    logic [R*WS*K-1:0] expected_consume;
    expected_consume=0;
    for(integer r=0;r<R;r++) for(integer k=0;k<K;k++) begin
      expected_consume[(r*WS+Q)*K+k]=lv[r];
      expected_consume[(r*WS+SL)*K+k]=prv[r];
      expected_consume[(r*WS+SH)*K+k]=prv[r];
      expected_consume[(r*WS+Z)*K+k]=prv[r];
    end
    if(weight_consumed!==expected_consume || drv!==lv) $fatal(1,"parameter/weight stream consume or instruction phase mismatch");
  end
  always #5 clk=~clk;
  function automatic logic [31:0] fp32_integer(input integer value);
    integer leading;
    logic [31:0] fraction;
    begin
      leading=0;for(integer b=0;b<31;b++) if((value>>b)&1) leading=b;
      fraction=32'(value)<<(23-leading);
      fp32_integer=value==0?32'b0:{1'b0,8'(leading+127),fraction[22:0]};
    end
  endfunction
  function automatic logic [LB-1:0] load_word(input integer seq);
    load_word=(LB'(seq%2)<<1) | LB'(1);
  endfunction
  always @(posedge clk) for(integer r=0;r<R;r++) begin
    if(!rst_n) row_load_seq[r]<=-1;
    else if(run && lv[r] && lx[r*16+:16]==0) row_load_seq[r]<=row_load_seq[r]+1;
  end
  always_comb begin
    activation='0;weight_streams='1;
    for(integer r=0;r<R;r++) begin
      logic [31:0] a;
      integer load_id,w;
      load_id=row_load_seq[r]+(lv[r] && lx[r*16+:16]==0?1:0);
      a=fp32_integer((int'(cx[r*16+:16])%32)%3+r+1);
      w=31-load_id/2+r+1+(lp[r*LB+1]?50:0);
      for(integer k=0;k<K;k++) begin
        activation[(r*K+k)*16+:16]=a[31:16];
        weight_streams[(r*WS*K+Q*K+k)*8+:8]=8'(w);
        weight_streams[(r*WS*K+SL*K+k)*8+:8]=8'h80;
        weight_streams[(r*WS*K+SH*K+k)*8+:8]=8'h3f;
        weight_streams[(r*WS*K+Z*K+k)*8+:8]=0;
      end
    end
  end
  lpu_mxm_frontend #(.QUEUE_DEPTH(1)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.compute_enqueue_valid_i(ce),.compute_launch_i(cl),
    .compute_instruction_i(ci),.compute_enqueue_ready_o(cr),.compute_launch_ready_o(clr),
    .load_enqueue_valid_i(le),.load_launch_i(ll),.load_instruction_i(li),.load_enqueue_ready_o(lr),.load_launch_ready_o(llr),
    .param_load_enqueue_valid_i(pe),.param_load_launch_i(pl),.param_load_instruction_i(pi),
    .param_load_enqueue_ready_o(per),.param_load_launch_ready_o(plr),
    .dequant_enqueue_valid_i(de),.dequant_launch_i(dl),.dequant_instruction_i(di),
    .dequant_enqueue_ready_o(der),.dequant_launch_ready_o(dlr),
    .param_load_row_valid_o(prv),.param_load_row_instruction_o(pri),
    .dequant_row_valid_o(drv),.dequant_row_instruction_o(dri),
    .activation_valid_i(cv),.activation_i(activation),.weight_stream_valid_i(weight_stream_valid),.weight_stream_i(weight_streams),.weight_stream_consume_o(weight_consumed),
    .compute_row_valid_o(cv),.load_row_valid_o(lv),.compute_row_instruction_o(cp),.load_row_instruction_o(lp),
    .compute_row_tag_o(cx),.load_row_index_o(lx),.result_valid_o(valid),.result_o(result),.result_tag_o(tags),
    .result_instruction_o(),.activation_forward_valid_o(),.activation_forward_o(),
    .cell_weight_valid_o(),.cell_weight_buffer_o(),.cell_activation_valid_o(),.cell_activation_buffer_o(),.fault_o(fault));
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;commands=0;computed=0;checked=0;source_beats=0;
      for(integer c=0;c<C;c++) for(integer t=0;t<=LIMIT;t++) expected_valid[c][t]=0;
    end else if(run) begin
      cycle=cycle+1;
      if(ll) begin
        if(!llr || (le && !lr)) $fatal(1,"single-shift command not ready");
        commands=commands+1;
      end
      if(cl) begin
        if(!clr || (ce && !cr)) $fatal(1,"single-fill compute not ready");
        for(integer c=0;c<C;c++) begin
          expected_valid[c][cycle+21+c]=1;expected_tag[c][cycle+21+c]=computed;
        end
        computed=computed+1;
      end
      for(integer r=0;r<R;r++) if(lv[r]) begin
        if(lx[r*16+:16]!=0 || lp[r*LB]!==1'b1) $fatal(1,"COLUMN must accept exactly one source beat");
        source_beats=source_beats+1;
      end
      #1;
      if(fault) $fatal(1,"COLUMN-only fill fault cycle=%0d",cycle);
      for(integer c=0;c<C;c++) begin
        if(valid[c]!==expected_valid[c][cycle]) $fatal(1,"COLUMN-only result phase mismatch");
        if(valid[c]) begin
          integer tag_value;
          tag_value=expected_tag[c][cycle];
          if(tags[c*16+:16]!==16'(tag_value)) $fatal(1,"COLUMN-only tag mismatch");
          for(integer g=0;g<N;g++) begin
            integer total;
            total=0;
            for(integer r=0;r<R;r++) total=total+K*((tag_value%32)%3+r+1)*(c*N+g+r+1+(tag_value>=32?50:0));
            if(result[(c*N+g)*32+:32]!==fp32_integer(total)) $fatal(1,"COLUMN-only full-chain/buffer data mismatch");
            checked=checked+1;
          end
        end
      end
    end
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    @(negedge clk);le=1;li=load_word(0);ce=1;ci=0;pe=1;pi=0;de=1;di=0;
    @(negedge clk);le=0;ce=0;pe=0;de=0;run=1;pl=1;
    for(integer t=0;t<300;t++) begin
      @(negedge clk);ll=0;le=0;cl=0;ce=0;pl=0;dl=0;de=0;
      if(t%LOAD_INTERVAL==0 && t/LOAD_INTERVAL<64) begin ll=1;dl=1;de=t/LOAD_INTERVAL<63;le=t/LOAD_INTERVAL<63;li=load_word(t/LOAD_INTERVAL+1);end
      cl=t>=63*LOAD_INTERVAL+3 && t<63*LOAD_INTERVAL+67;
      if(cl && t<63*LOAD_INTERVAL+66) begin ce=1;ci=CB'(t+1>=63*LOAD_INTERVAL+35);end
    end
    @(negedge clk);ll=0;le=0;cl=0;ce=0;pl=0;dl=0;de=0;
    if(commands!=64 || computed!=64 || source_beats!=64*R || checked!=64*C*N)
      $fatal(1,"COLUMN-only coverage missing commands=%0d beats=%0d values=%0d",commands,source_beats,checked);
    $display("MXM_WEIGHT_SHIFT_PASS instruction_bits=%0d column_commands=64 matrix_commands=0 source_beats=%0d vectors=64 fp32_results=%0d interleaved_buffers=1",LB,source_beats,checked);
    $finish;
  end
  initial begin #100000;$fatal(1,"COLUMN-only fill timeout");end
endmodule
