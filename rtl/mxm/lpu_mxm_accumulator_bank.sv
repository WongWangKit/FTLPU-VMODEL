// Logical single-port bank. A request is SERVICED on its sampling edge E0;
// captured read data is published at E1. The output register does not occupy
// the SRAM port, so another read or write can be serviced on E1.
module lpu_mxm_accumulator_bank #(
  parameter integer WIDTH=256,DEPTH=512,
  localparam integer ADDRESS_BITS=DEPTH>1?$clog2(DEPTH):1
) (
  input logic clk_i,rst_ni,run_i,
  input logic request_valid_i,write_i,
  input logic [ADDRESS_BITS-1:0] address_i,
  input logic [WIDTH-1:0] write_data_i,
  output logic read_valid_o,
  output logic [WIDTH-1:0] read_data_o,
  output logic [ADDRESS_BITS-1:0] read_address_o,
  output wire invalid_read_o
);
  logic [WIDTH-1:0] memory_q[0:DEPTH-1];
  logic [DEPTH-1:0] initialized_q;
  logic capture_valid_q;
  logic [WIDTH-1:0] capture_data_q;
  logic [ADDRESS_BITS-1:0] capture_address_q;
  assign invalid_read_o=run_i && request_valid_i && !write_i &&
    (int'(address_i)>=DEPTH || !initialized_q[address_i]);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      initialized_q<=0;capture_valid_q<=0;read_valid_o<=0;
      capture_data_q<=0;capture_address_q<=0;read_data_o<=0;read_address_o<=0;
      // Data array is not reset. Validity prevents consumption before STORE.
    end else if(!run_i) begin
      capture_valid_q<=0;read_valid_o<=0;
    end else begin
      capture_valid_q<=request_valid_i && !write_i && !invalid_read_o;
      read_valid_o<=capture_valid_q;
      if(capture_valid_q) begin read_data_o<=capture_data_q;read_address_o<=capture_address_q;end
      if(request_valid_i && int'(address_i)<DEPTH) begin
        if(write_i) begin memory_q[address_i]<=write_data_i;initialized_q[address_i]<=1;end
        else if(!invalid_read_o) begin capture_data_q<=memory_q[address_i];capture_address_q<=address_i;end
      end
    end
  end
  initial if(DEPTH<1 || WIDTH<1) $fatal(1,"Invalid accumulator bank");
endmodule
