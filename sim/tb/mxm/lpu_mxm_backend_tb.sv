`timescale 1ns/1ps
module lpu_mxm_backend_tb;
  parameter integer COLS=4,LANES=8,QUEUE_DEPTH=3;
  localparam integer DEPTH=1024,ROW_BITS=9,BITS=LANES*32,LIMIT=1000,COMMANDS=18;
  logic clk=0,rst_n=0,run=0,enqueue=0,launch=0;
  import lpu_mxm_backend_isa_pkg::*;
  localparam integer AB=BACKEND_ADDRESS_BITS,IB=BACKEND_INSTRUCTION_BITS;
  logic [IB-1:0] instruction=0;
  wire enqueue_ready,launch_ready,fault;
  logic [COLS-1:0] pv=0;
  logic [COLS*BITS-1:0] pd=0;
  logic [COLS*16-1:0] pt=0;
  wire [COLS-1:0] sv,rv,av,sq,rq;
  wire [COLS-1:0] iv,iq;
  wire [COLS*16-1:0] ia;
  wire [COLS*2-1:0] io;
  wire [COLS*16-1:0] sa,ra,rt,aa,at;
  wire [COLS*2-1:0] so,bv,bw;
  wire [COLS*BITS-1:0] rd,opa,opb;
  wire [COLS*2*ROW_BITS-1:0] ba;
  wire [COLS*2*BITS-1:0] bd;
  always #5 clk=~clk;
  lpu_mxm_backend #(.COLS(COLS),.LANES(LANES),.QUEUE_DEPTH(QUEUE_DEPTH)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.enqueue_valid_i(enqueue),.enqueue_ready_o(enqueue_ready),
    .instruction_i(instruction),.launch_i(launch),.launch_ready_o(launch_ready),
    .partial_valid_i(pv),.partial_i(pd),.partial_tag_i(pt),.slot_valid_o(sv),.slot_address_o(sa),.slot_operation_o(so),.slot_bf16_o(sq),
    .issue_valid_o(iv),.issue_address_o(ia),.issue_operation_o(io),.issue_bf16_o(iq),
    .result_valid_o(rv),.result_bf16_o(rq),.result_o(rd),.result_address_o(ra),.result_tag_o(rt),
    .bank_request_valid_o(bv),.bank_write_o(bw),.bank_address_o(ba),.bank_write_data_o(bd),
    .alu_valid_o(av),.operand_a_o(opa),.operand_b_o(opb),.alu_address_o(aa),.alu_tag_o(at),.fault_o(fault));
  logic [767:0] vectors[0:2303];
  logic [255:0] output_vectors[0:2303];
  function automatic integer operation(input integer command);
    case(command)
      0,3,8,9,11:operation=1;
      5,10,13,14:operation=2;
      7,12,15,16:operation=3;
      default:operation=0;
    endcase
  endfunction
  function automatic bit output_bf16(input integer command);
    output_bf16=(operation(command)==0 || operation(command)==3) && command%2==1;
  endfunction
  function automatic logic [IB-1:0] word_for(input integer op,input integer count,input integer base);
    word_for=(IB'(count-1)<<(AB+2)) | (IB'(base)<<2) | IB'(op);
  endfunction
  bit scoring=1;
  integer trace_fd=0;
  string trace_path,vcd_path;
  initial begin
    if($value$plusargs("trace_path=%s",trace_path)) begin
      trace_fd=$fopen(trace_path,"w");if(!trace_fd) $fatal(1,"cannot open backend trace");
      $fdisplay(trace_fd,"sample_ns,reset_n,run,scoring,launch,column,slot_valid,slot_address,slot_operation,partial_valid,partial_tag,partial_lane0,bank0_valid,bank0_write,bank0_address,bank0_data0,bank1_valid,bank1_write,bank1_address,bank1_data0,alu_valid,alu_address,alu_tag,operand_a0,operand_b0,result_valid,result_address,result_tag,result_lane0,fault,slot_bf16,result_bf16,issue_valid,issue_address,issue_operation,issue_bf16");
    end
    if($value$plusargs("vcd_path=%s",vcd_path)) begin
      $dumpfile(vcd_path);$dumpvars(0,clk,rst_n,run,launch,instruction,iv,ia,io,iq,sv,sa,so,sq,pv,pd,pt,bv,bw,ba,bd,av,opa,opb,aa,at,rv,rd,rq,ra,rt,fault);
    end
  end
  // Issue, bank requests and A/B are sampled BEFORE their consuming edge;
  // only registered results are sampled AFTER it.
  always @(posedge clk) begin : trace_ports
    logic [COLS-1:0] service_slot,service_partial,service_format,service_alu,service_issue,service_iq;
    logic [COLS*16-1:0] service_aa,service_at,service_ia;
    logic [COLS*2-1:0] service_io;
    logic [COLS*BITS-1:0] service_a,service_b;
    logic [COLS*16-1:0] service_address,service_tag;
    logic [COLS*2-1:0] service_operation,service_bv,service_bw;
    logic [COLS*BITS-1:0] service_data;
    logic [COLS*2*ROW_BITS-1:0] service_ba;
    logic [COLS*2*BITS-1:0] service_bd;
    service_slot=sv;service_partial=pv;service_address=sa;service_tag=pt;service_operation=so;
    service_format=sq;
    service_alu=av;service_aa=aa;service_at=at;service_a=opa;service_b=opb;
    service_issue=iv;service_ia=ia;service_io=io;service_iq=iq;
    service_data=pd;service_bv=bv;service_bw=bw;service_ba=ba;service_bd=bd;
    #2;
    if(trace_fd) for(integer c=0;c<COLS;c++)
      $fdisplay(trace_fd,"%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%08h,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
        $realtime,rst_n,run,scoring,launch,c,service_slot[c],service_address[c*16+:16],service_operation[c*2+:2],
        service_partial[c],service_tag[c*16+:16],service_data[c*BITS+:32],
        service_bv[c*2],service_bw[c*2],service_ba[c*2*ROW_BITS+:ROW_BITS],service_bd[c*2*BITS+:32],
        service_bv[c*2+1],service_bw[c*2+1],service_ba[(c*2+1)*ROW_BITS+:ROW_BITS],service_bd[(c*2+1)*BITS+:32],
        service_alu[c],service_aa[c*16+:16],service_at[c*16+:16],service_a[c*BITS+:32],service_b[c*BITS+:32],
        rv[c],ra[c*16+:16],rt[c*16+:16],rd[c*BITS+:32],fault,service_format[c],rq[c],service_issue[c],service_ia[c*16+:16],service_io[c*2+:2],service_iq[c]);
  end
  final if(trace_fd) $fclose(trace_fd);
  bit ei[0:COLS-1][0:LIMIT],er[0:COLS-1][0:LIMIT],ea[0:COLS-1][0:LIMIT];
  integer item_i[0:COLS-1][0:LIMIT],item_r[0:COLS-1][0:LIMIT],item_a[0:COLS-1][0:LIMIT];
  bit ebv[0:COLS-1][0:1][0:LIMIT],ebw[0:COLS-1][0:1][0:LIMIT];
  integer eaddr[0:COLS-1][0:1][0:LIMIT],eitem[0:COLS-1][0:1][0:LIMIT];
  integer cycle=0,sequence_id=0,outputs=0,adds=0,reads=0,writes=0;
  bit check_tail=0;
  integer tail_outputs=0;
  bit check_short=0;
  integer short_tick=0,short_outputs=0;
  // All 16 ordered pairs of {direct-FP32,direct-BF16,acc-FP32,acc-BF16}.
  function automatic integer short_state(input integer index);
    case(index)
      0,1,3,5,16:short_state=0;
      2,7,8,10:short_state=1;
      4,9,12,13:short_state=2;
      default:short_state=3;
    endcase
  endfunction
  function automatic logic [IB-1:0] short_word(input integer index);
    integer state;
    begin
      state=short_state(index);
      short_word=word_for(state>=2?3:0,1,DEPTH-2+index%2) | (IB'(state%2)<<(IB-1));
    end
  endfunction
  always @(posedge clk) begin
    #1;
    if(check_tail) for(integer c=0;c<COLS;c++) if(rv[c]) begin
      if(rq[c]) $fatal(1,"unexpected BF16 tail output");
      if(ra[c*16+:16]<DEPTH-2 || ra[c*16+:16]>=DEPTH) $fatal(1,"tail address mismatch");
      for(integer lane=0;lane<LANES;lane++)
        if(rd[(c*LANES+lane)*32+:32]!==32'h40000000) $fatal(1,"tail SRAM word data mismatch");
      tail_outputs=tail_outputs+1;
    end
    if(check_short) begin
      if(fault) $fatal(1,"COUNT1 output mode stream fault tick=%0d",short_tick);
      for(integer c=0;c<COLS;c++) begin
        bit due;
        integer item,state;
        logic [31:0] expected;
        due=short_tick>=6+c && short_tick<23+c;
        if(rv[c]!==due) $fatal(1,"COUNT1 output gap/extra tick=%0d column=%0d",short_tick,c);
        if(due) begin
          item=short_tick-6-c;state=short_state(item);
          expected=state>=2?32'h40000000:32'h3f800000;
          if(state%2==1) expected=expected>>16;
          if(rq[c]!==1'(state%2) || rt[c*16+:16]!==16'(1000+item) || ra[c*16+:16]!==16'(DEPTH-2+item%2))
            $fatal(1,"COUNT1 output metadata mismatch");
          for(integer lane=0;lane<LANES;lane++)
            if(rd[(c*LANES+lane)*32+:32]!==expected) $fatal(1,"COUNT1 output data mismatch");
          short_outputs=short_outputs+1;
        end
      end
    end
  end
  task automatic expect_bank(input integer c,input integer bank,input integer due,input bit write_op,input integer item);
    begin
      if(ebv[c][bank][due]) $fatal(1,"test schedule itself collides");
      ebv[c][bank][due]=1;ebw[c][bank][due]=write_op;eitem[c][bank][due]=item;
      eaddr[c][bank][due]=(item/4)%32;
    end
  endtask
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;sequence_id=0;outputs=0;adds=0;reads=0;writes=0;
      for(integer c=0;c<COLS;c++) for(integer t=0;t<=LIMIT;t++) begin
        ei[c][t]=0;er[c][t]=0;ea[c][t]=0;
        for(integer b=0;b<2;b++) begin ebv[c][b][t]=0;ebw[c][b][t]=0;end
      end
    end else if(run && scoring) begin
      cycle=cycle+1;
      if(launch) begin
        if(!launch_ready) $fatal(1,"legal backend launch blocked");
        for(integer c=0;c<COLS;c++) for(integer t=0;t<32;t++) begin
          integer item,op;
          item=(sequence_id*32+t)*4+c;op=operation(sequence_id);
          ei[c][cycle+c+3+t]=1;item_i[c][cycle+c+3+t]=item;
          if(op>=2) expect_bank(c,t%2,cycle+c+1+t,0,item);
          if(op>=2) begin ea[c][cycle+c+3+t]=1;item_a[c][cycle+c+3+t]=item;end
          if(op==1 || op==2) expect_bank(c,t%2,cycle+c+6+t,1,item);
          if(op==0 || op==3) begin er[c][cycle+c+6+t]=1;item_r[c][cycle+c+6+t]=item;end
        end
        sequence_id=sequence_id+1;
      end
      // Actual single-port requests are sampled on their service edge.
      for(integer c=0;c<COLS;c++) begin
        if(av[c]!==ea[c][cycle]) $fatal(1,"ALU capture phase mismatch column=%0d cycle=%0d",c,cycle);
        if(av[c]) begin
          integer item;
          item=item_a[c][cycle];
          if(opa[c*BITS+:BITS]!==pd[c*BITS+:BITS] || opa[c*BITS+:BITS]!==vectors[item][512+:BITS] || opb[c*BITS+:BITS]!==vectors[item][256+:BITS] ||
             aa[c*16+:16]!==16'((item/4)%32) || at[c*16+:16]!==16'(item/4)) $fatal(1,"direct A/prefetched B, address or tag mismatch item=%0d",item);
          adds=adds+1;
        end
        if(sv[c]!==ei[c][cycle] || pv[c]!==ei[c][cycle]) $fatal(1,"intake gap/extra column=%0d cycle=%0d",c,cycle);
        if(sv[c] && (sa[c*16+:16]!==16'((item_i[c][cycle]/4)%32) ||
           so[c*2+:2]!==2'(operation(item_i[c][cycle]/128)) || sq[c]!==output_bf16(item_i[c][cycle]/128))) $fatal(1,"slot address/op/format mismatch");
        for(integer b=0;b<2;b++) begin
          if(bv[c*2+b]!==ebv[c][b][cycle]) $fatal(1,"bank request latency column=%0d bank=%0d cycle=%0d",c,b,cycle);
          if(bv[c*2+b]) begin
            integer item;
            logic [BITS-1:0] expected;
            item=eitem[c][b][cycle];
            if(bw[c*2+b]!==ebw[c][b][cycle] || ba[(c*2+b)*ROW_BITS+:ROW_BITS]!==ROW_BITS'(eaddr[c][b][cycle]/2))
              $fatal(1,"bank mode/address mismatch");
            if(bw[c*2+b]) begin
              expected=operation(item/128)==1?vectors[item][512+:BITS]:vectors[item][0+:BITS];
              if(bd[(c*2+b)*BITS+:BITS]!==expected) $fatal(1,"bank write data mismatch item=%0d",item);
              writes=writes+1;
            end else reads=reads+1;
          end
        end
      end
      #1;
      if(fault) $fatal(1,"legal backend traffic fault cycle=%0d",cycle);
      for(integer c=0;c<COLS;c++) begin
        if(rv[c]!==er[c][cycle]) $fatal(1,"output valid phase mismatch column=%0d cycle=%0d",c,cycle);
        if(rv[c]) begin
          integer item;
          item=item_r[c][cycle];
          if(rd[c*BITS+:BITS]!==output_vectors[item][0+:BITS] || rq[c]!==output_bf16(item/128) || ra[c*16+:16]!==16'((item/4)%32) || rt[c*16+:16]!==16'(item/4))
            $fatal(1,"backend output mismatch item=%0d got=%h expected=%h",item,rd[c*BITS+:BITS],output_vectors[item][0+:BITS]);
          outputs=outputs+1;
        end
      end
    end
  end
  task automatic reset_backend;
    begin
      @(negedge clk);rst_n=0;run=0;enqueue=0;launch=0;pv=0;
      #1;if(rv!==0 || bv!==0 || av!==0 || fault!==0) $fatal(1,"backend reset failed");
      repeat(2) @(negedge clk);rst_n=1;
    end
  endtask
  task automatic enqueue_one(input integer op,input integer count,input integer base);
    begin
      @(negedge clk);enqueue=1;instruction=word_for(op,count,base);
      #1;if(!enqueue_ready) $fatal(1,"enqueue unexpectedly full");
      @(negedge clk);enqueue=0;
    end
  endtask
  task automatic launch_one;
    begin
      @(negedge clk);launch=1;#1;if(!launch_ready) $fatal(1,"launch unexpectedly blocked");
      @(negedge clk);launch=0;
    end
  endtask
  task automatic drive_slots(input integer cycles);
    begin
      for(integer t=0;t<cycles;t++) begin
        pv=sv;pt=0;
        for(integer lane=0;lane<COLS*LANES;lane++) pd[lane*32+:32]=32'h3f800000;
        @(negedge clk);
      end
      pv=0;
    end
  endtask
  string path,output_path;
  initial begin
    if(!$value$plusargs("vectors=%s",path)) $fatal(1,"missing backend vectors");
    $readmemh(path,vectors);
    if(!$value$plusargs("output_vectors=%s",output_path)) $fatal(1,"missing backend output vectors");
    $readmemh(output_path,output_vectors);
    repeat(3) @(negedge clk);rst_n=1;
    enqueue_one(operation(0),32,0);run=1;
    for(integer t=0;t<COMMANDS*32+20;t++) begin
      @(negedge clk);enqueue=0;launch=t<COMMANDS*32 && t%32==0;
      if(launch && t/32+1<COMMANDS) begin
        enqueue=1;instruction=word_for(operation(t/32+1),32,0) | (IB'(output_bf16(t/32+1))<<(IB-1));
      end
      for(integer c=0;c<COLS;c++) begin
        integer item;
        pv[c]=ei[c][cycle+1];item=item_i[c][cycle+1];
        if(pv[c]) begin pd[c*BITS+:BITS]=vectors[item][512+:BITS];pt[c*16+:16]=16'(item/4);end
      end
    end
    @(negedge clk);enqueue=0;launch=0;pv=0;
    if(sequence_id!=18 || outputs!=9*32*COLS || adds!=8*32*COLS || writes!=9*32*COLS || reads!=8*32*COLS)
      $fatal(1,"backend counts mismatch outputs=%0d adds=%0d reads=%0d writes=%0d",outputs,adds,reads,writes);
    $display("MXM_BACKEND_PASS columns=%0d lanes=%0d batches=576 transitions=16 formats=2 output_latency=6 partial_to_output=4 direct_A=1 outputs=%0d adds=%0d reads=%0d writes=%0d",COLS,LANES,outputs,adds,reads,writes);
    scoring=0;
    reset_backend();enqueue_one(1,2,DEPTH-2);run=1;launch_one();drive_slots(15);
    if(fault) $fatal(1,"last bank rows STORE failed");
    enqueue_one(3,2,DEPTH-2);launch_one();check_tail=1;drive_slots(15);check_tail=0;
    if(fault || tail_outputs!=2*COLS) $fatal(1,"last bank rows accumulation failed");
    $display("MXM_BACKEND_DEPTH_PASS logical_depth=1024 last_addresses=1022,1023");
    // Both tail rows retain FP32 1.0; ACC_OUT produces 2.0 without writeback.
    // Launch one command per edge, keeping multiple different instructions
    // simultaneously in the prefetch-control pipeline. Never drive from DUT sv.
    enqueue_one(0,1,DEPTH-2);check_short=1;
    for(integer t=0;t<32;t++) begin
      @(negedge clk);short_tick=t;launch=t<17;enqueue=t<16;
      if(enqueue) instruction=short_word(t+1);
      for(integer c=0;c<COLS;c++) begin
        pv[c]=t>=3+c && t<20+c;pt[c*16+:16]=16'(1000+t-3-c);
        for(integer lane=0;lane<LANES;lane++) pd[(c*LANES+lane)*32+:32]=32'h3f800000;
      end
    end
    @(negedge clk);launch=0;enqueue=0;pv=0;check_short=0;
    if(short_outputs!=17*COLS) $fatal(1,"missing COUNT1 outputs");
    $display("MXM_BACKEND_COUNT1_PASS commands=17 mode_transitions=16 outputs=%0d",short_outputs);
    reset_backend();run=1;
    launch=1;@(negedge clk);launch=0;
    if(!fault) $fatal(1,"empty launch not detected");
    reset_backend();enqueue_one(1,1024,1);run=1;launch_one();
    if(!fault || sv!==0) $fatal(1,"maximum COUNT address overflow executed");
    for(integer op=1;op<=2;op++) begin
      reset_backend();
      @(negedge clk);enqueue=1;instruction=word_for(op,1,0) | (IB'(1)<<(IB-1));
      @(negedge clk);enqueue=0;run=1;launch_one();
      if(!fault || sv!==0 || bv!==0) $fatal(1,"BF16 storage instruction not rejected");
    end
    reset_backend();enqueue_one(3,1,40);run=1;launch_one();
    drive_slots(12);
    if(!fault || rv!==0) $fatal(1,"uninitialized SRAM read not rejected");
    reset_backend();enqueue_one(0,1,0);run=1;launch_one();
    repeat(3) @(negedge clk);
    if(!fault) $fatal(1,"missing partial not detected");
    reset_backend();enqueue_one(1,2,DEPTH-1);run=1;launch_one();
    if(!fault || sv!==0 || bv!==0) $fatal(1,"address overflow not rejected");
    // Original SRAM value must be committed before any read. First initialize
    // address zero, then deliberately violate a pending ACC_STORE dependency.
    reset_backend();enqueue_one(1,1,0);run=1;launch_one();drive_slots(12);
    if(fault) $fatal(1,"single-batch STORE failed");
    enqueue_one(2,1,0);enqueue_one(3,1,0);launch_one();
    // Next launch on the immediately following edge: legal command cadence,
    // illegal address reuse before the first accumulation has written back.
    launch=1;
    drive_slots(1);launch=0;drive_slots(14);
    if(!fault) $fatal(1,"read-before-write dependency not detected");
    // Force a first request onto the same bank/edge as a five-cycle writeback.
    reset_backend();enqueue_one(1,1,0);run=1;launch_one();drive_slots(12);
    enqueue_one(2,1,0);enqueue_one(1,1,0);launch_one();
    drive_slots(4);launch=1;drive_slots(1);launch=0;drive_slots(14);
    if(!fault) $fatal(1,"same-bank writeback collision not detected");
    reset_backend();run=1;
    repeat(12) @(negedge clk);
    if(rv!==0 || bv!==0 || av!==0 || fault) $fatal(1,"stale backend transactions after reset");
    $display("MXM_BACKEND_FAULT_RESET_PASS");$finish;
  end
  initial begin #150000;$fatal(1,"backend timeout");end
endmodule
