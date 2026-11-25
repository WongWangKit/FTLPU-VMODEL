`timescale 1ns/1ps
// Geometry and bridge routing only. No program, START or forced internal nets.
module top_profile_tb;
  import lpu_pkg::*;
  localparam T=2, N=2*T*32;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [N-1:0] ev='0;
  logic [N*64-1:0] ed='0;
  lpu_top #(.T(T),.ACTIVE_MEM_COLUMNS(4),.MEM_DEPTH_ROWS(32),
            .PROGRAM_MEM_IMEM_DEPTH(16),.PROGRAM_MXM_IMEM_DEPTH(16)) dut
    (.clk_i(clk),.rst_ni(rst_n),.program_reset_i(1'b0),
     .mem_east_edge_valid_i(ev),.mem_east_edge_data_i(ed),
     .mem_west_edge_valid_i('0),.mem_west_edge_data_i('0));
  `define CL dut.u_fu_subsystems
  `define H1 `CL.gen_hemisphere[1]
  initial begin
    if (vector_bytes_for_tiles(20)!=320 || lanes_for_tiles(20)!=16 ||
        2*mem_slices_per_side_for_tiles(20)*GROQ_BANKS_PER_SLICE*
        bank_rows_for_tiles(20)*vector_bytes_for_tiles(20)!=220*1024*1024)
      $fatal(1,"paper geometry");
    if (dut.DMA_VECTOR_BYTES!=16 || $bits(dut.m_axi_rdata_i)!=128 ||
        $bits(dut.mem_east_edge_data_i)!=N*64 || dut.PROGRAM_MXMS_PER_HEMISPHERE!=1 ||
        `CL.gen_vxm_execution.u_vxm_subsystem.u_execution.u_control.TILES!=T ||
        `H1.gen_sxm_execution.u_sxm_subsystem.u_execution.T!=T ||
        `H1.gen_mxm[0].g_native.u_execution.u_core.ROWS!=T ||
        `H1.u_mem_subsystem.T!=T) $fatal(1,"top-to-FU geometry");
    repeat(3) @(negedge clk);
    rst_n=1;
    // Use the final stream of the final tile in BOTH hemispheres. This catches
    // a stale four-tile hemisphere stride even if both port declarations fit.
    for(int h=0;h<2;h++) begin
      ev[(h+1)*T*32-1]=1;
      ed[((h+1)*T*32-1)*64+:64]=64'habc000+h;
    end
    #1;
    if (`CL.vxm_to_mem_east_valid !== ev ||
        `CL.gen_hemisphere[0].u_mem_subsystem.east_edge_data_i[(T*32-1)*64+:64] !== 64'habc000 ||
        `H1.u_mem_subsystem.east_edge_data_i[(T*32-1)*64+:64] !== 64'habc001)
      $fatal(1,"hemisphere routing");
    $display("PASS T=2 native dimensions, both last-tile SRF inputs, T=20 paper capacity");
    $finish;
  end
  `undef H1
  `undef CL
endmodule
