`timescale 1ns/1ps
module lpu_mxm_control_tb #(parameter integer ROWS=4,QUEUE_DEPTH=3);
  import lpu_mxm_isa_pkg::*;
  localparam integer CB=COMPUTE_INSTRUCTION_BITS,LB=LOAD_INSTRUCTION_BITS,LIMIT=320;
  logic clk=0,rst_n=0,run=0,ce=0,cl=0,le=0,ll=0;
  logic [CB-1:0] ci=0;
  logic [LB-1:0] li=0;
  wire cr,clr,lr,llr,fault;
  wire [ROWS-1:0] cv,cu,lv,lu;
  wire [ROWS*CB-1:0] cp;
  wire [ROWS*LB-1:0] lp;
  wire [ROWS*16-1:0] ct,lx;
  always #5 clk=~clk;
  lpu_mxm_control #(.ROWS(ROWS),.QUEUE_DEPTH(QUEUE_DEPTH)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),
    .compute_enqueue_valid_i(ce),.compute_enqueue_ready_o(cr),.compute_instruction_i(ci),
    .compute_launch_i(cl),.compute_launch_ready_o(clr),
    .load_enqueue_valid_i(le),.load_enqueue_ready_o(lr),.load_instruction_i(li),
    .load_launch_i(ll),.load_launch_ready_o(llr),
    .compute_row_valid_o(cv),.compute_row_update_o(cu),.compute_row_instruction_o(cp),.compute_row_tag_o(ct),
    .load_row_valid_o(lv),.load_row_update_o(lu),.load_row_instruction_o(lp),.load_row_index_o(lx),.fault_o(fault));
  function automatic logic [CB-1:0] compute_word(input integer n);
    compute_word=CB'(((n/32)%64)*2+(n/32)%2);
  endfunction
  function automatic logic [LB-1:0] load_word(input integer n);
    load_word=(LB'(n%2)<<1) | LB'(n>=2 && n<=4);
  endfunction
  bit ec[0:ROWS-1][0:LIMIT],el[0:ROWS-1][0:LIMIT],eu[0:ROWS-1][0:LIMIT];
  integer et[0:ROWS-1][0:LIMIT],ew[0:ROWS-1][0:LIMIT],ei[0:ROWS-1][0:LIMIT];
  integer cycle=0,issued=0,loaded=0,beats=0,load_beats=0;
  bit scoring=1;
  integer trace_fd=0;
  string trace_path,vcd_path;
  initial begin
    if($value$plusargs("trace_path=%s",trace_path)) begin
      trace_fd=$fopen(trace_path,"w");
      $fdisplay(trace_fd,"sample_ns,reset_n,run,scoring,compute_launch,load_launch,row,compute_valid,compute_update,compute_instruction,compute_tag,load_valid,load_update,load_instruction,load_index,fault");
    end
    if($value$plusargs("vcd_path=%s",vcd_path)) begin
      $dumpfile(vcd_path);$dumpvars(0,clk,rst_n,run,cl,ll,cv,cu,cp,ct,lv,lu,lp,lx,fault);
    end
  end
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;issued=0;loaded=0;beats=0;load_beats=0;
      for(integer r=0;r<ROWS;r++) for(integer t=0;t<=LIMIT;t++) begin ec[r][t]=0;el[r][t]=0;eu[r][t]=0;end
    end else if(run && scoring) begin
      cycle++;
      if(cl) begin
        if(!clr || (ce && !cr)) $fatal(1,"full-rate compute blocked");
        for(integer r=0;r<ROWS;r++) begin ec[r][cycle+3*r]=1;et[r][cycle+3*r]=issued;end
        issued++;
      end
      if(ll) begin
        if(!llr || (le && !lr)) $fatal(1,"legal fixed load blocked");
        for(integer r=0;r<ROWS;r++) begin
          eu[r][cycle+3*r]=1;
          for(integer b=0;b<(loaded>=2 && loaded<=4?1:32);b++) begin
            el[r][cycle+3*r+b]=1;ew[r][cycle+3*r+b]=loaded;ei[r][cycle+3*r+b]=b;
          end
        end
        loaded++;
      end
      #1;
      if(fault) $fatal(1,"control stream fault");
      for(integer r=0;r<ROWS;r++) begin
        if(cv[r]!==ec[r][cycle] || cu[r]!==ec[r][cycle] || lv[r]!==el[r][cycle] || lu[r]!==eu[r][cycle])
          $fatal(1,"relay valid/update/phase row=%0d cycle=%0d",r,cycle);
        if(cv[r]) begin
          if(cp[r*CB+:CB]!==compute_word(et[r][cycle]) || ct[r*16+:16]!==16'(et[r][cycle]))
            $fatal(1,"relay compute word/tag mismatch");
          beats++;
        end
        if(lv[r]) begin
          if(lp[r*LB+:LB]!==load_word(ew[r][cycle]) || lx[r*16+:16]!==16'(ei[r][cycle]))
            $fatal(1,"fixed loader length/index mismatch row=%0d cycle=%0d",r,cycle);
          load_beats++;
        end
      end
    end
    #1;
    if(trace_fd) for(integer r=0;r<ROWS;r++)
      $fdisplay(trace_fd,"%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d,%h,%0d,%0d",
        $realtime,rst_n,run,scoring,cl,ll,r,cv[r],cu[r],cp[r*CB+:CB],ct[r*16+:16],lv[r],lu[r],lp[r*LB+:LB],lx[r*16+:16],fault);
  end
  final if(trace_fd) $fclose(trace_fd);
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    @(negedge clk);ce=1;ci=compute_word(0);le=1;li=load_word(0);
    @(negedge clk);ce=0;le=0;run=1;
    for(integer t=0;t<240;t++) begin
      @(negedge clk);cl=t<200 && t!=95;ce=cl && issued+1<199;
      if(ce) ci=compute_word(issued+1);
      ll=t==0 || t==32 || t==64 || t==65 || t==66 || t==67;
      le=ll && loaded<5;if(le) li=load_word(loaded+1);
    end
    @(negedge clk);cl=0;ce=0;ll=0;le=0;
    if(issued!=199 || loaded!=6 || beats!=199*ROWS || load_beats!=99*ROWS) $fatal(1,"control coverage missing");
    $display("MXM_CONTROL_PASS rows=%0d queue_depth=%0d compute_beats=%0d load_beats=%0d interval=3 identical_words=1 bubbles=1",ROWS,QUEUE_DEPTH,beats,load_beats);
    scoring=0;
    // Empty launch must fault; run=0 clears flight validity and sticky fault.
    cl=1;@(negedge clk);cl=0;if(!fault) $fatal(1,"empty launch not detected");
    run=0;repeat(2) @(negedge clk);
    if(cv || lv || fault) $fatal(1,"run flush failed");
    // Fixed MATRIX still rejects replacement before its last input beat.
    le=1;li=load_word(0);@(negedge clk);le=0;run=1;
    @(negedge clk);ll=1;le=1;li=load_word(1);
    @(negedge clk);ll=0;le=0;
    @(negedge clk);ll=1;@(negedge clk);ll=0;
    if(!fault) $fatal(1,"early MATRIX replacement not rejected");
    rst_n=0;#1;if(cv || lv || fault) $fatal(1,"reset flush failed");
    $display("MXM_CONTROL_FAULT_RESET_PASS");$finish;
  end
  initial begin #100000;$fatal(1,"control timeout");end
endmodule
