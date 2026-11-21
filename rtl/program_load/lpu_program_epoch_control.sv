// Single physical iMEM slot. Re-arm cannot revoke AXI or erase live FU/SR
// work. Host may queue a request early; ACK means descriptor/iMEM metadata
// can now be reused. Each segment has an independently rebased schedule.
module lpu_program_epoch_control (
  input logic clk_i, rst_ni,
  input logic reload_valid_i,
  output logic reload_ready_o,
  output logic reload_ack_o,
  input logic load_fire_i, start_fire_i,
  input logic load_complete_i, segment_done_i, fault_i,
  input logic axi_idle_i, execution_drained_i,
  output logic admit_o, cancel_transport_o
);
  logic reload_pending_q, load_active_q, executed_q, cancel_q, reload_ack_q;
  logic clear_epoch_w;
  assign reload_ready_o = !reload_pending_q && !reload_ack_q;
  assign admit_o = rst_ni && !reload_pending_q && !reload_ack_q && !reload_valid_i && !cancel_q;
  assign clear_epoch_w = reload_pending_q && axi_idle_i && execution_drained_i &&
      (executed_q ? (segment_done_i && !fault_i) : (!load_active_q || load_complete_i || cancel_q));
  // Registered fault feedback avoids depending combinationally on the DMA
  // response it is cancelling. It only drops private responses; AR/R drain.
  assign cancel_transport_o = cancel_q;
  assign reload_ack_o = reload_ack_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reload_pending_q <= 1'b0;
      load_active_q <= 1'b0;
      executed_q <= 1'b0;
      cancel_q <= 1'b0;
      reload_ack_q <= 1'b0;
    end else begin
      reload_ack_q <= clear_epoch_w;
      if (load_fire_i) load_active_q <= 1'b1;
      if (start_fire_i) executed_q <= 1'b1;
      if (fault_i && !reload_ack_q) cancel_q <= 1'b1;
      if (reload_ready_o && reload_valid_i) reload_pending_q <= 1'b1;
      if (clear_epoch_w) begin
        reload_pending_q <= 1'b0;
        load_active_q <= 1'b0;
        executed_q <= 1'b0;
        cancel_q <= 1'b0;
      end
    end
  end
endmodule
