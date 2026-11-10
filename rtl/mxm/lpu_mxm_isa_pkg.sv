// Queue-specific count-free frontend ISA. Each compute launch supplies one beat.
package lpu_mxm_isa_pkg;
  import lpu_mxm_config_pkg::*;
  localparam integer STREAM_BITS=6;
  localparam integer COMPUTE_INSTRUCTION_BITS=STREAM_BITS+1;
  localparam integer LOAD_INSTRUCTION_BITS=STREAM_BITS+2;
  localparam integer LOAD_CYCLE_BITS=MATRIX_N>1?$clog2(MATRIX_N+1):1;
  localparam logic LOAD_MATRIX=1'b0,LOAD_COLUMN=1'b1;
  typedef struct packed {
    logic [STREAM_BITS-1:0] activation_stream; // [6:1].
    logic weight_buffer;                      // [0].
  } compute_instruction_t;
  typedef struct packed {
    logic [STREAM_BITS-1:0] weight_stream; // [7:2].
    logic weight_buffer;                 // [1].
    logic column_mode;                   // [0], MATRIX=0 / COLUMN=1.
  } load_instruction_t;
  // All binary words are meaningful. Load mode retains fixed hardware lengths:
  // MATRIX performs MATRIX_N shifts, COLUMN one. No programmable repeat count.
endpackage
