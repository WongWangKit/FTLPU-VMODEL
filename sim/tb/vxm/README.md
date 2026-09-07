# VXM RTL test organization

Keep scalable VXM tests in this directory instead of adding one top-level file
for every physical ALU, source, opcode, and data format.

- `lpu_vxm_alu_stage_checker.sv` is the reusable position-aware checker. Add
  new opcode, source, dtype, latency, metadata, and fault cases here.
- `lpu_vxm_significand_multiplier_tb.sv` drives the segmented multiplier only
  through its ports and checks BF16/FP16/FP32 block gating, zero-chunk operand
  isolation, disabled behavior, and the complete 48-bit product.
- `lpu_vxm_shared_float_compare_tb.sv` drives only the shared comparator ports
  and checks FP16/BF16 low-part sharing, FP32 high/low hierarchy, signed MAX,
  NaN policy, signed zero, FTZ, and reserved-format behavior.
- `lpu_vxm_tile_pair_lut_tb.sv` programs only through module ports and checks
  eight Lane-parallel reads, back-to-back ownership by adjacent Tiles,
  simultaneous access to different functions, Stage-tagged returns, and
  explicit same-function/Lane collision reporting.
- `lpu_vxm_16_alu_tb.sv` is the regression top. It instantiates the checker for
  physical stages 0 through 15 and finishes only after all stages pass.
- `lpu_vxm_instruction_controller_tb.sv` verifies that one resident global +
  eight-local configuration is loaded once, executed by one shared Repeat
  counter, and retired only by the returned final marker.
- `lpu_vxm_tile_execution_tb.sv` verifies the assembled 16-stage/eight-lane
  Tile, resident configuration interface, chain-length-4 forwarding, and the
  single returned completion marker.
- `lpu_vxm_tile_fp32_phase_tb.sv` drives both FP32 input halves only through
  Tile ports, checks low/high phase consumption, 32-bit chain forwarding, and
  two-beat FP32 output serialization.
- `lpu_vxm_tile_special_paths_tb.sv` verifies tile-owned chain feedback,
  C1/C3 accumulator reset/update, FP16/BF16 packing/backpressure, and
  concurrent FP16/BF16/FP32 Exp/Reciprocal/Rsqrt traffic through the
  Lane-independent LUT SRAM interface.
- `lpu_vxm_slice_tb.sv` verifies the four physical Tile rows of the single VXM,
  both left-to-right and right-to-left flow settings, the one-cycle-per-row
  instruction wave, overlapping low/high FP32 port beats aligned with that
  wave, per-cell stream consumption, two-beat FP32 results, and the absence of boundary
  conflicts. Internal Slice signals are observation points only; all stimulus
  enters through the Slice instruction and stream ports.
- `lpu_vxm_slice_fp32_special_tb.sv` programs the compact LUT only through
  Slice ports, then verifies FP32 Exp/Reciprocal/Rsqrt across all four rows and
  both flow directions with low/high input and output phases.
- `lpu_vxm_slice_bf16_special_tb.sv` programs the same FP16 LUT through Slice
  ports, then verifies single-beat BF16 Exp/Reciprocal/Rsqrt across all four
  rows and both flow directions.
- Small tests in the parent `sim/tb` directory remain focused unit/smoke tests
  for one module or one historical regression.

The checker derives the local queue and special-ALU kind from the physical
stage. It must test only architecturally reachable sources for that position;
chain length is changed when a stage can legally act as both Head and Internal.
Supported operations are crossed with those legal source encodings using
fixed, independently known FP16/BF16/FP32 results. Distinct-value directed cases remain
alongside the cross to detect incorrect MUX selection.

The suite also covers every stage's chain-length-4 role, reset with Multiply
in flight, reserved chain/dtype/source/opcode encodings, and special-function
zero/Inf/NaN/negative/FTZ cases. Reciprocal additionally accesses a nonzero
LUT address so the test does not validate only entry zero.
