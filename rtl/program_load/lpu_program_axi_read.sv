// Conservative AXI4 program-read manager. One aligned single-beat AXI read
// at a time; one dedicated response register is reserved before publishing AR.
// The loader's LAST is the end of its byte range, not AXI RLAST.
module lpu_program_axi_read #(
  parameter integer DATA_WIDTH = 256,
  parameter integer ID_WIDTH = 8
) (
  input logic clk_i, rst_ni,
  input logic cancel_i,
  input logic command_valid_i,
  output logic command_ready_o,
  input logic [63:0] command_address_i,
  input logic [31:0] command_length_i,
  input logic [ID_WIDTH-1:0] command_id_i,
  output logic response_valid_o,
  input logic response_ready_i,
  output logic [DATA_WIDTH-1:0] response_data_o,
  output logic [DATA_WIDTH/8-1:0] response_keep_o,
  output logic response_last_o,
  output logic [ID_WIDTH-1:0] response_id_o,
  output logic response_error_o,
  output logic idle_o,
  output logic protocol_error_o,
  output logic [63:0] araddr_o,
  output logic [ID_WIDTH-1:0] arid_o,
  output logic [7:0] arlen_o,
  output logic [2:0] arsize_o,
  output logic [1:0] arburst_o,
  output logic arvalid_o,
  input logic arready_i,
  input logic [DATA_WIDTH-1:0] rdata_i,
  input logic [ID_WIDTH-1:0] rid_i,
  input logic [1:0] rresp_i,
  input logic rlast_i, rvalid_i,
  output logic rready_o
);
  localparam integer BYTES = DATA_WIDTH/8;
  localparam integer BYTE_SHIFT = $clog2(BYTES);
  typedef enum logic [2:0] {IDLE, ADDR, DATA, RESP, BAD_DRAIN} state_e;
  state_e state_q;
  logic [63:0] address_q;
  logic [31:0] remaining_q, take_bytes;
  logic [ID_WIDTH-1:0] id_q;
  logic cancel_q;
  logic [31:0] offset_bytes;
  logic [64:0] command_end;
  logic protocol_error_q;

  initial begin
    if (DATA_WIDTH < 8 || DATA_WIDTH > 1024 || DATA_WIDTH != 8*(1<<BYTE_SHIFT))
      $fatal(1,"Program AXI width must be a power-of-two byte count between 1 and 128");
  end
  assign command_end = {1'b0,command_address_i} + {33'b0,command_length_i};
  assign offset_bytes = 32'(address_q & 64'(BYTES-1));
  assign take_bytes = (remaining_q < 32'(BYTES)-offset_bytes)
                    ? remaining_q : 32'(BYTES)-offset_bytes;
  assign araddr_o = address_q & ~64'(BYTES-1);
  assign arid_o = id_q;
  assign arlen_o = '0;
  assign arsize_o = 3'(BYTE_SHIFT);
  assign arburst_o = 2'b01;
  assign arvalid_o = state_q == ADDR;
  assign rready_o = state_q == DATA || state_q == BAD_DRAIN;
  assign command_ready_o = state_q == IDLE && !cancel_i;
  // Keep VALID sticky under ordinary backpressure. During cancellation the
  // internal loader may already be faulted; discard only at this private port.
  assign response_valid_o = state_q == RESP && !cancel_i && !cancel_q;
  assign response_id_o = id_q;
  assign idle_o = state_q == IDLE;
  assign protocol_error_o = protocol_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      address_q <= '0;
      remaining_q <= '0;
      id_q <= '0;
      cancel_q <= 1'b0;
      protocol_error_q <= 1'b0;
      response_data_o <= '0;
      response_keep_o <= '0;
      response_last_o <= 1'b0;
      response_error_o <= 1'b0;
    end else begin
      if (state_q != IDLE && cancel_i) cancel_q <= 1'b1;
      case (state_q)
        IDLE: begin
          cancel_q <= 1'b0;
          protocol_error_q <= 1'b0;
          if (command_valid_i && command_ready_o) begin
            address_q <= command_address_i;
            remaining_q <= command_length_i;
            id_q <= command_id_i;
            if (command_length_i == 0 || command_end > 65'h1_0000_0000_0000_0000) begin
              response_data_o <= '0;
              response_keep_o <= '0;
              response_last_o <= 1'b1;
              response_error_o <= 1'b1;
              state_q <= RESP;
            end else state_q <= ADDR;
          end
        end
        ADDR: if (arready_i) state_q <= DATA; // Never revoke an already published AR.
        DATA: if (rvalid_i) begin
          if (!rlast_i || rid_i != id_q) protocol_error_q <= 1'b1;
          response_data_o <= rdata_i >> (8*offset_bytes);
          for (integer byte_index=0;byte_index<BYTES;byte_index++)
            response_keep_o[byte_index] <= byte_index < take_bytes;
          response_last_o <= remaining_q == take_bytes || rresp_i != 0 || rid_i != id_q || !rlast_i;
          response_error_o <= rresp_i != 0 || rid_i != id_q || !rlast_i;
          remaining_q <= remaining_q - take_bytes;
          address_q <= address_q + {32'b0,take_bytes};
          if (!rlast_i || rid_i != id_q) state_q <= BAD_DRAIN;
          else if (cancel_q || cancel_i) state_q <= IDLE;
          else state_q <= RESP;
        end
        // A foreign RID cannot retire our obligation. Publish the sticky
        // protocol error at top level and wait for a matching terminal beat.
        BAD_DRAIN: if (rvalid_i && rlast_i && rid_i == id_q) begin
          if (cancel_q || cancel_i) state_q <= IDLE;
          else state_q <= RESP;
        end
        RESP: begin
          if (cancel_i || cancel_q) state_q <= IDLE;
          else if (response_ready_i) begin
            if (response_last_o) state_q <= IDLE;
            else state_q <= ADDR;
          end
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
