// Shared fixed-latency Supercell arithmetic helpers. No real/shortreal math.
package lpu_mxm_supercell_math_pkg;
  localparam logic [31:0] FP32_QNAN = 32'h7fc00000;

  function automatic logic [63:0] shift_right_sticky64(
    input logic [63:0] value, input integer distance
  );
    logic [63:0] shifted;
    logic sticky;
    begin
      shifted = distance >= 64 ? 64'b0 : value >> distance;
      sticky = 1'b0;
      for (integer bit_index = 0; bit_index < 64; bit_index++)
        if (bit_index < distance) sticky = sticky | value[bit_index];
      shifted[0] = shifted[0] | sticky;
      shift_right_sticky64 = shifted;
    end
  endfunction

  // magnitude[63] is the leading one; exponent is its unbiased exponent.
  // Preserve FP32 gradual underflow. BF16 input DAZ is a separate policy.
  // RNE is applied to the supplied finite-precision value, not to any bits
  // previously discarded by the dot-product alignment window.
  function automatic logic [31:0] pack_fp32_rne(
    input logic sign, input integer exponent, input logic [63:0] magnitude
  );
    logic [63:0] adjusted;
    logic [24:0] rounded;
    integer working_exponent;
    logic [7:0] encoded_exponent;
    begin
      adjusted = magnitude;
      working_exponent = exponent;
      if (working_exponent < -126) begin
        adjusted = shift_right_sticky64(adjusted, -126-working_exponent);
        working_exponent = -126;
      end
      rounded = {1'b0, adjusted[63:40]};
      if (adjusted[39] && ((|adjusted[38:0]) || rounded[0]))
        rounded = rounded + 1'b1;
      if (rounded[24]) begin
        rounded = rounded >> 1;
        working_exponent = working_exponent + 1;
      end
      encoded_exponent = 8'(working_exponent + 127);
      if (working_exponent == -126 && !rounded[23]) encoded_exponent = 0;
      if (magnitude == 0 || rounded == 0)
        pack_fp32_rne = {sign, 31'b0};
      else if (working_exponent > 127)
        pack_fp32_rne = {sign, 8'hff, 23'b0};
      else
        pack_fp32_rne = {sign, encoded_exponent, rounded[22:0]};
    end
  endfunction

  function automatic integer csa_count_after(input integer count, input integer levels);
    integer active_count;
    begin
      active_count = count;
      for (integer level = 0; level < levels; level++)
        if (active_count > 2)
          active_count = (active_count/3)*2 + active_count%3;
      csa_count_after = active_count;
    end
  endfunction

  function automatic integer csa_levels(input integer count);
    integer active_count, levels;
    begin
      active_count = count;
      levels = 0;
      // Positive supported counts shrink in fewer than 64 iterations.
      for (integer step = 0; step < 64; step++)
        if (active_count > 2) begin
          active_count = (active_count/3)*2 + active_count%3;
          levels = levels + 1;
        end
      csa_levels = levels;
    end
  endfunction
endpackage
