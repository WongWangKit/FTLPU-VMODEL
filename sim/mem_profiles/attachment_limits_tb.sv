`timescale 1ns/1ps
// Exact profile-sized inputs. Unsupported attachment widths must be rejected,
// not elaborated as a truncated T4 endpoint. No forced state or fake payload.
module mem_profiles_attachment_limits_tb #(
  parameter integer PROFILE=16, KIND=0
);
  localparam integer T=lpu_native_config_pkg::tile_rows(PROFILE);
  logic clk=0;
  always #5 clk=~clk;
  if(KIND==0) begin:gen_dma
    lpu_mem_srf_dma_store_vector_sink #(.P_LPU_PROFILE(PROFILE)) dut(
      .clk_i(clk),.rst_ni(1'b0),
      .bank_issue_valid_i(104'b0),.bank_issue_i(3328'b0),
      .boundary_valid_i({64*T{1'b0}}),.boundary_data_i({4096*T{1'b0}}),
      .dma_store_issue_valid_i(1'b0),.dma_store_stream_index_i(3'b0),
      .vector_accept_i(1'b0));
  end else begin:gen_sxm
    lpu_mem_srf_sxm_turnaround_integration #(.P_LPU_PROFILE(PROFILE)) dut(
      .clk_i(clk),.rst_ni(1'b0),
      .vmodel_mem_issue_valid_i(104'b0),.vmodel_mem_issue_instruction_i(4888'b0),
      .vmodel_transpose_valid_i(1'b0),.vmodel_transpose_instruction_i(416'b0),
      .vmodel_permute_valid_i(1'b0),.vmodel_permute_instruction_i(416'b0),
      .boundary_valid_i({64*T{1'b0}}),.boundary_data_i({4096*T{1'b0}}));
  end
  initial begin
    #20;
    $fatal(1,"UNEXPECTED_UNSUPPORTED_ATTACHMENT_ACCEPTED");
  end
endmodule
