// Finish the first two issue cycles before START. Small images can finish
// decoding at PRIME. Larger images may start with a full context window and
// continue decoding from resident iMEM, never writing an active iMEM.
module lpu_program_prime_window (
  input logic clk_i, rst_ni,
  input logic prime_i, decoder_drained_i,
  input logic context_fire_i,
  input logic [31:0] context_cycle_i,
  input logic scheduler_ready_i, scheduler_blocked_i, stream_prefix_i,
  output logic tail_o, ready_o, fault_o
);
  logic seen_context_q, unordered_q, stream_q, fault_q;
  logic [31:0] previous_cycle_q;
  logic inversion_w;
  assign inversion_w = context_fire_i && seen_context_q && context_cycle_i < previous_cycle_q;
  // Check the accepted context at the edge. Fault must not feed back
  // combinationally into the handshake that detects the same inversion.
  assign fault_o = fault_q;
  assign ready_o = prime_i && tail_o && !fault_o &&
    (stream_q ? (scheduler_ready_i || stream_prefix_i) : (decoder_drained_i && scheduler_ready_i));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      seen_context_q <= 1'b0;
      previous_cycle_q <= '0;
      unordered_q <= 1'b0;
      stream_q <= 1'b0;
      fault_q <= 1'b0;
      tail_o <= 1'b0;
    end else begin
      if (context_fire_i) begin
        seen_context_q <= 1'b1;
        previous_cycle_q <= context_cycle_i;
        unordered_q <= unordered_q || inversion_w;
      end
      if (stream_q && inversion_w) fault_q <= 1'b1;
      if (prime_i && !tail_o) begin
        if (decoder_drained_i && scheduler_ready_i) tail_o <= 1'b1;
        else if (scheduler_blocked_i) begin
          if (stream_prefix_i && !unordered_q && !inversion_w) begin
            tail_o <= 1'b1;
            stream_q <= 1'b1;
          end else fault_q <= 1'b1;
        end
      end
    end
  end
endmodule
