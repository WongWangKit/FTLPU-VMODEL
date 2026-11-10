// Compact queue-specific frontend ISA, incompatible with former 64/48-bit ISA.
package lpu_mxm_isa_pkg;
  import lpu_mxm_config_pkg::*;
  localparam integer STREAM_BITS=6;
  localparam integer COMPUTE_INSTRUCTION_BITS=STREAM_BITS+COMPUTE_COUNT_BITS+1;
  localparam integer LOAD_INSTRUCTION_BITS=STREAM_BITS+2;
  localparam integer COMPUTE_DURATION_BITS=COMPUTE_COUNT_BITS+1;
  localparam integer LOAD_DURATION_BITS=MATRIX_N>1?$clog2(MATRIX_N+1):1;
  localparam logic LOAD_MATRIX=1'b0,LOAD_COLUMN=1'b1;
  typedef struct packed {
    logic [STREAM_BITS-1:0] activation_stream; // Default [16:11].
    logic [COMPUTE_COUNT_BITS-1:0] count_minus_one; // [10:1], 31..1023.
    logic weight_buffer;                      // [0]. Queue implies COMPUTE.
  } compute_instruction_t;
  typedef struct packed {
    logic [STREAM_BITS-1:0] weight_stream; // [7:2].
    logic weight_buffer;                 // [1].
    logic column_mode;                   // [0], MATRIX=0 / COLUMN=1.
  } load_instruction_t;
  function automatic logic [COMPUTE_DURATION_BITS-1:0] compute_duration(
    input logic [COMPUTE_INSTRUCTION_BITS-1:0] bits
  );
    compute_instruction_t cmd;
    begin
      cmd=bits;
      // Widen BEFORE adding: encoded 1023 is 1024, never zero.
      compute_duration={1'b0,cmd.count_minus_one}+COMPUTE_DURATION_BITS'(1);
    end
  endfunction
  function automatic logic compute_legal(input logic [COMPUTE_INSTRUCTION_BITS-1:0] bits);
    compute_legal=int'(compute_duration(bits))>=COMPUTE_MIN_COUNT;
  endfunction
  // All 256 load encodings are meaningful: mode chooses 1 or MATRIX_N shifts.
  // Queue availability, launch timing, source data and buffer ownership still
  // require checks; there is no column address or reserved encoding to decode.
endpackage
