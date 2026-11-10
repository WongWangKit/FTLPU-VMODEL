`timescale 1ns/1ps
module lpu_mxm_supercell_tb;
  parameter integer TERMS=8;
  parameter integer OUTPUTS=8;
  localparam integer LIMIT=2000;
  logic clk=0,rst_n=0,input_valid=0,input_buffer=0;
  always #5 clk=~clk;
  logic [15:0] input_tag=0;
  wire [TERMS*16-1:0] input_activation;
  logic write_valid=0,write_buffer=0;
  integer write_step=0;
  wire weight_forward_valid,weight_forward_buffer;
  wire [TERMS*16-1:0] weight_forward_data;
  wire [1:0] terminal_forward_valid;
  wire [TERMS*16-1:0] bottom_weights,upper_weights;
  wire [2:0] write_accepted,fault;
  wire [5:0] ready,busy;
  wire right_input_valid,right_input_buffer;
  wire [TERMS*16-1:0] right_input_activation;
  wire [15:0] right_input_tag;
  logic [2:0] upper_wave=0,upper_buffer=0;
  logic [15:0] upper_tag[0:2];
  wire [TERMS*16-1:0] upper_activation;
  wire [3*OUTPUTS-1:0] partial_valid;
  wire [3*OUTPUTS*32-1:0] partial_data;
  wire [3*OUTPUTS*16-1:0] partial_tag;
  wire [OUTPUTS-1:0] bottom_dot_valid;
  wire [OUTPUTS*32-1:0] bottom_dot;
  wire [OUTPUTS*16-1:0] bottom_dot_tag;
  logic suppress_below=0;
  logic corrupt_below_tag=0;
  bit scoring=1;
  bit expected_valid[0:2][0:OUTPUTS-1][0:LIMIT];
  logic [31:0] expected_data[0:2][0:OUTPUTS-1][0:LIMIT];
  logic [15:0] expected_tag[0:2][0:OUTPUTS-1][0:LIMIT];
  bit expected_dot_valid[0:OUTPUTS-1][0:LIMIT];
  logic [31:0] expected_dot_data[0:OUTPUTS-1][0:LIMIT];
  logic [15:0] expected_dot_tag[0:OUTPUTS-1][0:LIMIT];
  bit expected_forward[0:LIMIT];
  logic [15:0] forward_tag[0:LIMIT];
  bit forward_buffer[0:LIMIT];
  integer cycle=0,sent=0,checked=0,forward_checked=0,dot_checked=0;
  // Independent interface-level queue model for weight forwarding. No DUT
  // hierarchy references: observe only accepted writes and forwarding ports.
  logic [TERMS*16-1:0] expected_weight[0:1][0:OUTPUTS-1];
  bit expected_weight_valid[0:1][0:OUTPUTS-1];
  bit forwarded_valid=0,forwarded_buffer=0;
  logic [TERMS*16-1:0] forwarded_data=0;

  always @(posedge clk) begin
    if(!rst_n) begin
      forwarded_valid=0;
      for(integer b=0;b<2;b++)
        for(integer g=0;g<OUTPUTS;g++) expected_weight_valid[b][g]=0;
    end else begin
      if(weight_forward_valid !== forwarded_valid)
        $fatal(1,"weight forwarding validity/shift count mismatch");
      if(weight_forward_valid &&
         (weight_forward_buffer!==forwarded_buffer || weight_forward_data!==forwarded_data))
        $fatal(1,"weight forwarding data/buffer ID mismatch");
      forwarded_valid=write_accepted[0] && expected_weight_valid[write_buffer][OUTPUTS-1];
      forwarded_buffer=write_buffer;forwarded_data=expected_weight[write_buffer][OUTPUTS-1];
      if(write_accepted[0]) begin
        for(integer g=OUTPUTS-1;g>0;g--) begin
          expected_weight[write_buffer][g]=expected_weight[write_buffer][g-1];
          expected_weight_valid[write_buffer][g]=expected_weight_valid[write_buffer][g-1];
        end
        expected_weight[write_buffer][0]=bottom_weights;
        expected_weight_valid[write_buffer][0]=1;
      end
    end
  end

  function automatic logic [31:0] fp32_integer(input integer value);
    integer magnitude,leading;
    logic sign;
    logic [31:0] fraction;
    begin
      sign=value<0;magnitude=sign?-value:value;leading=0;
      for(integer b=0;b<31;b++) if((magnitude>>b)&1) leading=b;
      fraction=32'(magnitude)<<(23-leading);
      fp32_integer=value==0?32'b0:{sign,8'(leading+127),fraction[22:0]};
    end
  endfunction
  function automatic logic [TERMS*16-1:0] activations(input integer tag_value,input integer upper);
    logic [31:0] bits;
    begin
      for(integer k=0;k<TERMS;k++) begin
        bits=fp32_integer(tag_value%5+1+k%3+upper);
        activations[k*16 +:16]=bits[31:16];
      end
    end
  endfunction
  function automatic logic [TERMS*16-1:0] weights(input integer unit_id,input integer bank,input integer group_id);
    logic [31:0] bits;
    begin
      bits=fp32_integer((group_id+1)*(unit_id+1+bank));
      for(integer k=0;k<TERMS;k++) weights[k*16 +:16]=bits[31:16];
    end
  endfunction
  function automatic integer dot_integer(input integer tag_value,input integer bank,input integer group_id,input integer unit_id);
    integer total;
    begin
      total=0;
      for(integer k=0;k<TERMS;k++) total=total+tag_value%5+1+k%3+(unit_id==1?1:0);
      dot_integer=total*(group_id+1)*(unit_id+1+bank);
    end
  endfunction
  assign input_activation=activations(int'(input_tag),0);
  assign upper_activation=activations(int'(upper_tag[2]),1);
  // Rightmost cell's weights first; within each cell, group N-1 first.
  assign bottom_weights=weights(write_step<OUTPUTS?2:0,int'(write_buffer),OUTPUTS-1-write_step%OUTPUTS);
  assign upper_weights=weights(1,int'(write_buffer),OUTPUTS-1-write_step%OUTPUTS);

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      upper_wave<=0;upper_buffer<=0;
      for(integer i=0;i<3;i++) upper_tag[i]<=0;
    end else begin
      upper_wave<={upper_wave[1:0],input_valid};
      upper_buffer<={upper_buffer[1:0],input_buffer};
      upper_tag[0]<=input_tag;upper_tag[1]<=upper_tag[0];upper_tag[2]<=upper_tag[1];
    end
  end

  lpu_mxm_supercell #(.TERMS(TERMS),.OUTPUTS(OUTPUTS),.BOTTOM(1)) bottom (
    .clk_i(clk),.rst_ni(rst_n),.activation_valid_i(input_valid),.activation_i(input_activation),
    .weight_buffer_i(input_buffer),.tag_i(input_tag),
    .weight_write_valid_i(write_valid),.weight_write_buffer_i(write_buffer),
    .weight_write_data_i(bottom_weights),
    .weight_forward_valid_o(weight_forward_valid),.weight_forward_buffer_o(weight_forward_buffer),
    .weight_forward_data_o(weight_forward_data),
    .weight_write_accepted_o(write_accepted[0]),.weight_buffer_ready_o(ready[1:0]),.weight_buffer_busy_o(busy[1:0]),
    .activation_valid_o(right_input_valid),.activation_o(right_input_activation),
    .weight_buffer_o(right_input_buffer),.activation_tag_o(right_input_tag),
    .below_valid_i('0),.below_partial_i('0),.below_tag_i('0),
    .dot_valid_o(bottom_dot_valid),.dot_result_o(bottom_dot),.dot_tag_o(bottom_dot_tag),.alignment_lost_o(),
    .partial_valid_o(partial_valid[0+:OUTPUTS]),.partial_o(partial_data[0+:OUTPUTS*32]),
    .partial_tag_o(partial_tag[0+:OUTPUTS*16]),.fault_o(fault[0])
  );
  lpu_mxm_supercell #(.TERMS(TERMS),.OUTPUTS(OUTPUTS),.BOTTOM(0),.LAST_COLUMN(1)) upper (
    .clk_i(clk),.rst_ni(rst_n),.activation_valid_i(upper_wave[2]),.activation_i(upper_activation),
    .weight_buffer_i(upper_buffer[2]),.tag_i(upper_tag[2]),
    .weight_write_valid_i(write_valid),.weight_write_buffer_i(write_buffer),
    .weight_write_data_i(upper_weights),
    .weight_forward_valid_o(terminal_forward_valid[0]),.weight_forward_buffer_o(),.weight_forward_data_o(),
    .weight_write_accepted_o(write_accepted[1]),.weight_buffer_ready_o(ready[3:2]),.weight_buffer_busy_o(busy[3:2]),
    .activation_valid_o(),.activation_o(),.weight_buffer_o(),.activation_tag_o(),
    .below_valid_i(suppress_below?'0:partial_valid[0+:OUTPUTS]),
    .below_partial_i(partial_data[0+:OUTPUTS*32]),
    .below_tag_i(partial_tag[0+:OUTPUTS*16] ^ {OUTPUTS*16{corrupt_below_tag}}),
    .dot_valid_o(),.dot_result_o(),.dot_tag_o(),.alignment_lost_o(),
    .partial_valid_o(partial_valid[OUTPUTS+:OUTPUTS]),.partial_o(partial_data[OUTPUTS*32+:OUTPUTS*32]),
    .partial_tag_o(partial_tag[OUTPUTS*16+:OUTPUTS*16]),.fault_o(fault[1])
  );
  lpu_mxm_supercell #(.TERMS(TERMS),.OUTPUTS(OUTPUTS),.BOTTOM(1),.LAST_COLUMN(1)) right_cell (
    .clk_i(clk),.rst_ni(rst_n),.activation_valid_i(right_input_valid),.activation_i(right_input_activation),
    .weight_buffer_i(right_input_buffer),.tag_i(right_input_tag),
    .weight_write_valid_i(weight_forward_valid),.weight_write_buffer_i(weight_forward_buffer),
    .weight_write_data_i(weight_forward_data),
    .weight_forward_valid_o(terminal_forward_valid[1]),.weight_forward_buffer_o(),.weight_forward_data_o(),
    .weight_write_accepted_o(write_accepted[2]),.weight_buffer_ready_o(ready[5:4]),.weight_buffer_busy_o(busy[5:4]),
    .activation_valid_o(),.activation_o(),.weight_buffer_o(),.activation_tag_o(),
    .below_valid_i('0),.below_partial_i('0),.below_tag_i('0),
    .dot_valid_o(),.dot_result_o(),.dot_tag_o(),.alignment_lost_o(),
    .partial_valid_o(partial_valid[2*OUTPUTS+:OUTPUTS]),.partial_o(partial_data[2*OUTPUTS*32+:OUTPUTS*32]),
    .partial_tag_o(partial_tag[2*OUTPUTS*16+:OUTPUTS*16]),.fault_o(fault[2])
  );

  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;
      for(integer c=0;c<=LIMIT;c++) begin
        expected_forward[c]=0;
        for(integer g=0;g<OUTPUTS;g++) begin
          expected_dot_valid[g][c]=0;
          for(integer u=0;u<3;u++) expected_valid[u][g][c]=0;
        end
      end
    end else if(scoring) begin
      cycle=cycle+1;
      if(input_valid) begin
        sent=sent+1;
        expected_forward[cycle]=1;
        forward_tag[cycle]=input_tag;
        forward_buffer[cycle]=input_buffer;
        for(integer g=0;g<OUTPUTS;g++) begin
          integer due,bottom_value,upper_value,right_value;
          bottom_value=dot_integer(int'(input_tag),int'(input_buffer),g,0);
          upper_value=dot_integer(int'(input_tag),int'(input_buffer),g,1);
          right_value=dot_integer(int'(input_tag),int'(input_buffer),g,2);
          expected_dot_valid[g][cycle+8]=1;
          expected_dot_data[g][cycle+8]=fp32_integer(bottom_value);
          expected_dot_tag[g][cycle+8]=input_tag;
          for(integer u=0;u<3;u++) begin
            due=cycle+11+(u==1?3:(u==2?1:0));
            expected_valid[u][g][due]=1;
            expected_tag[u][g][due]=input_tag;
            expected_data[u][g][due]=fp32_integer(u==0?bottom_value:(u==1?bottom_value+upper_value:right_value));
          end
        end
      end
      #1;
      if(|fault) $fatal(1,"legal Supercell traffic fault=%b cycle=%0d",fault,cycle);
      if(right_input_valid!==expected_forward[cycle]) $fatal(1,"activation forwarding latency mismatch");
      if(right_input_valid) begin
        if(right_input_tag!==forward_tag[cycle] || right_input_buffer!==forward_buffer[cycle] ||
           right_input_activation!==activations(int'(forward_tag[cycle]),0))
          $fatal(1,"activation data/control changed while moving right");
        forward_checked=forward_checked+1;
      end
      for(integer g=0;g<OUTPUTS;g++) begin
        if(bottom_dot_valid[g]!==expected_dot_valid[g][cycle]) $fatal(1,"broadcast dot phase mismatch group=%0d",g);
        if(bottom_dot_valid[g]) begin
          if(bottom_dot[g*32+:32]!==expected_dot_data[g][cycle] || bottom_dot_tag[g*16+:16]!==expected_dot_tag[g][cycle])
            $fatal(1,"Supercell local dot mismatch group=%0d",g);
          dot_checked=dot_checked+1;
        end
        for(integer u=0;u<3;u++) begin
          if(partial_valid[u*OUTPUTS+g]!==expected_valid[u][g][cycle])
            $fatal(1,"broadcast partial phase/latency mismatch unit=%0d group=%0d cycle=%0d",u,g,cycle);
          if(partial_valid[u*OUTPUTS+g]) begin
            if(partial_data[(u*OUTPUTS+g)*32+:32]!==expected_data[u][g][cycle] ||
               partial_tag[(u*OUTPUTS+g)*16+:16]!==expected_tag[u][g][cycle])
              $fatal(1,"partial mismatch unit=%0d group=%0d tag=%0d",u,g,expected_tag[u][g][cycle]);
            checked=checked+1;
          end
        end
      end
    end
  end

  task automatic reset_cells;
    begin
      @(negedge clk);rst_n=0;input_valid=0;write_valid=0;suppress_below=0;corrupt_below_tag=0;
      #1;
      if(partial_valid!=='0 || bottom_dot_valid!=='0 || right_input_valid!==0 || ready!=='0 || fault!=='0)
        $fatal(1,"Supercell state survived reset");
      repeat(2) @(negedge clk);rst_n=1;
    end
  endtask
  task automatic reload_interleaved;
    begin
      for(integer step=0;step<2*OUTPUTS;step++) begin
        for(integer b=0;b<2;b++) begin
          @(negedge clk);
          if((step+b)%4==1) begin
            write_valid=0;write_buffer=1'(1-b);
            @(negedge clk);
          end
          write_valid=1;write_buffer=1'(b);write_step=step;
          #1;if(write_accepted[1:0]!==2'b11 || (weight_forward_valid && !write_accepted[2]))
            $fatal(1,"interleaved shift load rejected");
        end
      end
      @(negedge clk);write_valid=0;
      @(negedge clk); // Drain the registered weight link to the right cell.
    end
  endtask
  task automatic load_bank_zero;
    begin
      for(integer g=0;g<2*OUTPUTS;g++) begin
        @(negedge clk);write_valid=1;write_buffer=0;write_step=g;
        if(g==OUTPUTS) begin
          #1;if(ready!==6'b000101) $fatal(1,"one-cell fill was not exactly N accepted shifts");
        end
        #1;if(write_accepted[1:0]!==2'b11 || (weight_forward_valid && !write_accepted[2])) $fatal(1,"idle bank load rejected");
      end
      @(negedge clk);write_valid=0;
      @(negedge clk);
    end
  endtask

  always @(negedge clk)
    if(rst_n && (|terminal_forward_valid)) $fatal(1,"last cell forwarded weights");

  always @(negedge clk)
    if(rst_n && (suppress_below || corrupt_below_tag) &&
       (|partial_valid[OUTPUTS+:OUTPUTS]))
      $fatal(1,"misaligned lower partial produced an upper result");

  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    load_bank_zero();
    if(ready!==6'b010101) $fatal(1,"bank-zero readiness mismatch");
    // Interleaved buffer IDs and bubbles must advance only the selected
    // chain. Later arithmetic verifies both cells received their own weights.
    reload_interleaved();
    if(ready!==6'b111111) $fatal(1,"interleaved chain load did not fill both banks");
    // Load bank 1 during continuous bank-0 computation, then alternate banks
    // while previous vectors remain in the arithmetic pipeline.
    for(integer t=0;t<48;t++) begin
      @(negedge clk);
      input_valid=t%7!=2;input_tag=16'(t);
      input_buffer=t>2*OUTPUTS+2 ? 1'(t%2) : 1'b0;
      write_valid=t<2*OUTPUTS;write_buffer=1;write_step=t;
      #1;if(write_valid && (write_accepted[1:0]!==2'b11 || (weight_forward_valid && !write_accepted[2]))) $fatal(1,"overlapped inactive-bank load rejected");
    end
    @(negedge clk);input_valid=0;write_valid=0;
    repeat(OUTPUTS+24) @(negedge clk);
    if(checked!=sent*OUTPUTS*3 || dot_checked!=sent*OUTPUTS || forward_checked!=sent)
      $fatal(1,"Supercell missing results sent=%0d checked=%0d",sent,checked);
    if(ready!==6'b111111) $fatal(1,"both banks not ready");
    scoring=0;
    // A missing lower token is a schedule error, not a local stall/retry.
    @(negedge clk);input_valid=1;input_buffer=0;input_tag=100;suppress_below=1;
    @(negedge clk);input_valid=0;
    repeat(OUTPUTS+18) @(negedge clk);
    if(!fault[1]) $fatal(1,"missing lower partial was not detected");
    reset_cells();
    load_bank_zero();
    @(negedge clk);input_valid=1;input_buffer=0;input_tag=102;corrupt_below_tag=1;
    @(negedge clk);input_valid=0;
    repeat(OUTPUTS+18) @(negedge clk);
    if(!fault[1]) $fatal(1,"mismatched lower tag was not detected");
    reset_cells();
    load_bank_zero();
    // Updating a bank on its M1 capture edge is rejected.
    @(negedge clk);input_valid=1;input_buffer=0;input_tag=101;
    write_valid=1;write_buffer=0;write_step=0;
    #1;if(write_accepted[0]!==0) $fatal(1,"active-bank write accepted");
    @(negedge clk);input_valid=0;
    if(!fault[0]) $fatal(1,"active-bank write did not fault");
    // All groups captured their weights together; no OUTPUTS-edge ownership
    // remains. The outgoing neighbor still enforces its own capture edge.
    #1;if(write_accepted[0]!==1 || busy[1:0]!==0)
      $fatal(1,"captured weights unnecessarily kept local bank busy");
    @(negedge clk);
    write_valid=0;
    // Reset while arithmetic is still in flight.
    reset_cells();
    repeat(OUTPUTS+18) @(negedge clk);
    if(partial_valid!=='0) $fatal(1,"old token returned after reset");
    // Reset invalidates weights; arithmetic must not consume unknown data.
    @(negedge clk);input_valid=1;input_buffer=0;
    @(negedge clk);input_valid=0;
    if(!fault[0]) $fatal(1,"unconfigured weights did not fault");
    $display("MXM_SUPERCELL_K%0d_N%0d_PASS vectors=%0d partials=%0d",TERMS,OUTPUTS,sent,checked);$finish;
  end
  initial begin #300000;$fatal(1,"Supercell timeout");end
endmodule
