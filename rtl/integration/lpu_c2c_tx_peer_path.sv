`timescale 1ns/1ps

// Stateless connection wrapper. Input tile t is [t*64 +: 64]; stream
// selection is external. Gather completion and the peer boundary are payload-only.
module lpu_c2c_tx_peer_path #(
  parameter integer FIFO_DEPTH = 2,
  parameter integer LINK_LATENCY = 1
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [255:0] tile_data_i,
  input  logic [3:0] tile_valid_i,
  output logic [3:0] tile_consume_o,
  output logic peer_rx_valid_o,
  output logic [255:0] peer_rx_payload_o
);
  logic gather_completed_valid;
  logic [255:0] gather_completed_payload;
  logic fifo_deq_valid, fifo_deq_pop;
  logic [255:0] fifo_deq_payload;
  logic fifo_full, fifo_empty, fifo_can_enqueue;
  logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_count;

  c2c_tx_gather #(.SEGMENT_BITS(64)) u_gather (
    .clk_i, .rst_ni, .tile_data_i, .tile_valid_i,
    .tile_consume_o,
    .completed_valid_o(gather_completed_valid),
    .completed_payload_o(gather_completed_payload)
  );

  c2c_completed_fifo #(.DEPTH(FIFO_DEPTH)) u_fifo (
    .clk_i, .rst_ni,
    .enq_valid_i(gather_completed_valid),
    .enq_payload_i(gather_completed_payload),
    .deq_pop_i(fifo_deq_pop), .deq_valid_o(fifo_deq_valid),
    .deq_payload_o(fifo_deq_payload),
    .full_o(fifo_full), .empty_o(fifo_empty), .count_o(fifo_count)
  );

  // Readyless transport accepts a head every cycle. A full FIFO still has
  // enqueue capacity when a valid head is popped at the same edge.
  assign fifo_deq_pop = fifo_deq_valid;
  assign fifo_can_enqueue = !fifo_full || (fifo_deq_valid && fifo_deq_pop);

  c2c_peer_transport #(.LINK_LATENCY(LINK_LATENCY)) u_transport (
    .clk_i, .rst_ni,
    .tx_valid_i(fifo_deq_valid), .tx_payload_i(fifo_deq_payload),
    .rx_valid_o(peer_rx_valid_o), .rx_payload_o(peer_rx_payload_o)
  );

  // No gating of Gather and no hardware recovery. Legal schedules must not
  // overflow; report an illegal loss in simulation instead of hiding it.
`ifndef SYNTHESIS
  always @(posedge clk_i) begin
    if (rst_ni && gather_completed_valid && !fifo_can_enqueue)
      $fatal(1, "TEST_FAIL C2C completed FIFO enqueue capacity exceeded");
  end
`endif
endmodule
