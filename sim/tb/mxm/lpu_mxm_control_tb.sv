`timescale 1ns/1ps
module lpu_mxm_control_tb;
  parameter integer ROWS=4,QUEUE_DEPTH=3;
  localparam integer LIMIT=240;
  logic clk=0,rst_n=0,run=0,ce=0,cl=0,le=0,ll=0;
  logic [63:0] ci=0,li=0;
  wire cr,lr,clr,llr,fault;
  wire [ROWS-1:0] cv,cu,lv,lu;
  wire [ROWS*64-1:0] cp,lp;
  wire [ROWS*16-1:0] cx,ct,lx;
  bit scoring=1;
  // Optional trace exports contain public DUT ports only, never expectations.
  integer trace_fd=0;
  string trace_path,vcd_path;
  initial begin
    if($value$plusargs("trace_path=%s",trace_path)) begin
      trace_fd=$fopen(trace_path,"w");
      if(!trace_fd) $fatal(1,"cannot open control trace");
      $fdisplay(trace_fd,"sample_ns,reset_n,run,scoring,compute_launch,load_launch,row,compute_valid,compute_update,compute_instruction,compute_index,compute_tag,load_valid,load_update,load_instruction,load_index,fault");
    end
    if($value$plusargs("vcd_path=%s",vcd_path)) begin
      $dumpfile(vcd_path);
      $dumpvars(0,clk,rst_n,run,cl,ll,ci,li,cv,cu,cp,cx,ct,lv,lu,lp,lx,fault);
    end
  end
  always @(posedge clk) begin
    #2;
    if(trace_fd) for(integer r=0;r<ROWS;r++)
      $fdisplay(trace_fd,"%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%016h,%0d,%0d,%0d,%0d,%016h,%0d,%0d",
        $realtime,rst_n,run,scoring,cl,ll,r,cv[r],cu[r],cp[r*64+:64],cx[r*16+:16],ct[r*16+:16],
        lv[r],lu[r],lp[r*64+:64],lx[r*16+:16],fault);
  end
  final if(trace_fd) $fclose(trace_fd);
  always #5 clk=~clk;
  lpu_mxm_control #(.ROWS(ROWS),.QUEUE_DEPTH(QUEUE_DEPTH)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.compute_enqueue_valid_i(ce),.compute_enqueue_ready_o(cr),
    .compute_instruction_i(ci),.compute_launch_i(cl),.compute_launch_ready_o(clr),
    .load_enqueue_valid_i(le),.load_enqueue_ready_o(lr),.load_instruction_i(li),.load_launch_i(ll),
    .load_launch_ready_o(llr),.compute_row_valid_o(cv),.compute_row_update_o(cu),.compute_row_instruction_o(cp),
    .compute_row_index_o(cx),.compute_row_tag_o(ct),.load_row_valid_o(lv),.load_row_update_o(lu),
    .load_row_instruction_o(lp),.load_row_index_o(lx),.fault_o(fault));
  function automatic logic [63:0] compute_word(input integer n,input integer bank,input integer base);
    logic [63:0] word_value;
    begin
      word_value=64'h8000000000000002;
      word_value[18:3]=16'(n);word_value[2]=1'(bank);word_value[44:39]=6'(base/64);
      compute_word=word_value;
    end
  endfunction
  function automatic logic [63:0] load_word(input integer column_number);
    logic [63:0] word_value;
    begin
      word_value=64'h8000000000000000;
      if(column_number>=0) begin word_value[1:0]=1;word_value[62:57]=6'(column_number);end
      load_word=word_value;
    end
  endfunction
  logic [63:0] cq[0:31],lq[0:31];
  integer ch=0,ctail=0,lh=0,ltail=0,cycle=0,next_tag=0,checked_c=0,checked_l=0,updates=0;
  bit ecv[0:ROWS-1][0:LIMIT],elv[0:ROWS-1][0:LIMIT],ecu[0:ROWS-1][0:LIMIT],elu[0:ROWS-1][0:LIMIT];
  logic [63:0] ecp[0:ROWS-1][0:LIMIT],elp[0:ROWS-1][0:LIMIT];
  integer ecx[0:ROWS-1][0:LIMIT],elx[0:ROWS-1][0:LIMIT],ect[0:ROWS-1][0:LIMIT];
  always @(posedge clk) begin
    if(!rst_n) begin
      ch=0;ctail=0;lh=0;ltail=0;cycle=0;next_tag=0;checked_c=0;checked_l=0;updates=0;
      for(integer r=0;r<ROWS;r++) for(integer t=0;t<=LIMIT;t++) begin
        ecv[r][t]=0;elv[r][t]=0;ecu[r][t]=0;elu[r][t]=0;
      end
    end else if(scoring) begin
      if(ce && cr) begin cq[ctail]=ci;ctail=ctail+1;end
      if(le && lr) begin lq[ltail]=li;ltail=ltail+1;end
      if(run) begin
        cycle=cycle+1;
        if(cl) begin
          if(!clr || ch>=ctail) $fatal(1,"legal compute launch unexpectedly blocked");
          for(integer r=0;r<ROWS;r++) begin
            ecu[r][cycle+3*r]=1;
            for(integer t=0;t<int'(cq[ch][18:3]);t++) begin
              ecv[r][cycle+3*r+t]=1;ecp[r][cycle+3*r+t]=cq[ch];
              ecx[r][cycle+3*r+t]=t;ect[r][cycle+3*r+t]=next_tag+t;
            end
          end
          next_tag=next_tag+int'(cq[ch][18:3]);ch=ch+1;
        end
        if(ll) begin
          integer duration;
          if(!llr || lh>=ltail) $fatal(1,"legal load launch unexpectedly blocked");
          duration=lq[lh][1:0]==0?32:1;
          for(integer r=0;r<ROWS;r++) begin
            elu[r][cycle+3*r]=1;
            for(integer t=0;t<duration;t++) begin
              elv[r][cycle+3*r+t]=1;elp[r][cycle+3*r+t]=lq[lh];elx[r][cycle+3*r+t]=t;
            end
          end
          lh=lh+1;
        end
        #1;
        if(fault) $fatal(1,"legal control traffic fault");
        for(integer r=0;r<ROWS;r++) begin
          if(cv[r]!==ecv[r][cycle] || lv[r]!==elv[r][cycle] || cu[r]!==ecu[r][cycle] || lu[r]!==elu[r][cycle])
            $fatal(1,"wave/update mismatch row=%0d cycle=%0d",r,cycle);
          if(cv[r]) begin
            if(cp[r*64+:64]!==ecp[r][cycle] || cx[r*16+:16]!==16'(ecx[r][cycle]) || ct[r*16+:16]!==16'(ect[r][cycle]))
              $fatal(1,"compute command/count/tag mismatch row=%0d cycle=%0d",r,cycle);
            checked_c=checked_c+1;
          end
          if(lv[r]) begin
            if(lp[r*64+:64]!==elp[r][cycle] || lx[r*16+:16]!==16'(elx[r][cycle]))
              $fatal(1,"load command/count mismatch row=%0d cycle=%0d",r,cycle);
            checked_l=checked_l+1;
          end
          updates=updates+int'(cu[r])+int'(lu[r]);
        end
      end
    end
  end
  task automatic reset_control;
    begin
      @(negedge clk);rst_n=0;run=0;ce=0;le=0;cl=0;ll=0;
      #1;if(cv!==0 || lv!==0 || cu!==0 || lu!==0 || fault!==0) $fatal(1,"control reset failed");
      repeat(2) @(negedge clk);rst_n=1;
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Preload each queue independently while run is low.
    @(negedge clk);ce=1;ci=compute_word(32,0,0);le=1;li=load_word(-1);
    @(negedge clk);ce=0;le=0;
    if(QUEUE_DEPTH==1 && (cr || lr)) $fatal(1,"full queue did not backpressure enqueue");
    run=1;
    for(integer t=0;t<120;t++) begin
      @(negedge clk);ce=0;le=0;
      cl=t==0 || t==32 || t==72;
      ll=t==0 || t==32 || t==36 || t==41 || t==44;
      // Full depth-one queue supports pop+push on the same edge. Non-power-
      // of-two depth-three queues also wrap their pointers in this sequence.
      if(t==0) begin ce=1;ci=compute_word(40,1,64);le=1;li=load_word(7);end
      if(t==32) begin ce=1;ci=compute_word(32,0,128);le=1;li=load_word(12);end
      // Distinct four/five/three-edge spacings: upper rows still relay older
      // commands while the bottom accepts a new one. No top-row drain lock.
      if(t==36) begin le=1;li=load_word(13);end
      if(t==41) begin le=1;li=load_word(14);end
    end
    @(negedge clk);cl=0;ll=0;ce=0;le=0;
    if(checked_c!=ROWS*104 || checked_l!=ROWS*36 || updates!=ROWS*8)
      $fatal(1,"missing control beats compute=%0d load=%0d updates=%0d",checked_c,checked_l,updates);
    $display("MXM_CONTROL_LEGAL_PASS rows=%0d depth=%0d compute_beats=%0d load_beats=%0d",ROWS,QUEUE_DEPTH,checked_c,checked_l);
    scoring=0;
    reset_control();run=1;
    @(negedge clk);cl=1;ll=1;
    @(negedge clk);cl=0;ll=0;
    if(!fault || cv!==0 || lv!==0) $fatal(1,"empty launch not detected");
    reset_control();
    @(negedge clk);ce=1;ci=compute_word(31,0,0);le=1;li=load_word(0);li[63]=0;
    @(negedge clk);ce=0;le=0;run=1;cl=1;ll=1;
    @(negedge clk);cl=0;ll=0;
    repeat(12) @(negedge clk);
    if(!fault || cv!==0 || lv!==0) $fatal(1,"illegal count/version executed");
    reset_control();
    @(negedge clk);ce=1;ci=compute_word(32,0,0);le=1;li=load_word(0);
    @(negedge clk);ce=0;le=0;run=1;cl=1;ll=1;
    @(negedge clk);cl=0;ll=0;ce=1;ci=compute_word(32,1,64);le=1;li=load_word(1);
    @(negedge clk);ce=0;le=0;cl=1;ll=1;
    #1;if(clr || (ROWS>1 && llr)) $fatal(1,"early launch reported ready");
    @(negedge clk);cl=0;ll=0;
    if(!fault) $fatal(1,"early launch not detected");
    // Rejected launch must leave next compute command queued, not execute
    // it automatically after the first command ends.
    repeat(45) @(negedge clk);
    if(cv!==0 || !clr) $fatal(1,"rejected command lost or retried autonomously");
    cl=1;
    @(negedge clk);cl=0;
    if(cp[0+:64]!==compute_word(32,1,64)) $fatal(1,"early launch consumed queued command");
    reset_control();run=1;
    repeat(15) @(negedge clk);
    if(cv!==0 || lv!==0 || clr || llr) $fatal(1,"reset did not flush pending waves/queues");
    $display("MXM_CONTROL_FAULT_RESET_PASS rows=%0d depth=%0d",ROWS,QUEUE_DEPTH);$finish;
  end
  initial begin #100000;$fatal(1,"control timeout");end
endmodule
