`timescale 1ns/1ps
// Queue/FIFO model and expected row phases use only public handshake ports.
module lpu_mxm_dequant_control_tb #(parameter integer ROWS=4,QUEUE_DEPTH=3);
  localparam integer LIMIT=600;
  logic clk=0,rst_n=0,run=0,pe=0,pl=0,de=0,dl=0,pi=0,di=0;
  wire per,plr,der,dlr,fault;
  wire [ROWS-1:0] pv,dv,pc,dc;
  integer count[0:1],head[0:1],tail[0:1];
  bit memory[0:1][0:QUEUE_DEPTH-1];
  bit expected_valid[0:1][0:ROWS-1][0:LIMIT];
  bit expected_word[0:1][0:ROWS-1][0:LIMIT];
  integer cycle=0,checked=0,replacements=0;
  bit expected_fault=0;
  always #5 clk=~clk;
  lpu_mxm_dequant_control #(.ROWS(ROWS),.QUEUE_DEPTH(QUEUE_DEPTH)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),
    .param_load_enqueue_valid_i(pe),.param_load_launch_i(pl),.param_load_instruction_i(pi),
    .param_load_enqueue_ready_o(per),.param_load_launch_ready_o(plr),
    .dequant_enqueue_valid_i(de),.dequant_launch_i(dl),.dequant_instruction_i(di),
    .dequant_enqueue_ready_o(der),.dequant_launch_ready_o(dlr),
    .param_load_row_valid_o(pv),.param_load_row_instruction_o(pc),
    .dequant_row_valid_o(dv),.dequant_row_instruction_o(dc),.fault_o(fault));
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;expected_fault=0;
      for(integer q=0;q<2;q++) begin
        count[q]=0;head[q]=0;tail[q]=0;
        for(integer r=0;r<ROWS;r++) for(integer t=0;t<=LIMIT;t++) expected_valid[q][r][t]=0;
      end
    end else begin
      cycle++;
      for(integer q=0;q<2;q++) begin
        bit launch,enq,word_value,ready_launch,ready_enq,pop,push;
        launch=q==0?pl:dl;enq=q==0?pe:de;word_value=q==0?pi:di;
        ready_launch=q==0?plr:dlr;ready_enq=q==0?per:der;
        pop=run && launch && count[q]>0;
        push=enq && (count[q]<QUEUE_DEPTH || pop);
        if(ready_launch!==(run && count[q]>0) || ready_enq!==(count[q]<QUEUE_DEPTH || pop))
          $fatal(1,"dequant FIFO handshake mismatch q=%0d cycle=%0d",q,cycle);
        if(!run) begin
          for(integer r=0;r<ROWS;r++) for(integer t=cycle;t<=LIMIT;t++) expected_valid[q][r][t]=0;
        end else begin
          if(launch && !ready_launch) expected_fault=1;
          if(pop) for(integer r=0;r<ROWS;r++) begin
            expected_valid[q][r][cycle+3*r]=1;
            expected_word[q][r][cycle+3*r]=memory[q][head[q]];
          end
        end
        if(pop && push && count[q]==QUEUE_DEPTH) replacements++;
        if(pop) head[q]=(head[q]+1)%QUEUE_DEPTH;
        if(push) begin memory[q][tail[q]]=word_value;tail[q]=(tail[q]+1)%QUEUE_DEPTH;end
        count[q]=count[q]+int'(push)-int'(pop);
      end
      if(!run) expected_fault=0;
      #1;
      if(fault!==expected_fault) $fatal(1,"dequant fault lifetime mismatch");
      for(integer q=0;q<2;q++) for(integer r=0;r<ROWS;r++) begin
        bit valid,word_value;
        valid=q==0?pv[r]:dv[r];word_value=q==0?pc[r]:dc[r];
        if(valid!==expected_valid[q][r][cycle]) $fatal(1,"dequant row valid phase mismatch q=%0d row=%0d cycle=%0d",q,r,cycle);
        if(valid) begin
          if(word_value!==expected_word[q][r][cycle]) $fatal(1,"dequant row buffer mismatch");
          checked++;
        end
      end
    end
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Fill both independent FIFOs while run is stopped.
    for(integer i=0;i<QUEUE_DEPTH;i++) begin @(negedge clk);pe=1;de=1;pi=1'(i);di=1'(~i);end
    @(negedge clk);pe=0;de=0;run=1;
    for(integer t=0;t<256;t++) begin
      @(negedge clk);pl=t%5!=2 && plr;dl=t%7!=3 && dlr;
      pe=t%11!=6;de=t%13!=7;pi=1'(t/5);di=1'(t/3);
    end
    for(integer t=0;t<QUEUE_DEPTH+12;t++) begin @(negedge clk);pe=0;de=0;pl=plr;dl=dlr;end
    @(negedge clk);pl=1;dl=1;
    @(negedge clk);pl=0;dl=0;if(!fault) $fatal(1,"empty launch not detected");run=0;pe=1;de=1;pi=1;di=0;
    @(negedge clk);pe=0;de=0;run=1;
    @(negedge clk);pl=1;dl=1;
    @(negedge clk);pl=0;dl=0;run=0;
    repeat(3) @(negedge clk);
    run=1;
    repeat(12) @(negedge clk);
    // Cancel an in-flight word and queued work by reset.
    pe=1;de=1;
    @(negedge clk);pe=0;de=0;
    @(negedge clk);pl=1;dl=1;
    @(negedge clk);rst_n=0;pl=0;dl=0;
    @(negedge clk);rst_n=1;
    repeat(12) @(negedge clk);
    if(checked<100*ROWS || replacements==0 || fault || pv || dv || plr || dlr) $fatal(1,"dequant control coverage missing");
    $display("MXM_DEQUANT_CONTROL_PASS rows=%0d depth=%0d checked=%0d full_replacements=%0d row_interval=3 count_free=1",ROWS,QUEUE_DEPTH,checked,replacements);
    $finish;
  end
  initial begin #20000;$fatal(1,"dequant control timeout");end
endmodule
