// Queue-specific count-free frontend ISA. Each compute launch supplies one beat.
package lpu_mxm_isa_pkg;
  import lpu_mxm_config_pkg::*;
  localparam integer MXM_QUEUE_LOAD=0;
  localparam integer MXM_QUEUE_COMPUTE=1;
  localparam integer MXM_QUEUE_DEQUANT=2;
  localparam integer MXM_QUEUE_PARAM_LOAD=3;
  localparam integer MXM_QUEUE_BACKEND=4;
  localparam integer MXM_QUEUE_COUNT=5;
  localparam logic [1:0] MXM_INDUCTION_NONE=2'd0;
  localparam logic [1:0] MXM_INDUCTION_OPERAND0=2'd1;
  localparam logic [1:0] MXM_INDUCTION_OPERAND1=2'd2;
  localparam integer STREAM_BITS=6;
  localparam integer COMPUTE_INSTRUCTION_BITS=STREAM_BITS+1;
  localparam integer LOAD_INSTRUCTION_BITS=2;
  localparam integer PARAM_LOAD_INSTRUCTION_BITS=1;
  localparam integer DEQUANT_INSTRUCTION_BITS=1;
  localparam integer MACRO_INSTRUCTION_BITS=49;
  localparam integer MACRO_OPERAND_BITS=13;
  localparam integer LOAD_CYCLE_BITS=MATRIX_N>1?$clog2(MATRIX_N+1):1;
  localparam logic LOAD_MATRIX=1'b0,LOAD_COLUMN=1'b1;
  typedef struct packed {
    logic [STREAM_BITS-1:0] activation_stream; // [6:1].
    logic weight_buffer;                      // [0].
  } compute_instruction_t;
  typedef struct packed {
    logic weight_buffer;                 // [1].
    logic column_mode;                   // [0], MATRIX=0 / COLUMN=1.
  } load_instruction_t;
  // Queue identity supplies the operation. Parameter buffer IDs are
  // independent of load_instruction_t.weight_buffer. Every launch is one beat.
  typedef struct packed {
    logic param_buffer;
  } param_load_instruction_t;
  typedef struct packed {
    logic param_buffer;
  } dequant_instruction_t;

  // The packed Macro parser is shared by all five streams. These helpers
  // describe only the stream-specific native payload and induction state.
  function automatic integer macro_native_bits(input integer queue_kind);
    case(queue_kind)
      MXM_QUEUE_LOAD: macro_native_bits=LOAD_INSTRUCTION_BITS;
      MXM_QUEUE_COMPUTE: macro_native_bits=COMPUTE_INSTRUCTION_BITS;
      MXM_QUEUE_DEQUANT: macro_native_bits=DEQUANT_INSTRUCTION_BITS;
      MXM_QUEUE_PARAM_LOAD: macro_native_bits=PARAM_LOAD_INSTRUCTION_BITS;
      MXM_QUEUE_BACKEND: macro_native_bits=3+lpu_mxm_backend_isa_pkg::backend_address_bits(ACCUMULATOR_DEPTH);
      default: macro_native_bits=1;
    endcase
  endfunction

  function automatic integer macro_operand_bits(input integer queue_kind);
    case(queue_kind)
      MXM_QUEUE_COMPUTE: macro_operand_bits=STREAM_BITS;
      MXM_QUEUE_BACKEND: macro_operand_bits=lpu_mxm_backend_isa_pkg::backend_address_bits(ACCUMULATOR_DEPTH);
      default: macro_operand_bits=1;
    endcase
  endfunction
  // All binary words are meaningful. Load mode retains fixed hardware lengths:
  // MATRIX performs MATRIX_N shifts, COLUMN one. No programmable repeat count.
endpackage
