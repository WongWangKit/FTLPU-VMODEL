// Independent accumulator/storage instruction stream with optional BF16 output.
package lpu_mxm_backend_isa_pkg;
  import lpu_mxm_config_pkg::*;
  localparam logic [1:0] DIRECT_OUT=2'd0, STORE=2'd1, ACC_STORE=2'd2, ACC_OUT=2'd3;
  typedef struct packed {
    logic version;                // [63], must be one.
    logic [27:0] reserved;         // [62:35], must be zero.
    logic out_bf16;                // [34], DIRECT_OUT/ACC_OUT only; zero for stores.
    logic [15:0] count;            // [33:18], result batches, independent of compute COUNT.
    logic [15:0] base_address;     // [17:2], linear batch address; low bit selects bank.
    logic [1:0] opcode;            // [1:0].
  } backend_instruction_t;
  function automatic logic backend_legal(input logic [63:0] bits);
    backend_instruction_t cmd;
    logic [16:0] end_address;
    begin
      cmd=bits;end_address={1'b0,cmd.base_address}+{1'b0,cmd.count};
      backend_legal=cmd.version && cmd.reserved==0 && cmd.count!=0 &&
        (!cmd.out_bf16 || cmd.opcode==DIRECT_OUT || cmd.opcode==ACC_OUT) &&
        end_address<=17'd65536 &&
        (cmd.opcode==DIRECT_OUT || end_address<=ACCUMULATOR_DEPTH);
    end
  endfunction
endpackage
