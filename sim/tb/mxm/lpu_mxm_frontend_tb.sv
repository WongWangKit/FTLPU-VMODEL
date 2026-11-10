`timescale 1ns/1ps
module lpu_mxm_frontend_tb;
  localparam integer R=4,C=4,K=8,N=8,LIMIT=400;
  import lpu_mxm_isa_pkg::*;
  localparam integer CB=COMPUTE_INSTRUCTION_BITS,LB=LOAD_INSTRUCTION_BITS;
  logic clk=0,rst_n=0,run=0,ce=0,cl=0,le=0,ll=0;
  logic [CB-1:0] ci=0;
  logic [LB-1:0] li=0;
  wire cr,clr,lr,llr,fault;
  wire [R-1:0] cv,lv;
  wire [R*CB-1:0] cp;
  wire [R*LB-1:0] lp;
  wire [R*16-1:0] cx,lx;
  wire [C-1:0] rv;
  wire [C*N*32-1:0] result;
  wire [C*16-1:0] tags;
  wire [C*CB-1:0] commands;
  logic [R*K*16-1:0] activation,weight_data;
  logic drop_activation=0;
  bit scoring=1;
  integer trace_fd=0;
  string trace_path,vcd_path;
  initial begin
    if($value$plusargs("trace_path=%s",trace_path)) begin
      trace_fd=$fopen(trace_path,"w");
      if(!trace_fd) $fatal(1,"cannot open frontend trace");
      $fdisplay(trace_fd,"sample_ns,reset_n,run,scoring,compute_launch,load_launch,column,compute_row_valid,compute_instruction,compute_index,load_row_valid,load_instruction,load_index,result_valid,result_tag,result_instruction,result_lane0,fault");
    end
    if($value$plusargs("vcd_path=%s",vcd_path)) begin
      $dumpfile(vcd_path);
      $dumpvars(0,clk,rst_n,run,cl,ll,cp,cx,lp,lx,cv,lv,rv,result,tags,commands,fault);
    end
  end
  always @(posedge clk) begin
    #2;
    if(trace_fd) for(integer c=0;c<C;c++)
      $fdisplay(trace_fd,"%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%016h,%0d,%0d,%016h,%0d,%0d,%0d,%016h,%08h,%0d",
        $realtime,rst_n,run,scoring,cl,ll,c,cv[c],cp[c*CB+:CB],cx[c*16+:16],lv[c],lp[c*LB+:LB],lx[c*16+:16],
        rv[c],tags[c*16+:16],commands[c*CB+:CB],result[c*N*32+:32],fault);
  end
  final if(trace_fd) $fclose(trace_fd);
  always #5 clk=~clk;
  lpu_mxm_frontend #(.QUEUE_DEPTH(3)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.compute_enqueue_valid_i(ce),.compute_launch_i(cl),
    .compute_instruction_i(ci),.compute_enqueue_ready_o(cr),.compute_launch_ready_o(clr),
    .load_enqueue_valid_i(le),.load_launch_i(ll),.load_instruction_i(li),.load_enqueue_ready_o(lr),.load_launch_ready_o(llr),
    .activation_valid_i(drop_activation?(cv & 4'b1110):cv),.weight_valid_i(lv),.activation_i(activation),.weight_i(weight_data),
    .compute_row_valid_o(cv),.load_row_valid_o(lv),.compute_row_instruction_o(cp),.load_row_instruction_o(lp),
    .compute_row_index_o(cx),.load_row_index_o(lx),.result_valid_o(rv),.result_o(result),.result_tag_o(tags),
    .result_instruction_o(commands),
    .activation_forward_valid_o(),.activation_forward_o(),
    .cell_weight_valid_o(),.cell_weight_buffer_o(),.cell_activation_valid_o(),.cell_activation_buffer_o(),.fault_o(fault));
  function automatic logic [31:0] fp32_integer(input integer value);
    integer leading;
    logic [31:0] fraction;
    begin
      leading=0;for(integer b=0;b<31;b++) if((value>>b)&1) leading=b;
      fraction=32'(value)<<(23-leading);
      fp32_integer=value==0?32'b0:{1'b0,8'(leading+127),fraction[22:0]};
    end
  endfunction
  function automatic logic [CB-1:0] compute_word(input integer seq);
    logic [CB-1:0] word_value;
    begin
      word_value='0;
      word_value[10:1]=seq==1?10'd39:10'd31;
      word_value[0]=seq==1;
      word_value[16:11]=6'(seq+1);
      compute_word=word_value;
    end
  endfunction
  function automatic logic [LB-1:0] load_word(input integer bank,input integer stream,input bit single_shift);
    logic [LB-1:0] word_value;
    begin
      word_value='0;word_value[1]=1'(bank);
      word_value[0]=single_shift;word_value[7:2]=6'(stream);
      load_word=word_value;
    end
  endfunction
  always_comb begin
    activation=0;weight_data=0;
    for(integer r=0;r<R;r++) begin
      integer column_number,w;
      logic [31:0] a_bits,w_bits;
      a_bits=fp32_integer(int'(cx[r*16+:16])%3+r+1);
      column_number=31-int'(lx[r*16+:16]);
      w=lp[r*LB]?100+10*int'(lp[r*LB+2+:6])+r:column_number+r+1+(lp[r*LB+1]?20:0);
      w_bits=fp32_integer(w);
      for(integer k=0;k<K;k++) begin
        activation[(r*K+k)*16+:16]=a_bits[31:16];
        weight_data[(r*K+k)*16+:16]=w_bits[31:16];
      end
    end
  end
  bit expected_valid[0:C-1][0:LIMIT];
  logic [CB-1:0] expected_command[0:C-1][0:LIMIT];
  integer expected_tag[0:C-1][0:LIMIT];
  integer cycle=0,sequence_id=0,base_tag=0,checked=0;
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;sequence_id=0;base_tag=0;checked=0;
      for(integer c=0;c<C;c++) for(integer t=0;t<=LIMIT;t++) expected_valid[c][t]=0;
    end else if(run && scoring) begin
      cycle=cycle+1;
      if(cl) begin
        integer count;
        logic [CB-1:0] word_value;
        if(!clr) $fatal(1,"frontend compute launch blocked");
        word_value=compute_word(sequence_id);count=int'(word_value[10:1])+1;
        for(integer c=0;c<C;c++) for(integer t=0;t<count;t++) begin
          integer due;
          logic [CB-1:0] addressed;
          due=cycle+21+c+t;addressed=word_value;
          expected_valid[c][due]=1;expected_command[c][due]=addressed;expected_tag[c][due]=base_tag+t;
        end
        base_tag=base_tag+count;sequence_id=sequence_id+1;
      end
      if(ll && !llr) $fatal(1,"frontend load launch blocked");
      #1;
      if(fault) $fatal(1,"legal frontend traffic fault cycle=%0d",cycle);
      for(integer c=0;c<C;c++) begin
        if(rv[c]!==expected_valid[c][cycle]) $fatal(1,"frontend latency/valid mismatch column=%0d cycle=%0d",c,cycle);
        if(rv[c]) begin
          integer tag_value,seq,idx;
          tag_value=expected_tag[c][cycle];seq=tag_value<32?0:(tag_value<72?1:2);
          idx=tag_value-(seq==0?0:(seq==1?32:72));
          if(tags[c*16+:16]!==16'(tag_value) || commands[c*CB+:CB]!==expected_command[c][cycle])
            $fatal(1,"in-flight result metadata corrupted column=%0d tag=%0d",c,tag_value);
          for(integer g=0;g<N;g++) begin
            integer total,col,w;
            total=0;col=c*N+g;
            for(integer r=0;r<R;r++) begin
              // Two COLUMN commands shifted the full bank0 chain twice:
              // new group0=120+r, group1=110+r, group n>=2=old[n-2].
              w=seq==1?col+r+21:(col==0?120+r:(col==1?110+r:col+r-1));
              total=total+K*(idx%3+r+1)*w;
            end
            if(result[(c*N+g)*32+:32]!==fp32_integer(total))
              $fatal(1,"frontend arithmetic/shift-chain mismatch column=%0d group=%0d tag=%0d",c,g,tag_value);
            checked=checked+1;
          end
        end
      end
    end
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    @(negedge clk);le=1;li=load_word(0,0,0);ce=1;ci=compute_word(0);
    @(negedge clk);le=0;ce=0;run=1;
    for(integer t=0;t<240;t++) begin
      @(negedge clk);le=0;ce=0;ll=0;cl=0;
      case(t)
        0:begin ll=1;le=1;li=load_word(1,0,0);end
        32:begin ll=1;le=1;li=load_word(0,1,1);end
        // COLUMN follows MATRIX while tails are in flight. Data, valid
        // and buffer ID must stay associated in the shared shift chain.
        64:begin ll=1;le=1;li=load_word(0,2,1);end
        67:begin ll=1;le=1;li=load_word(1,0,0);end
        // Simultaneous compute on bank0 and reload of the inactive bank1.
        72:begin cl=1;ce=1;ci=compute_word(1);ll=1;end
        104:begin cl=1;ce=1;ci=compute_word(2);end
        144:cl=1;
        default:begin end
      endcase
    end
    @(negedge clk);le=0;ce=0;cl=0;ll=0;
    if(checked!=104*C*N) $fatal(1,"missing frontend results checked=%0d",checked);
    $display("MXM_FRONTEND_PASS vectors=104 fp32_results=%0d rows=4 columns=4",checked);
    scoring=0;
    // Missing activation is a schedule fault, not a stall or local retry.
    @(negedge clk);ce=1;ci=compute_word(0);
    @(negedge clk);ce=0;cl=1;
    @(negedge clk);cl=0;drop_activation=1;
    repeat(2) @(negedge clk);
    if(!fault) $fatal(1,"missing activation not detected");
    rst_n=0;run=0;drop_activation=0;
    #1;if(rv!==0 || cv!==0 || lv!==0 || fault!==0) $fatal(1,"frontend reset failed");
    repeat(2) @(negedge clk);rst_n=1;run=1;
    repeat(40) @(negedge clk);
    if(rv!==0 || fault) $fatal(1,"old transactions survived reset");
    $display("MXM_FRONTEND_FAULT_RESET_PASS");$finish;
  end
  initial begin #100000;$fatal(1,"frontend timeout");end
endmodule
