`timescale 1ns/1ps
module mxm_dot_tb;
  localparam COLS=32;
  reg format_bf16_i=0;
  reg [127:0] activation_bits_i=0;
  reg [COLS*128-1:0] weight_bits_i=0;
  wire [COLS*32-1:0] partial_values_o;
  reg [31:0] expected;
  integer checks=0,offset;
  lpu_mxm_dot_bank dut(.*);

  reg [31:0] rng=32'hb07d2026;
  function automatic [31:0] advance(input [31:0] x);
    reg [31:0] y;
    begin y=x^(x<<13);y=y^(y>>17);advance=y^(y<<5);end
  endfunction
  function automatic [31:0] decode_ref(input [15:0] x,input bit fmt);
    decode_ref=fmt?{x,16'b0}:fpga_reference_math_pkg::fp16_to_fp32(x);
  endfunction

  initial begin
    #200;
    for(integer fmt=0;fmt<2;fmt++) begin
      format_bf16_i=fmt;
      for(integer n=0;n<64;n++) begin
        for(integer k=0;k<8;k++) begin
          rng=advance(rng);activation_bits_i[k*16+:16]=rng[15:0];
          if(n==0) activation_bits_i[k*16+:16]=fmt?16'h3f80:16'h3c00;
          if(n==1) activation_bits_i[k*16+:16]=0;
          for(integer c=0;c<COLS;c++) begin
            offset=(COLS==1)?k*16:(((c/8)*8+k)*8+c%8)*16;
            rng=advance(rng);weight_bits_i[offset+:16]=rng[15:0];
            if(n<2) weight_bits_i[offset+:16]=fmt?16'h3f80:16'h3c00;
          end
        end
        #20;
        for(integer c=0;c<COLS;c++) begin
          expected=0;
          for(integer k=0;k<8;k++) begin
            offset=(COLS==1)?k*16:(((c/8)*8+k)*8+c%8)*16;
            expected=fpga_reference_math_pkg::fp32_add_rne(expected,
              fpga_reference_math_pkg::fp32_multiply_rne(
                decode_ref(activation_bits_i[k*16+:16],fmt),
                decode_ref(weight_bits_i[offset+:16],fmt)));
          end
          if(n==0 && expected!==32'h41000000) $fatal(1,"reference known 8*1");
          if(n==1 && expected!==0) $fatal(1,"reference known zero");
          if(partial_values_o[c*32+:32]!==expected) $fatal(1,"MXM dot mismatch fmt=%0d vector=%0d col=%0d actual=%h expected=%h",fmt,n,c,partial_values_o[c*32+:32],expected);
          checks++;
        end
      end
    end
    $display("PASS mxm_dot checks=%0d legacy_bit_equivalence_plus_known_vectors",checks);$finish;
  end
  initial begin #200000;$fatal(1,"timeout");end
endmodule
