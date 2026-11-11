// Compile-time defaults for the next parameterized MXM implementation.
// The new queued frontend and Supercell consume these defaults. Legacy MXM
// modules retain their current interfaces until their backend is migrated.
package lpu_mxm_config_pkg;
  // ---------- User configuration ----------

  // Supercell grid: default 4 x 4 cells of 8 x 8 weights = 32 x 32.
  parameter integer SC_ROWS = 4;
  parameter integer SC_COLS = 4;
  parameter integer CELL_K = 8;
  parameter integer CELL_N = 8;

  // Reserved choices are interface definitions, not implemented capabilities.
  typedef enum logic [1:0] {
    MXM_DTYPE_FP16 = 2'd0,
    MXM_DTYPE_BF16 = 2'd1,
    MXM_DTYPE_FP32 = 2'd2,
    MXM_DTYPE_INT8 = 2'd3
  } mxm_data_type_e;
  parameter mxm_data_type_e DATA_TYPE = MXM_DTYPE_BF16;

  // Ping-pong weight storage, matching the current two-buffer layout.
  parameter integer WEIGHT_BUFFER_COUNT = 2;
  // Paired scale/zero registers, independent of the BF16 weight buffers.
  parameter integer WEIGHT_PARAMETER_BUFFER_COUNT = 2;
  // Per-Lane byte streams, fixed at elaboration, independent of load words.
  parameter integer WEIGHT_STREAM_COUNT = 32;
  parameter integer WEIGHT_Q_STREAM = 0;
  parameter integer WEIGHT_SCALE_LO_STREAM = 1;
  parameter integer WEIGHT_SCALE_HI_STREAM = 2;
  parameter integer WEIGHT_ZERO_STREAM = 3;
  parameter bit WEIGHT_ZERO_POINT_ENABLE = 1'b1;
  localparam integer WEIGHT_EXTERNAL_BITS = 8;
  localparam integer WEIGHT_DEQUANT_STAGES = 3; // D3 is the destination weight register.
  localparam integer WEIGHT_DEQUANT_EXTRA_CYCLES = WEIGHT_DEQUANT_STAGES-1;

  // Accumulator shape: LENGTH FP32 elements per result, DEPTH results.
  // Default: 32 elements x 1024 results x 4 bytes = 128 KiB per MXM.
  parameter integer ACCUMULATOR_RESULT_LENGTH = SC_COLS * CELL_N;
  parameter integer ACCUMULATOR_DEPTH = 1024;
  parameter integer INSTRUCTION_QUEUE_DEPTH = 16;
  // Compiler contract only: no encoded length or compute execution counter.
  localparam integer COMPUTE_MIN_BATCHES = 32;
  localparam bit ACCUMULATOR_CONTINUOUS_PASS_EVEN_BATCHES = 1'b1;
  localparam integer SUPERLANE_INSTRUCTION_INTERVAL = 3;
  localparam integer DOT_PIPELINE_CYCLES = 9;
  localparam integer PARTIAL_ADD_CYCLES = 3;
  // Static top-to-left result return: column c turns at bottom-indexed row c.
  // Down (SC_ROWS-1-c) + left (c+1) registers gives SC_ROWS cycles on every
  // path. The complete core requires a square grid for this mapping.
  localparam integer RESULT_RETURN_CYCLES = SC_ROWS;
  localparam integer RESULT_SUPERLANE_INTERVAL = 1;
  // Work backwards from direct A/B capture, without new-partial wait registers.
  // Launch L0, prefetch L1, array A + SRAM B available L2, A1 captures L3.
  localparam integer BACKEND_COMMAND_TO_READ_CYCLES = 1;
  localparam integer BACKEND_COMMAND_TO_OPERAND_CYCLES = 3;
  localparam integer BACKEND_COMMAND_TO_WRITE_CYCLES = 6;
  localparam integer BACKEND_COMMAND_LEAD_CYCLES = 2; // Before returned data availability.
  localparam integer OUTPUT_CONVERSION_CYCLES = 1; // Shared FP32/BF16 output register.
  localparam integer BACKEND_OUTPUT_CYCLES = 5 + OUTPUT_CONVERSION_CYCLES;
  localparam integer BACKEND_PARTIAL_TO_OUTPUT_CYCLES = 3 + OUTPUT_CONVERSION_CYCLES;
  localparam integer ARRAY_PARTIAL_TO_OUTPUT_CYCLES =
    RESULT_RETURN_CYCLES + BACKEND_PARTIAL_TO_OUTPUT_CYCLES;

  // ---------- Derived properties: do not configure independently ----------

  localparam integer SC_COUNT = SC_ROWS * SC_COLS;
  localparam integer MATRIX_K = SC_ROWS * CELL_K;
  localparam integer MATRIX_N = SC_COLS * CELL_N;

  // Each Lane supplies one activation per cycle. The CELL_K values broadcast
  // to all CELL_N groups together; a single link register forwards them to
  // the next Supercell each cycle, independently of CELL_N.
  // Each group owns CELL_K multipliers: an 8 x 8 cell has 8 groups of 8,
  // hence 64 multipliers, not an extra replicated Block8 compute dimension.
  // Dot-product results travel upward; instructions/data are time-skewed
  // vertically adjacent cells to align the partial sums. The standalone RTL
  // uses nine dot stages and three upward-add stages; see mxm_supercell.md.
  localparam integer K_PAR = CELL_K;
  localparam integer N_PAR = CELL_N;
  localparam integer ACTIVATION_LANES = K_PAR;
  localparam integer DOT_OUTPUTS_PER_CELL = N_PAR;
  localparam integer MULTIPLIERS_PER_CELL = N_PAR * K_PAR;
  localparam integer ARRAY_MULTIPLIER_COUNT = SC_COUNT * MULTIPLIERS_PER_CELL;

  // Initial implementation target: BF16 inputs and FP32 dot/partial sums.
  // BF16 has an 8-bit significand (including the hidden bit), so each
  // multiplier uses an 8 x 8 significand product. The FP16-specific internal
  // exact-sum width must not be reused: BF16 has a much wider exponent range.
  // These flags describe operand support in the standalone Supercell.
  localparam bit SUPPORT_FP16 = 1'b0;
  localparam bit SUPPORT_BF16 = 1'b1;
  localparam bit SUPPORT_FP32 = 1'b0;
  localparam bit SUPPORT_INT8 = 1'b0; // Compute operands remain BF16, not integer MACs.
  localparam bit SUPPORT_INT8_WEIGHT_LOAD = 1'b1;
  localparam integer OPERAND_BITS = 16;
  localparam integer ACCUMULATOR_BITS = 32;

  // Local dot-product representation, not IEEE FP64: signed integers with
  // a shared, separately carried exponent. Keep this width through the CSA
  // tree and final carry-propagate adder; normalize/round to FP32 only after
  // all CELL_K products have been summed.
  localparam integer DOT_INTERNAL_BITS = 64;
  localparam integer DOT_GROWTH_BITS = CELL_K > 1 ? $clog2(CELL_K) : 0;
  localparam integer DOT_ALIGNED_PRODUCT_BITS =
    DOT_INTERNAL_BITS - 1 - DOT_GROWTH_BITS;
  // For CELL_K=8: 1 sign + 3 growth + 60 aligned-product bits.
  // Products outside the retained alignment window can lose low bits;
  // 64 bits does not guarantee exact summation for all BF16 exponent spans.

  localparam integer WEIGHT_BITS_PER_CELL = CELL_K * CELL_N * OPERAND_BITS;
  localparam integer WEIGHT_STORAGE_BITS =
    WEIGHT_BUFFER_COUNT * SC_COUNT * WEIGHT_BITS_PER_CELL;

  // ---------- New MXM weight-load instruction semantics ----------
  // W[k][n]: a load beat contains all MATRIX_K weights of one output column
  // n, split across SC_ROWS parallel row inputs (CELL_K values per row).
  // External default: 32 INT8 values / 256 weight bits per beat, plus
  // per-Lane BF16 scales and optional INT8 zero points loaded separately
  // into paired parameter ping-pong registers through fixed byte streams.
  // D1/D2 dequantize once at ingress; D3 is the BF16 weight-buffer write.
  // Internally all shift links and both buffers still carry BF16.
  // A MATRIX load supplies MATRIX_N consecutive beats to the selected buffer
  // using the horizontal shift chains. Tail data/valid/buffer ID cross ONE
  // register per cell, matching activation. Last-cell completion is later
  // by SC_COLS-1 edges, overlapped by the same activation offset. When compiler-scheduled compute batches
  // cover MATRIX_N cycles, next-buffer loading fits inside the current compute block.
  // A COLUMN load supplies one beat into the SAME shift chain. Every cell
  // that accepts that buffer's displaced tail shifts once. There is no column
  // address or selective group update; position follows the input sequence.
  // lpu_mxm_isa_pkg defines separate compact compute/load instruction formats.
  localparam integer WEIGHT_LOAD_ELEMENTS_PER_BEAT = MATRIX_K;
  localparam integer WEIGHT_LOAD_BEAT_BITS =
    WEIGHT_LOAD_ELEMENTS_PER_BEAT * WEIGHT_EXTERNAL_BITS;
  localparam integer WEIGHT_LOAD_ROW_BEAT_BITS = CELL_K * WEIGHT_EXTERNAL_BITS;
  localparam integer WEIGHT_BF16_ROW_BITS = CELL_K * OPERAND_BITS;
  localparam integer WEIGHT_PARAMETER_BITS_PER_LANE = 16 + (WEIGHT_ZERO_POINT_ENABLE ? 8 : 0);
  localparam integer WEIGHT_PARAMETER_STORAGE_BITS =
    SC_ROWS * WEIGHT_PARAMETER_BUFFER_COUNT * CELL_K * WEIGHT_PARAMETER_BITS_PER_LANE;
  localparam integer WEIGHT_LOAD_MATRIX_CYCLES = MATRIX_N;
  localparam integer WEIGHT_LOAD_COLUMN_CYCLES = 1;
  localparam integer WEIGHT_LOAD_BUFFER_ADDRESS_BITS =
    WEIGHT_BUFFER_COUNT > 1 ? $clog2(WEIGHT_BUFFER_COUNT) : 1;
  // Durations count weight input beats at the array interface, not command
  // propagation or result-pipeline drain. No automatic stall/retry: sources
  // and the selected destination buffer must be scheduled ready each beat.
  // Compiler emits each compute beat explicitly, in continuous groups of at
  // least COMPUTE_MIN_BATCHES. Compute/load instructions relay at full rate
  // through two intermediate registers plus each next local register (3 cycles).
  // No propagation timers or variable-length compute loops remain. MATRIX
  // retains its fixed MATRIX_N-beat loader; COLUMN launches can be consecutive.
  // For continuous in-place accumulation the compiler also preserves an even
  // complete address-pass length and the specified bank phase at boundaries.

  // ---------- New MXM accumulator architecture contract ----------
  // Implemented by lpu_mxm_backend / lpu_mxm_core; not migrated into the
  // legacy accumulator or lpu_top stream network.
  // Each vertical Supercell column owns CELL_N parallel FP32 adders and a
  // private pair of single-port logical SRAM banks. One batch is the CELL_N
  // simultaneous results from that column, never a single FP32 element.
  localparam integer ACCUMULATOR_COLUMN_COUNT = SC_COLS;
  localparam integer ACCUMULATOR_ELEMENTS_PER_BATCH = CELL_N;
  localparam integer ACCUMULATOR_ADDERS_PER_COLUMN = CELL_N;
  localparam integer ACCUMULATOR_BANK_COUNT_PER_COLUMN = 2;
  localparam integer ACCUMULATOR_BANK_PORTS = 1; // One read OR write per edge.
  localparam integer ACCUMULATOR_BANK_WORD_BITS =
    ACCUMULATOR_ELEMENTS_PER_BATCH * ACCUMULATOR_BITS;
  localparam integer ACCUMULATOR_BANK_DEPTH = ACCUMULATOR_DEPTH / 2;
  localparam integer ACCUMULATOR_BANK_ADDRESS_BITS =
    ACCUMULATOR_BANK_DEPTH > 1 ? $clog2(ACCUMULATOR_BANK_DEPTH) : 1;
  localparam integer ACCUMULATOR_STORAGE_BITS =
    ACCUMULATOR_RESULT_LENGTH * ACCUMULATOR_DEPTH * ACCUMULATOR_BITS;
  localparam integer ACCUMULATOR_STORAGE_BYTES = ACCUMULATOR_STORAGE_BITS / 8;
  // Default per column: 8 adders, two 512 x 256-bit banks. Four columns
  // together retain 128 KiB of logical capacity, with no third scratch bank.
  // Logical widths scale with CELL_N; 256 bits is the default, not a limit.
  // A technology wrapper may concatenate narrower macros using the same
  // address/control. RTL arrays alone do not guarantee SRAM macro mapping.

  // Logical batch address a: bank = a % 2, bank row = a / 2. Every batch
  // keeps all CELL_N FP32 values together and writes back to the SAME bank
  // and row. Each column starts its own stream at Bank0, then Bank1, etc.;
  // Column c is returned to Superlane c; adjacent Superlanes retain the
  // original one-edge output/command offsets after equal-length return.
  localparam bit ACCUMULATOR_IN_PLACE_WRITEBACK = 1'b1;
  localparam integer ACCUMULATOR_FIRST_BANK = 0;

  // Fixed edge contract for the backend: read request accepted E0;
  // read data available E1; adder captures A1/A2/A3 at E2/E3/E4; the SRAM
  // accepts/commits the write at E5. No uncounted stage may be inserted.
  // Cycle-accurate RTL contract, not a measured physical macro latency.
  localparam integer ACCUMULATOR_SRAM_READ_CYCLES = 1;
  localparam integer ACCUMULATOR_FP32_ADD_CYCLES = 3;
  localparam integer ACCUMULATOR_SRAM_WRITE_CYCLES = 1;
  localparam integer ACCUMULATOR_READ_TO_WRITE_CYCLES =
    ACCUMULATOR_SRAM_READ_CYCLES + ACCUMULATOR_FP32_ADD_CYCLES +
    ACCUMULATOR_SRAM_WRITE_CYCLES;
  // D=5 is odd: alternating reads and their in-place writes use opposite
  // banks on each service edge. This is NOT a guarantee for arbitrary
  // addresses/bubbles. The compiler preserves clock-based bank phase,
  // avoids direct-write/output conflicts, aligns SRAM B and observes address
  // dependencies. A bank-conflicting access is not silently queued/retried.
  localparam integer ACCUMULATOR_BATCH_II = 1;
  // No result-to-operand feedback register or forwarding/bypass network.
  // This is a fixed architecture property, not an implemented mode switch.
  localparam bit ACCUMULATOR_FEEDBACK_ENABLED = 1'b0;

  // Data routes: new FP32 dot -> A, SRAM write, or output. SRAM read -> B
  // only; B has no feedback or zero source. Add result -> SRAM write or output.
  // First results bypass addition. The compiler must not reread an address
  // until its previous write commits; a read and write of that bank cannot
  // share the commit edge. A 32-row round-robin accumulation pass revisits
  // each address after 32 edges, exceeding D=5. Input width alone does not
  // guarantee this spacing; shorter passes must be explicitly scheduled.
  // SRAM is not cleared on reset: consumers must initialize each address
  // before reading it. A separate backend ISA/queue owns these operations;
  // compute instructions carry no SRAM address, route or output-format flags.
  // Both output instructions select FP32 or BF16 RNE using the compact
  // backend word's high bit (default bit12; address width follows depth).
  // One shared output register gives both types the SAME launch-to-output
  // latency (6), II=1. Left-edge returned data to output is 4 cycles;
  // top-array data adds the equal-length RESULT_RETURN_CYCLES first.
  // SRAM/accumulation stay FP32, with D=5 unchanged. STORE reuses the
  // three-stage passthrough so all writes occupy the same A+3 commit phase.
  // BF16 output preserves subnormals and quiets NaNs; no output DAZ/FTZ.
  // Core carrier: each 32-bit lane holds FP32 or zero-extended BF16 plus a
  // per-column format flag. Final stream packing/destination remain deferred.

  // Consumers must reject an invalid configuration at elaboration; reserved
  // data types must never silently fall back to BF16. Pipeline latency,
  // initiation interval and accumulator hazards require separate RTL design;
  // multiplier count alone does not establish an end-to-end II of one.
  localparam bit CONFIG_VALID =
    (SC_ROWS > 0) && (SC_COLS > 0) && (CELL_K > 0) && (CELL_N > 0) &&
    (DATA_TYPE == MXM_DTYPE_BF16) &&
    (WEIGHT_BUFFER_COUNT == 2) &&
    (WEIGHT_PARAMETER_BUFFER_COUNT == 2) &&
    (DOT_ALIGNED_PRODUCT_BITS >= 16) &&
    (ACCUMULATOR_RESULT_LENGTH == MATRIX_N) &&
    (ACCUMULATOR_DEPTH >= 2) && (ACCUMULATOR_DEPTH <= 65536) &&
    ((ACCUMULATOR_DEPTH % 2) == 0) &&
    ((ACCUMULATOR_READ_TO_WRITE_CYCLES % 2) == 1);
endpackage
