// Independent accumulator/storage instruction stream with optional BF16 output.
package lpu_mxm_backend_isa_pkg;
  import lpu_mxm_config_pkg::*;
  localparam logic [1:0] DIRECT_OUT=2'd0, STORE=2'd1, ACC_STORE=2'd2, ACC_OUT=2'd3;
  function automatic integer backend_address_bits(input integer depth);
    backend_address_bits=depth>1?$clog2(depth):1;
  endfunction
  function automatic integer backend_instruction_bits(input integer depth);
    backend_instruction_bits=3+backend_address_bits(depth)+BACKEND_COUNT_BITS;
  endfunction
  localparam integer BACKEND_ADDRESS_BITS=backend_address_bits(ACCUMULATOR_DEPTH);
  localparam integer BACKEND_INSTRUCTION_BITS=backend_instruction_bits(ACCUMULATOR_DEPTH);
  localparam integer BACKEND_DURATION_BITS=BACKEND_COUNT_BITS+1;
  typedef struct packed {
    logic out_bf16;                // Default [22], zero for stores.
    logic [BACKEND_COUNT_BITS-1:0] count_minus_one; // Default [21:12].
    logic [BACKEND_ADDRESS_BITS-1:0] base_address; // Default [11:2].
    logic [1:0] opcode;            // [1:0].
  } backend_instruction_t;
  function automatic logic [BACKEND_DURATION_BITS-1:0] backend_duration(
    input logic [BACKEND_COUNT_BITS-1:0] count_minus_one
  );
    backend_duration={1'b0,count_minus_one}+BACKEND_DURATION_BITS'(1);
  endfunction
  // Shared field checker also accepts per-instance DEPTH overrides. All four
  // operations use the same bounded numbering space, including DIRECT_OUT.
  // Extend the addition: end==DEPTH is legal, overflow/wrap is never legal.
  function automatic logic backend_fields_legal(
    input integer unsigned depth,base_address,count,
    input logic [1:0] opcode,input logic out_bf16
  );
    logic [32:0] end_address;
    begin
      end_address={1'b0,base_address}+{1'b0,count};
      backend_fields_legal=depth>0 && count>=1 && count<=BACKEND_MAX_COUNT &&
        base_address<depth && end_address<=33'(depth) &&
        (!out_bf16 || opcode==DIRECT_OUT || opcode==ACC_OUT);
    end
  endfunction
  function automatic logic backend_legal(input logic [BACKEND_INSTRUCTION_BITS-1:0] bits);
    backend_instruction_t cmd;
    begin
      cmd=bits;
      backend_legal=backend_fields_legal(ACCUMULATOR_DEPTH,int'(cmd.base_address),
        int'(backend_duration(cmd.count_minus_one)),cmd.opcode,cmd.out_bf16);
    end
  endfunction
endpackage
