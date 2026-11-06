`timescale 1ns/1ps
module mxm_compute_tb;
  reg clk_i=0,rst_ni=0,run_i=0,result_ready_i=1;
  always #5 clk_i=~clk_i;
  reg [3:0] compute_row_valid_i=0;
  reg [191:0] compute_row_instruction_i=0;
  reg [127:0] east_valid_i=0;
  reg [8191:0] east_data_i=0;
  reg [32767:0] weight_bits_i=0;
  reg [31:0] cell_valid_i=0;
  wire [127:0] east_consumed_o;
  wire result_valid_o,result_stream_destination_o,result_clear_o,result_block_mode_o,fault_o;
  wire [8191:0] result_values_o;
  wire [12:0] result_address_o;
  wire [5:0] result_stream_base_o;
`ifdef GATE
  lpu_mxm_compute dut(.*);
`else
  lpu_mxm_compute #(.ACCUMULATOR_BLOCK_COUNT(1)) dut(.*);
`endif
  reg [47:0] instruction;
  reg [15:0] value;
  reg [31:0] expected;
  reg [127:0] expected_consume;
  integer checks=0;
  task automatic clear_state;
    begin
      @(negedge clk_i);run_i=0;compute_row_valid_i=0;result_ready_i=1;
      @(posedge clk_i);#1;
      if(fault_o!==0) $fatal(1,"run=0 must clear fault");
      @(negedge clk_i);run_i=1;
    end
  endtask
  task automatic setup_values(input bit fmt,input bit buffer_id,input integer pattern);
    begin
      instruction=0;instruction[1:0]=1;instruction[2]=buffer_id;
      instruction[14:9]=4;instruction[43:28]=1;instruction[45]=fmt;
      for(integer t=0;t<4;t++) begin
        compute_row_instruction_i[t*48+:48]=instruction;
        value=fmt?16'h3f80:16'h3c00;
        for(integer k=0;k<8;k++) begin
          east_data_i[(t*32)*64+k*8+:8]=value[7:0];
          east_data_i[(t*32+1)*64+k*8+:8]=value[15:8];
        end
      end
      east_valid_i='1;cell_valid_i='1;
      for(integer b=0;b<2;b++) for(integer t=0;t<4;t++)
        for(integer block_id=0;block_id<4;block_id++) for(integer k=0;k<8;k++)
          for(integer c=0;c<8;c++) begin
            value=fmt?16'h3f80:16'h3c00;
            if(pattern==1 && c%2) value=16'h4000;
            if(pattern==2) value=fmt?16'hbf80:16'hbc00;
            weight_bits_i[((b*4+t)*4*64+block_id*64+k*8+c)*16+:16]=value;
          end
    end
  endtask
  initial begin
    #200;@(negedge clk_i);rst_ni=1;
    for(integer fmt=0;fmt<2;fmt++) for(integer b=0;b<2;b++)
      for(integer pattern=0;pattern<3;pattern++) begin
        clear_state();setup_values(fmt,b,pattern);
        for(integer t=0;t<4;t++) begin
          compute_row_valid_i=1<<t;#1;
          expected_consume=0;expected_consume[t*32+:2]=2'b11;
          if(east_consumed_o!==expected_consume || result_valid_o!==(t==3))
            $fatal(1,"compute handshake mismatch tile=%0d",t);
          if(t==3) begin
            if(result_address_o!==0 || result_stream_base_o!==4 || result_stream_destination_o!==0 ||
               result_clear_o!==1 || result_block_mode_o!==0) $fatal(1,"result metadata mismatch");
            for(integer c=0;c<32;c++) begin
              expected=(pattern==2)?32'hc2000000:
                       ((pattern==1 && c%2)?32'h42800000:32'h42000000);
              if(result_values_o[c*32+:32]!==expected)
                $fatal(1,"compute math mismatch fmt=%0d buffer=%0d pattern=%0d col=%0d actual=%h expected=%h",fmt,b,pattern,c,result_values_o[c*32+:32],expected);
              checks++;
            end
            if(result_values_o[8191:1024]!==0) $fatal(1,"disabled Block8 outputs not zero");
          end
          @(posedge clk_i);#1;if(fault_o!==0) $fatal(1,"unexpected compute fault");
          @(negedge clk_i);
        end
        compute_row_valid_i=0;
      end
    clear_state();setup_values(0,0,0);
    compute_row_valid_i=3;#1;
    if(east_consumed_o!==0 || result_valid_o!==0) $fatal(1,"overlap not rejected");
    @(posedge clk_i);#1;if(fault_o!==1) $fatal(1,"overlap fault missing");checks++;
    clear_state();setup_values(0,0,0);
    for(integer t=0;t<4;t++) begin
      compute_row_valid_i=1<<t;result_ready_i=(t!=3);#1;
      if(t==3 && (result_valid_o!==0 || east_consumed_o!==0)) $fatal(1,"backpressure fault not rejected");
      @(posedge clk_i);#1;
      if(fault_o!==(t==3)) $fatal(1,"backpressure fault mismatch");
      @(negedge clk_i);
    end
    checks++;
    clear_state();
    $display("PASS mxm_compute checks=%0d 12_directed_waves_overlap_backpressure",checks);$finish;
  end
  initial begin #200000;$fatal(1,"compute timeout");end
endmodule
