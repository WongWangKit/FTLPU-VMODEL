`timescale 1ns/1ps
module mem_profiles_geometry_tb #(
  parameter integer PROFILE=16, SLOTS=2, LEGACY_GROUP=4
);
  localparam integer T=PROFILE==0?4:lpu_native_config_pkg::tile_rows(PROFILE);
  localparam integer P=PROFILE==0?16:lpu_native_config_pkg::mem_depth_rows(PROFILE);
  localparam integer F=PROFILE==0?4:52;
  lpu_mem_srf_integration #(.MEM_SLICES(4),.MEM_SLICES_PER_GROUP(LEGACY_GROUP),
    .MEM_DEPTH_ROWS(16),.SUPERLANES(4),.P_LPU_PROFILE(PROFILE),.LOCAL_PRODUCERS(SLOTS)) dut(
    .clk_i(1'b0),.rst_ni(1'b0),.bank_issue_valid_i('0),.bank_issue_i('0),.boundary_valid_i('0),.boundary_data_i('0));
  initial begin
    #1;
    if(dut.T!=T || dut.P!=P || dut.E!=P || dut.F!=F || dut.G!=4 ||
       dut.u_mem.P_TILE_ROWS!=T || dut.u_mem.P_MEM_BANK_DEPTH_ROWS!=P ||
       $bits(dut.bank_issue_i)!=F*2*32 || $bits(dut.mem_producer_valid_o)!=F*2*T ||
       $bits(dut.mem_bank_fault_tile_id)!=F*2*((T>1)?$clog2(T):1))
      $fatal(1,"profile did not control effective geometry");
    $display("MEM_PROFILE_GEOMETRY TEST_PASS profile=%0d T=%0d P=%0d F=%0d G=4",PROFILE,T,P,F);$finish;
  end
endmodule

module mem_profiles_bad_tile_tb;
  mem_bank_control_column #(.P_TILE_ROWS(3)) dut(.clk_i(1'b0),.rst_ni(1'b0),.south_cmd_valid_i(1'b0),.south_cmd_i('0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
