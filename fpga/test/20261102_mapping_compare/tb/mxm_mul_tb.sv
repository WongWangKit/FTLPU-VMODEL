`timescale 1ns/1ps
module mxm_mul_tb;
  reg format_bf16_i=0;
  reg [15:0] lhs_i=0,rhs_i=0;
  wire [31:0] product_o;
  reg [31:0] expected;
  integer checks=0;
  fpga_mxm_mul dut(.*);

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
      lhs_i=fmt?16'h3fc0:16'h3e00;rhs_i=16'h4000;#20;
      if(product_o!==32'h40400000) $fatal(1,"MXM known 1.5*2 vector");
      checks++;
      for(integer n=0;n<4096;n++) begin
        rng=advance(rng);lhs_i=rng[15:0];rng=advance(rng);rhs_i=rng[15:0];
        if(n<16) begin lhs_i=n;rhs_i=fmt?16'h3f80:16'h3c00;end
        expected=fpga_reference_math_pkg::fp32_multiply_rne(
          decode_ref(lhs_i,fmt),decode_ref(rhs_i,fmt));
        #20;
        if(product_o!==expected) $fatal(1,"MXM mul mismatch fmt=%0d lhs=%h rhs=%h actual=%h expected=%h",fmt,lhs_i,rhs_i,product_o,expected);
        checks++;
      end
    end
    $display("PASS mxm_mul checks=%0d legacy_bit_equivalence_plus_known_vectors",checks);$finish;
  end
  initial begin #200000;$fatal(1,"timeout");end
endmodule
