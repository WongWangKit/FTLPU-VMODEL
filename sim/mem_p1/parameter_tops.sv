`timescale 1ns/1ps

module mem_bad_physical_zero;
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(0)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_physical_nonpower;
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(63)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_physical_large;
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(65536)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_active_zero;
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_ACTIVE_ROWS(0)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_active_nonpower;
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_ACTIVE_ROWS(63)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_active_large;
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_ACTIVE_ROWS(128)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_latency;
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_READ_TO_SR_CYCLES(2)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_hop;
  mem_bank_control_column #(.P_MEM_CONTROL_HOP_CYCLES(2)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_bank_count;
  mem_slice #(.P_BANKS(3),.P_MEM_BANK_DEPTH_ROWS(64)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_group_count;
  mem_group #(.P_SLICES(3),.P_MEM_BANK_DEPTH_ROWS(64)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_hemisphere_count;
  mem_hemisphere #(.P_MEM_SLICES_PER_HEMI(2),.P_MEM_BANK_DEPTH_ROWS(64)) dut(.clk_i(1'b0),.rst_ni(1'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_c7_legacy_depth;
  mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(16)) dut(.issue_valid_i(1'b0),.issue_instruction_i(32'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
module mem_bad_c7_active;
  mem_c7_primitive_adapter #(.P_MEM_ACTIVE_ROWS(63)) dut(.issue_valid_i(1'b0),.issue_instruction_i(32'b0));
  initial begin #10;$fatal(1,"UNEXPECTED_PARAMETER_SUCCESS");end
endmodule
