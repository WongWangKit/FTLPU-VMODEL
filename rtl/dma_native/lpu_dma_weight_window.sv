// Combinational admission for ONE scheduler-certified LOAD slot. The grant
// is sampled only when the wave request and the native port both handshake;
// it does not gate AXI R or a wave in flight. Bounds are physical edges in
// one epoch, [first, limit); the write acknowledgement need not fit inside.
module lpu_dma_weight_window #(parameter T=4, F=52)(
 input logic valid_i, cancel_i,
 input logic [63:0] cycle_i,first_i,limit_i,epoch_i,desc_epoch_i,
 input logic hem_i, reserved_hem_i,
 input logic [6:0] bank_i,
 input logic [2*F-1:0] reserved_banks_i,
 input logic [2:0] lane_i,reserved_lane_i,
 input logic [4:0] stream_i,reserved_stream_i,
 output logic grant_o
);
 // West edge -> column 15 -> boundary (bank/8 + 1) -> short
 // native MEM pipeline. Last physical write relative to acceptance:
 // (17 - boundary) + T - 1 = 15 + T - bank/8.
 wire [5:0] last_offset = 6'(15+T)-6'(bank_i[6:3]);
 assign grant_o=valid_i && !cancel_i && desc_epoch_i==epoch_i &&
   hem_i==reserved_hem_i && lane_i==reserved_lane_i && stream_i==reserved_stream_i && bank_i<2*F &&
   reserved_banks_i[bank_i] && first_i<=cycle_i && cycle_i<limit_i &&
   (limit_i-cycle_i)>last_offset;
 initial if((T!=2 && T!=4) || F<4 || F>52 || F%4!=0)$fatal(1,"weight window geometry");
endmodule
