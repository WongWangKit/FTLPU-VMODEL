`timescale 1ns/1ps
// Four horizontal cells, observed exclusively through public module ports.
module lpu_mxm_supercell_chain_tb;
  localparam integer CELLS=4, TERMS=8, OUTPUTS=8, LIMIT=400;
  logic clk=0,rst_n=0,input_valid=0,input_buffer=0,load_valid=0,load_buffer=0;
  logic [15:0] input_tag=0;
  always #5 clk=~clk;
  wire [CELLS:0] activation_valid,activation_buffer,write_valid,write_buffer;
  wire [TERMS*16-1:0] activation[0:CELLS],write_data[0:CELLS];
  wire [15:0] activation_tag[0:CELLS];
  wire [OUTPUTS-1:0] dot_valid[0:CELLS-1],partial_valid[0:CELLS-1];
  wire [OUTPUTS*32-1:0] dot_data[0:CELLS-1],partial_data[0:CELLS-1];
  wire [OUTPUTS*16-1:0] dot_tag[0:CELLS-1],partial_tag[0:CELLS-1];
  wire [CELLS-1:0] fault;
  wire [2*CELLS-1:0] ready;
  bit history_valid[0:LIMIT];
  logic [15:0] history_tag[0:LIMIT];
  bit history_buffer[0:LIMIT];
  integer cycle=0,sent=0,forwards=0,dots=0,partials=0;

  function automatic logic [31:0] fp32_integer(input integer value);
    integer leading;
    logic [31:0] fraction;
    begin
      leading=0;
      for(integer b=0;b<31;b++) if((value>>b)&1) leading=b;
      fraction=32'(value)<<(23-leading);
      fp32_integer=value==0?32'b0:{1'b0,8'(leading+127),fraction[22:0]};
    end
  endfunction
  function automatic logic [TERMS*16-1:0] vector_for(input logic [15:0] tag_value);
    logic [31:0] value;
    begin
      value=fp32_integer(int'(tag_value)%5+1);
      vector_for={TERMS{value[31:16]}};
    end
  endfunction
  assign activation_valid[0]=input_valid;
  assign activation_buffer[0]=input_buffer;
  assign activation[0]=vector_for(input_tag);
  assign activation_tag[0]=input_tag;
  assign write_valid[0]=load_valid;
  assign write_buffer[0]=load_buffer;
  assign write_data[0]={TERMS{load_buffer?16'h4000:16'h3f80}};

  for(genvar c=0;c<CELLS;c++) begin : g_cell
    lpu_mxm_supercell #(.TERMS(TERMS),.OUTPUTS(OUTPUTS),.BOTTOM(1),.LAST_COLUMN(c==CELLS-1)) dut (
      .clk_i(clk),.rst_ni(rst_n),
      .activation_valid_i(activation_valid[c]),.activation_i(activation[c]),
      .weight_buffer_i(activation_buffer[c]),.tag_i(activation_tag[c]),
      .activation_valid_o(activation_valid[c+1]),.activation_o(activation[c+1]),
      .weight_buffer_o(activation_buffer[c+1]),.activation_tag_o(activation_tag[c+1]),
    .weight_write_valid_i(write_valid[c]),.weight_write_buffer_i(write_buffer[c]),
      .weight_write_data_i(write_data[c]),.weight_write_accepted_o(),
      .weight_forward_valid_o(write_valid[c+1]),.weight_forward_buffer_o(write_buffer[c+1]),
      .weight_forward_data_o(write_data[c+1]),.weight_buffer_ready_o(ready[2*c+:2]),.weight_buffer_busy_o(),
      .below_valid_i('0),.below_partial_i('0),.below_tag_i('0),
      .dot_valid_o(dot_valid[c]),.dot_result_o(dot_data[c]),.dot_tag_o(dot_tag[c]),.alignment_lost_o(),
      .partial_valid_o(partial_valid[c]),.partial_o(partial_data[c]),.partial_tag_o(partial_tag[c]),.fault_o(fault[c])
    );
  end

  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;
      for(integer t=0;t<=LIMIT;t++) history_valid[t]=0;
    end else begin
      cycle=cycle+1;
      if(cycle>LIMIT) $fatal(1,"chain scoreboard overflow");
      history_valid[cycle]=input_valid;
      history_tag[cycle]=input_tag;
      history_buffer[cycle]=input_buffer;
      if(input_valid) sent=sent+1;
      #1;
      if(|fault || write_valid[CELLS]) $fatal(1,"chain fault or terminal weight forwarding");
      for(integer c=0;c<CELLS;c++) begin
        integer source;
        source=cycle-c;
        if(activation_valid[c+1] !== (source>=1 ? history_valid[source] : 1'b0))
          $fatal(1,"activation must advance exactly one cell per edge cell=%0d",c);
        if(activation_valid[c+1]) begin
          if(activation_tag[c+1]!==history_tag[source] ||
             activation_buffer[c+1]!==history_buffer[source] || activation[c+1]!==vector_for(history_tag[source]))
            $fatal(1,"activation payload/control corruption cell=%0d",c);
          forwards=forwards+1;
        end
        source=cycle-c-8;
        if(dot_valid[c] !== {OUTPUTS{source>=1 ? history_valid[source] : 1'b0}})
          $fatal(1,"nonrectangular/wrong-phase dot valid cell=%0d cycle=%0d",c,cycle);
        if(|dot_valid[c]) begin
          for(integer g=0;g<OUTPUTS;g++)
            if(dot_tag[c][g*16+:16]!==history_tag[source] ||
               dot_data[c][g*32+:32]!==fp32_integer(TERMS*(int'(history_tag[source])%5+1)*(history_buffer[source]?2:1)))
              $fatal(1,"chain dot mismatch cell=%0d group=%0d",c,g);
          dots=dots+1;
        end
        source=cycle-c-11;
        if(partial_valid[c] !== {OUTPUTS{source>=1 ? history_valid[source] : 1'b0}})
          $fatal(1,"nonrectangular/wrong-phase partial valid cell=%0d cycle=%0d",c,cycle);
        if(|partial_valid[c]) begin
          for(integer g=0;g<OUTPUTS;g++)
            if(partial_tag[c][g*16+:16]!==history_tag[source] ||
               partial_data[c][g*32+:32]!==fp32_integer(TERMS*(int'(history_tag[source])%5+1)*(history_buffer[source]?2:1)))
              $fatal(1,"chain partial mismatch cell=%0d group=%0d",c,g);
          partials=partials+1;
        end
      end
    end
  end

  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Interleaved private weight chains with bubbles, filling all four cells.
    for(integer step=0;step<CELLS*OUTPUTS;step++) begin
      for(integer bank=0;bank<2;bank++) begin
        @(negedge clk);load_valid=1;load_buffer=1'(bank);
        if(step%7==3) begin
          @(negedge clk);load_valid=0;
          @(negedge clk);load_valid=1;
        end
      end
    end
    @(negedge clk);load_valid=0;
    repeat(CELLS-1) @(negedge clk);
    if(ready!=={2*CELLS{1'b1}}) $fatal(1,"four-cell weights did not fill");
    for(integer t=0;t<64;t++) begin
      @(negedge clk);input_valid=t%11!=3;input_tag=16'(t);input_buffer=1'(t%2);
    end
    @(negedge clk);input_valid=0;
    repeat(20) @(negedge clk);
    if(forwards!=sent*CELLS || dots!=sent*CELLS || partials!=sent*CELLS)
      $fatal(1,"missing chain vectors sent=%0d forward=%0d dot=%0d partial=%0d",sent,forwards,dots,partials);
    $display("MXM_SUPERCELL_CHAIN_PASS cells=%0d vectors=%0d forwards=%0d dot_vectors=%0d partial_vectors=%0d",CELLS,sent,forwards,dots,partials);
    $finish;
  end
  initial begin #100000;$fatal(1,"chain timeout");end
endmodule
