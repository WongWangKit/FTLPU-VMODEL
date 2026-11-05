// New 64-bit ISA; never reinterpret legacy 48-bit IW/Block8 instructions.
package lpu_mxm_isa_pkg;
  import lpu_mxm_config_pkg::*;
  localparam integer INSTRUCTION_BITS=64;
  localparam logic [1:0] LOAD_MATRIX=2'd0, LOAD_COLUMN=2'd1, COMPUTE=2'd2;
  typedef struct packed {
    logic version;                 // [63], must be 1.
    logic [5:0] column_index;       // [62:57], COLUMN only.
    logic [5:0] weight_stream;      // [56:51], row-local source binding.
    logic [5:0] reserved_output;    // [50:45], zero; backend owns output.
    logic [5:0] activation_stream;  // [44:39].
    logic [19:0] reserved_backend;  // [38:19], zero; independent backend queue.
    logic [15:0] count;             // [18:3], activation vectors, not capacity.
    logic weight_buffer;           // [2].
    logic [1:0] opcode;             // [1:0].
  } instruction_t;
  function automatic logic compute_legal(input logic [63:0] bits);
    instruction_t cmd;
    begin
      cmd=bits;
      compute_legal=cmd.version && cmd.opcode==COMPUTE &&
        cmd.count>=COMPUTE_MIN_COUNT && cmd.column_index==0 && cmd.weight_stream==0 &&
        cmd.reserved_output==0 && cmd.reserved_backend==0;
    end
  endfunction
  function automatic logic load_legal(input logic [63:0] bits);
    instruction_t cmd;
    begin
      cmd=bits;
      load_legal=cmd.version &&
        ((cmd.opcode==LOAD_MATRIX && cmd.column_index==0) ||
         (cmd.opcode==LOAD_COLUMN && int'(cmd.column_index)<MATRIX_N)) &&
        cmd.count==0 && cmd.reserved_backend==0 &&
        cmd.activation_stream==0 && cmd.reserved_output==0;
    end
  endfunction
endpackage
