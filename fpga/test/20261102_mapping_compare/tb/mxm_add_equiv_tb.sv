`timescale 1ns/1ps
module mxm_add_equiv_tb;
  reg [31:0] rng=32'h49a12026,a,b,actual,expected;
  integer checks=0;
  function automatic [31:0] advance(input [31:0] x);
    reg [31:0] y;
    begin y=x^(x<<13);y=y^(y>>17);advance=y^(y<<5);end
  endfunction
  task automatic check_pair(input [31:0] x,y);
    begin
      actual=lpu_vxm_math_pkg::fp32_add_rne(x,y);
      expected=fpga_reference_math_pkg::fp32_add_rne(x,y);
      if(actual!==expected)
        $fatal(1,"adder mismatch a=%h b=%h actual=%h expected=%h",x,y,actual,expected);
      checks++;
    end
  endtask
  initial begin
    check_pair(32'h3f800000,32'h40000000);
    if(actual!==32'h40400000) $fatal(1,"known vector");
    // Every exponent and cancellation distance; includes original exceptional domains.
    for(integer e=0;e<256;e++) for(integer k=0;k<23;k++) begin
      a=(e<<23)|(1<<k);b=(e<<23)|32'h80000000;
      check_pair(a,b);check_pair(b,a);
      check_pair(a^32'h80000000,b^32'h80000000);
      check_pair(a,a^32'h80000000);
    end
    for(integer n=0;n<50000;n++) begin
      rng=advance(rng);a=rng;rng=advance(rng);b=rng;
      check_pair(a,b);
    end
    $display("PASS mxm_add_equiv checks=%0d all_exponents_cancellation_random",checks);$finish;
  end
endmodule
