// One explicit address per backend launch, with optional BF16 output.
package lpu_mxm_backend_isa_pkg;
  import lpu_mxm_config_pkg::*;
  localparam logic [1:0] DIRECT_OUT=2'd0, STORE=2'd1, ACC_STORE=2'd2, ACC_OUT=2'd3;
  function automatic integer backend_address_bits(input integer depth);
    backend_address_bits=depth>1?$clog2(depth):1;
  endfunction
  function automatic integer backend_instruction_bits(input integer depth);
    backend_instruction_bits=3+backend_address_bits(depth);
  endfunction
  localparam integer BACKEND_ADDRESS_BITS=backend_address_bits(ACCUMULATOR_DEPTH);
  localparam integer BACKEND_INSTRUCTION_BITS=backend_instruction_bits(ACCUMULATOR_DEPTH);
  typedef struct packed {
    logic out_bf16;                // Default [12], zero for stores.
    logic [BACKEND_ADDRESS_BITS-1:0] address; // Default [11:2], low bit selects bank.
    logic [1:0] opcode;            // [1:0].
  } backend_instruction_t;
  function automatic logic backend_fields_legal(
    input integer unsigned depth,address,
    input logic [1:0] opcode,input logic out_bf16
  );
    backend_fields_legal=depth>0 && address<depth &&
      (!out_bf16 || opcode==DIRECT_OUT || opcode==ACC_OUT);
  endfunction
  function automatic logic backend_legal(input logic [BACKEND_INSTRUCTION_BITS-1:0] bits);
    backend_instruction_t cmd;
    begin
      cmd=bits;
      backend_legal=backend_fields_legal(ACCUMULATOR_DEPTH,int'(cmd.address),cmd.opcode,cmd.out_bf16);
    end
  endfunction
endpackage
