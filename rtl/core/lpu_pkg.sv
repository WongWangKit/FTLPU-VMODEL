package lpu_pkg;
  // Keep these values aligned with FTLPU-CMODEL/core/hardware_params.hpp.
  localparam integer TILE_ROWS             = 4;
  localparam integer LANES_PER_TILE        = 8;
  localparam integer PHYSICAL_VECTOR_BYTES = 32;

  localparam integer HEMISPHERES           = 2;
  localparam integer STREAMS_PER_DIRECTION = 32;
  localparam integer PACKED_STREAMS        = 64;
  localparam integer STREAM_BYTE_WIDTH     = 8;

  localparam integer MEM_SLICES_PER_HEMISPHERE = 52;
  localparam integer MEM_SLICE_COUNT            = 104;
  localparam integer MEM_SLICES_PER_GROUP       = 4;
  localparam integer MEM_GROUPS                 = 13;
  localparam integer STREAM_REGISTER_COLUMNS    = 15;
  localparam integer MEM_BOUNDARY_COLUMN        = 13;
  localparam integer MXM_BOUNDARY_COLUMN        = 14;
  localparam integer SRAM_DEPTH_ROWS            = 65536;
  localparam integer SRAM_ROW_BYTES             = 32;

  localparam integer MXM_COUNT            = 2;
  localparam integer MXM_ROWS             = 32;
  localparam integer MXM_COLUMNS          = 32;
  localparam integer MXM_ACCUMULATOR_ROWS = 8192;
  localparam integer VXM_ALU_COUNT         = 16;
  localparam integer SXM_COUNT             = 2;

  localparam integer MEM_INSTRUCTION_WIDTH = 47;
  localparam integer MXM_INSTRUCTION_WIDTH = 48;
  localparam integer VXM_INSTRUCTION_WIDTH = 128;
  localparam integer SXM_INSTRUCTION_WIDTH = 416;
  localparam integer ICU_PAYLOAD_WIDTH     = SXM_INSTRUCTION_WIDTH;
  localparam integer ICU_QUEUE_COUNT       = 132;

  localparam integer MEM_QUEUE_BASE           = 0;
  localparam integer MXM_LOAD_QUEUE_BASE      = 104;
  localparam integer MXM_DEQUANT_QUEUE_BASE   = 106;
  localparam integer MXM_COMPUTE_QUEUE_BASE   = 108;
  localparam integer VXM_QUEUE_BASE           = 112;
  localparam integer SXM_TRANSPOSE_QUEUE_BASE = 128;
  localparam integer SXM_PERMUTE_QUEUE_BASE   = 130;

  typedef enum logic {
    HEMISPHERE_EAST = 1'b0,
    HEMISPHERE_WEST = 1'b1
  } hemisphere_e;

  typedef enum logic [2:0] {
    MEM_READ       = 3'd0,
    MEM_WRITE      = 3'd1,
    MEM_READ_WRITE = 3'd2,
    MEM_GATHER     = 3'd3,
    MEM_SCATTER    = 3'd4
  } mem_opcode_e;

  typedef enum logic [1:0] {
    MXM_IW               = 2'd0,
    MXM_COMPUTE          = 2'd1,
    MXM_ACCUMULATOR_READ = 2'd2
  } mxm_opcode_e;

  typedef enum logic [4:0] {
    VXM_PASS     = 5'd0,
    VXM_ADD      = 5'd1,
    VXM_SUBTRACT = 5'd2,
    VXM_MULTIPLY = 5'd3,
    VXM_DIVIDE   = 5'd4,
    VXM_NEGATE   = 5'd5,
    VXM_ABS      = 5'd6,
    VXM_MIN      = 5'd7,
    VXM_MAX      = 5'd8,
    VXM_CLAMP    = 5'd9,
    VXM_SQUARE   = 5'd10,
    VXM_SQRT     = 5'd11,
    VXM_EXP      = 5'd12,
    VXM_LOG      = 5'd13,
    VXM_RELU     = 5'd14,
    VXM_CAST     = 5'd15
  } vxm_opcode_e;

  typedef enum logic [1:0] {
    SXM_SHIFT_SELECT = 2'd0,
    SXM_DISTRIBUTE   = 2'd1,
    SXM_TRANSPOSE    = 2'd2,
    SXM_PERMUTE      = 2'd3
  } sxm_opcode_e;

  typedef enum logic [1:0] {
    ICU_INSTRUCTION = 2'd0,
    ICU_NOP         = 2'd1,
    ICU_REPEAT      = 2'd2
  } icu_command_opcode_e;

  function automatic logic [5:0] packed_stream(
    input logic direction_west,
    input logic [4:0] index
  );
    packed_stream = {direction_west, index};
  endfunction
endpackage
