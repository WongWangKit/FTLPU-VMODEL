# FTLPU VMODEL architecture

This RTL derives its architectural constants, instruction encodings, and
cycle contracts from the sibling `FTLPU-CMODEL` repository's
`refactor/cmodel-architecture` branch.

## Fixed configuration

| Item | RTL value |
| --- | ---: |
| Tile rows / lanes per tile | 4 / 8 |
| Physical vector | 32 bytes |
| Hemispheres | 2 |
| Byte streams | 32 east + 32 west |
| MEM slices | 52 per hemisphere, 104 total |
| MEM groups / stream-register columns | 13 / 15 |
| SRAM geometry per MEM slice | 65,536 x 32 bytes |
| MXM | two 32 x 32 arrays per hemisphere, four total |
| VXM | one four-row VXM, 8 heterogeneous local ALU queues plus 1 global configuration queue |
| SXM | one per hemisphere |
| ICU address slots / physical queues | 138 / 131 |

The physical topology is:

```text
MXM.W[0:1] <-> SXM.W <-> MEM.W(52) <-> VXM <-> MEM.E(52) <-> SXM.E <-> MXM.E[0:1]
```

## ICU queue map

The schedule-loading interface is uniformly 416 bits so that the largest,
13-word SXM packet fits without a side channel. Physical VXM FIFO memories use
only their architectural 5/6/7/15-bit payload widths.

| Queue indices | Consumer | Payload bits |
| --- | --- | ---: |
| 0..103 | MEM | 47 |
| 104..105 | MXM weight load, one queue per hemisphere | 48 |
| 106..107 | MXM BF16 dequant scale, one queue per hemisphere | 16 |
| 108..109 | MXM compute / accumulator read, one queue per hemisphere | 48 |
| 110..111 | Reserved | - |
| 112 | VXM local Q0 | 6 |
| 113 | VXM local Q1 | 5 |
| 114 | VXM local Q2 | 7 |
| 115 | VXM local Q3 | 5 |
| 116 | VXM local Q4 | 7 |
| 117 | VXM local Q5 | 5 |
| 118 | VXM local Q6 | 7 |
| 119 | VXM local Q7 | 5 |
| 120 | VXM global configuration | 15 |
| 121..127 | Reserved | - |
| 128..129 | SXM transpose | 416 |
| 130..131 | SXM permute | 416 |
| 132..133 | secondary MXM weight load, one queue per hemisphere | 48 |
| 134..135 | secondary MXM BF16 dequant scale, one queue per hemisphere | 16 |
| 136..137 | secondary MXM compute / accumulator read, one queue per hemisphere | 48 |

Schedules may be preloaded while `run_i=0` or refilled while execution is
active. Each queue independently accepts a simultaneous enqueue/dequeue so
long schedules do not require layer-sized instruction SRAMs. `NOP` and
`Repeat` use the same 32-bit encoding. MEM queues additionally apply the signed
12-bit Repeat stride to SRAM row address bits `[30:15]`.

## Implemented RTL boundary

- Architectural constants and MEM/MXM/VXM/SXM instruction decoders.
- 131 independent physical ICU queues in a stable 138-slot address map,
  including runtime refill, NOP, and Repeat timing. VXM slots 121..127 are
  unimplemented reservations.
- South-to-north four-tile control pipelines.
- A byte-stream register stage with aggregate broadcast consumption and
  conflicting-producer detection.
- A synthesizable tile-local MEM SRAM slice supporting Read, Write, and
  ReadWrite; Gather/Scatter deliberately fault because the C model does not
  implement their address-stream datapath.
- Four-tile MEM-column composition and MXM/VXM control-wave blocks.
- Two 52-column MEM hemispheres with 14 MEM boundaries, passive one-hop
  East/West propagation, broadcast consumption, and collision detection.
- One physical SXM per hemisphere, including four tile-local FP16-byte
  Transpose banks, northbound capture control, complete-block Permute maps,
  registered passive boundary-13/14 bypass, and sticky encoding/collision
  faults.
- Two physical MXMs per hemisphere split into control-wave, Direct16/INT8
  weight buffers, vector/Block8 compute and accumulation, FP32 result emission,
  and stream-bridge modules. Local MXM 0 and 1 own distinct weight-stream
  windows while sharing activation streams.
- A top-level schedule-loading interface wired through ICU, MEM control waves,
  SRAM slices, and the MEM stream fabric.
- A C-model vector generator plus VCS end-to-end comparison for mirrored
  `MEM Read -> passive SR hops -> MEM Write` transfers.
- A second C-model generator and VCS comparison for a 16-stream, four-tile
  `MEM Read -> SXM Transpose -> identity block Permute -> MEM Write` transfer.
- A full 32x32 FP16 wavefront regression with four overlapping Transpose
  captures, MEM Repeat address strides, seven distinct cross-tile Permute maps,
  and comparison of all 1,024 output elements against C-model SRAM state.
- One four-Tile VXM between the two hemispheres, with global-direction input
  selection, opposite-side result routing, and passive boundary crossing.
- Eight heterogeneous compact local-control waves plus one independently
  committed global configuration wave.
- A position-parameterized 32-bit ALU interface with FP16, BF16, and FP32
  Basic and Special arithmetic.
- FP16 FTZ/RNE Bypass, Add, Subtract, Multiply, Negate, Max, Exp,
  Reciprocal, and Rsqrt units. Basic operations have one-cycle latency except
  Multiply at two cycles; special operations use five arithmetic stages plus
  a variable single-port-SRAM arbitration wait.
- FP32 Bypass, Add, Subtract, Multiply, Negate, and Max with the same Basic
  timing contract.
- FP32 Exp, Reciprocal, and Rsqrt with FP16 LUT coefficients widened before
  FP32 address/interpolation arithmetic.
- BF16 Basic and Special operations with FP32 internal arithmetic and RNE
  narrowing at each ALU result; the Special LUT remains FP16.
- C-model/VCS `MEM -> MXM -> MEM` comparisons using non-symmetric 32x32 BF16
  and FP16 permutation matrices. Each format loads and computes both weight
  buffers with distinct permutations and signed activation sets. Together the
  regressions cover sixteen Direct16 IW waves, sixteen four-tile accumulation
  sequences, sixteen staggered output column blocks, and all 128 FP32 results
  while detecting format, buffer-selection, and lane/column/block errors.
- A C-model/VCS Column Direct16 regression loads all 32 weight columns through
  two East streams, verifies delayed cell validity, and checks a non-symmetric
  32x32 BF16 permutation across all FP32 outputs.
- A C-model/VCS INT8 dequant regression pairs the load and dequant queues,
  checks positive and negative quantized weights with four BF16 scales, and
  compares all 32 FP32 outputs.
- A module-boundary MXM negative regression checks that missing/mispaired
  dequant instructions and overlapping compute waves assert sticky
  faults without consuming streams.
- A C-model/VCS Block8 regression consumes sixteen BF16 activation streams,
  computes eight rows by 32 columns, accumulates four tile contributions in a
  dedicated wide accumulator, checks all 256 BF16 stream results, and then
  checks all 256 FP32 values during retained read, read-clear, and
  zero-after-clear after an SRAM-destination compute.
- A C-model/VCS accumulator regression covers SRAM-destination compute,
  four-bank FP32 accumulation, continuous row progression with row stride 3,
  a new-wave row reset, retained AccumulatorRead, read-clear, and
  zero-after-clear across all 32 columns.
- A three-phase C-model/VCS SmolLM2 FFN regression carries actual RTL
  intermediates through SRAM from dual-MXM INT8-dequant Block8 gate/up, through
  the six-stage BF16 SwiGLU VXM program, into the INT8-dequant Block8 down
  projection, comparing gate/up, SwiGLU, and final FP32 images independently.

### MXM module boundaries

| Module | Hardware responsibility |
| --- | --- |
| `lpu_mxm_control` | Advances independent load, dequant, and compute instructions through four physical tiles. |
| `lpu_mxm_dequantizer` | Converts signed INT8 weights times a BF16 scale into BF16 with round-to-nearest-even. |
| `lpu_mxm_weight_buffer` | Consumes full-cell or per-column Direct16/INT8 East streams and owns two buffers of four-by-four 8x8 weight cells plus inner-column validity. |
| `lpu_mxm_dot_bank` | Implements the 32 parallel eight-element FP32 dot products for one active physical tile. |
| `lpu_mxm_compute` | Selects the active tile, runs one or eight dot-bank rows, accumulates four tile contributions, and emits Vector or Block8 transactions. |
| `lpu_mxm_accumulator` | Architectural Vector reference backend used by the default regression build. |
| `lpu_mxm_block_accumulator` | Architectural Block8 reference backend used by the default regression build. |
| `lpu_mxm_shared_accumulator` | Selects the cycle-compatible reference backends or the physical Vector-only SRAM backend. |
| `lpu_mxm_accumulator_sram` | Composes two 512 x 128 single-port macros into one 512 x 256 row bank. |
| `lpu_mxm_slice` | Composes control, weight storage, compute, passive stream routing, collision detection, and sticky faults. |

The functional MXM subset supports full-supercell and Column Direct16 IW,
full-supercell and Column INT8-to-BF16 dequant IW, Vector and Block8 Compute,
FP16/BF16 input, Stream or SRAM destination, nonzero row stride, retain/clear,
Vector and Block8 AccumulatorRead, FP32 accumulator stream output, and BF16
Block8 compute stream output. Overlapping compute waves assert `mxm_fault_o`. This keeps
unsupported behavior explicit while preserving the current 48-bit C-model
encoding.

The RTL is structurally synthesizable: state uses bounded registers/SRAM-style
arrays, loops have static bounds, and no simulation-only timing constructs are
present under `rtl/`. The MEM tile has two explicit implementations selected
by `USE_SRAM_MACRO`. The default behavioral path preserves the C-model's
zero-latency reads. The physical path uses a synchronous 1RW abstraction and
banks a 64-bit x 65,536-row tile across 32 ARM `sram_64_2048` macros. A MEM
Read returns one cycle after issue; ReadWrite performs the read first and the
write on the following cycle because the macro is single-port. Design Compiler
L-2016.03 maps the surrounding logic to TSMC28 cells and preserves all 32 macro
instances; `scripts/dc_mem_macro.sh` checks that count before and after compile.

Design Compiler L-2016.03 maps the physical Vector accumulator to sixteen ARM
`sram_128_512` macros: eight independently selected 256-bit row banks, with two
128-bit macros per bank. One DesignWare FP32 adder is reused across the eight
lanes. At TT 0.9 V/25 C the isolated target has 522,018.7 um2 cell area,
including 491,773.8 um2 of SRAM macro area, and a 2.37 ns critical path under a
10 ns clock constraint. `scripts/dc_acc_macro.sh` checks the macro count before
and after mapping and writes all reports under `build/dc_acc_macro/`.
Accumulator capacity is configured at `lpu_top` with
`MXM_ACCUMULATOR_BLOCK_COUNT`, where one block is one complete 32x32 FP32
partial-sum tile. The default 32 blocks derive 1024 Vector rows or 128 Block8
rows, and both layouts therefore contain 128 KiB per MXM. The 13-bit instruction
address limits the parameter to 1..256 blocks. The default reference build
represents the Vector accumulator as four `(block_count * 32)` x 256-bit
segment banks and Block8 as four `(block_count * 4)` x 2048-bit banks. The
macro build instead uses one shared 128 KiB physical store for Vector data,
performs a post-reset zero sweep, and serializes its read-modify-write
operation. Block8 is intentionally unsupported in this backend. The full macro
script additionally defines `FTLPU_DISABLE_BLOCK8`, reducing the MXM compute
array from eight dot rows to one and making Block8 instructions fault rather
than allocating unused adders.

### VXM module boundaries

| Module | Hardware responsibility |
| --- | --- |
| `lpu_vxm_control` | Advances eight heterogeneous local words and the global configuration through four Tile rows, one row per cycle. |
| `lpu_vxm_input_converter` | Performs supported chain-head conversions among FP16, BF16, and FP32 while preserving a stable 32-bit container. |
| `lpu_vxm_alu` | Validates format/opcode, dispatches Basic versus position-specific Special execution, and detects result collisions. |
| `lpu_vxm_basic_alu` | Executes FP16/BF16/FP32 Bypass/Add/Subtract/Multiply/Negate/Max with one/two-cycle timing. BF16/FP32 share the wide adder, ADD/SUBTRACT/MAX share one comparator front end, and all formats share the segmented multiplier. |
| `lpu_vxm_mul8x8` | Defines one operand-isolated 8x8 unsigned multiplier boundary while leaving its internal implementation to synthesis. |
| `lpu_vxm_significand_multiplier` | Builds a shared 24x24 significand multiplier from nine gated 8x8 blocks; BF16 enables one block, FP16 up to four, and FP32 up to nine. |
| `lpu_vxm_shared_float_multiplier` | Left-aligns FP16/BF16/FP32 significands, drives the shared block multiplier, performs FP32-style normalization/RNE, and packs the selected result format. |
| `lpu_vxm_shared_float_compare` | Sanitizes operands and implements the shared magnitude/order/MAX front end: FP16/BF16 use the low 15-bit layer and FP32 adds a high 16-bit layer. |
| `lpu_vxm_lut_storage` | Provides the legacy/standalone configurable LUT used by isolated ALU tests. |
| `lpu_vxm_lut_sram` | Implements one physical 64x32 single-read function SRAM, storing each FP16 `{k,b}` pair in one row. |
| `lpu_vxm_tile_pair_lut` | Implements one adjacent-Tile shared set of 24 SRAMs: one single-read SRAM for every special-function/Lane pair, with one-cycle Tile/Stage-tagged return and collision detection. |
| `lpu_vxm_special_alu` | Performs range reduction, waits for its tagged external LUT response, interpolates `k*dx+b`, and restores the result exponent. |
| `lpu_vxm_fp16_pkg` | Implements FP16 classification, FTZ, RNE arithmetic, division, square-root, reciprocal, and rsqrt helpers. |
| `lpu_vxm_math_pkg` | Retains reusable format-conversion and FP32 helpers shared by the remaining RTL. |
| `lpu_vxm_stream_bridge` | Arbitrates external East traffic, unconsumed cross-hemisphere West traffic, and active VXM result producers. |
| `lpu_vxm_slice` | Composes four execution Tiles into the single VXM and applies the global direction bit to its boundary-input MUXes and result routes. |
| `lpu_vxm_global_config` | Holds shadow/current global VXM state and commits it only at a safe configuration boundary. |

The ALU uses a 32-bit data container and a 2-bit format selector. FP16, BF16,
and FP32 Basic and Special operations share the interface. The reserved format
does not issue and raises `unsupported_format_o`; unsupported position/opcode
combinations raise `illegal_opcode_o`. Arithmetic uses deterministic
RNE/flush-to-zero handling and a canonical quiet NaN.

Basic multiplication uses one explicitly segmented significand multiplier for
all three formats. The 24-bit operands are divided into three 8-bit chunks.
Format gating plus zero-chunk operand isolation activates only `P22` for BF16,
up to `P11/P12/P21/P22` for FP16, and up to all nine blocks for FP32. Each 8x8
leaf still uses the synthesizable `*` operator, so the target synthesis flow
chooses its internal Array/Booth/library implementation.

Basic comparison is also explicitly hierarchical. One 15-bit comparator
covers the complete signless FP16/BF16 encoding and the low portion of FP32;
FP32 first compares `[30:15]` and consults the shared low layer only on a tie.
The resulting magnitude order selects the larger operand for floating-point
addition/subtraction alignment and also drives signed MAX selection, avoiding
three independently inferred comparators in each physical ALU.

The Special path uses function ID 0 for Exp, 1 for Reciprocal, and 2 for
Rsqrt. One adjacent-Tile pair physically instantiates 24 independent 64x32
single-read SRAMs, one per `{function, Lane}`; each row stores one FP16 `{k,b}`
coefficient pair. Four Tile rows use two shared sets, so one Slice contains 48
SRAMs. Every function also owns programmable FP16 `input_min` and
`segment_width` state, replicated consistently across its eight Lane SRAMs.
The one-cycle control/data wave alternates ownership between adjacent Tiles.
Tile and physical-Stage tags route the next-cycle response without an arbiter.
Two Tiles, or two Stages within one Tile, requesting the same function/Lane in
one cycle is a protocol fault that the compiler schedule must prevent.

The compute unit clamps the derived address, consumes the tagged `{k,b}`
response, and evaluates `k*dx+b` before exponent/sign restoration. LUT-free
special cases retain the base pipeline latency; a lookup adds only its
arbitration wait. In BF16 and FP32 modes, `input_min`, `segment_width`, `k`, and `b`
are widened from FP16 and all address/interpolation arithmetic remains FP32;
BF16 narrows the final ALU result with RNE. The
default SRAM depth is 64 and is parameterized. One Slice LUT programming port
broadcasts identical contents into both pair sets and all eight Lane replicas
of the selected function.

The active ICU-to-Slice control path separates one 15-bit global queue from
eight physical local FIFOs with 6/5/7/5/7/5/7/5-bit payloads.  The local words
and the committed global word advance through four Tile rows. Each Tile stores
its resident configuration. Queues 121..127 are no longer instantiated. The
former 16 x 128-bit control path is not active. Compact local decode, fixed
stream operand selection, 16-stage ALU chaining, and FP16/BF16/FP32 result
serialization are connected at Tile level; the Slice connects all four Tiles
to the two boundary hemispheres.

The 15-bit global configuration begins with a 1-bit `flow_direction`, followed
by 2-bit `chain_length`, `active_width`, and `compute_dtype` fields and
independent 2-bit read-width and dtype fields for LHS and RHS. The direction
bit selects the left or right input boundary and routes results to the opposite
hemisphere. Chain-head conversion is selected from source and compute dtypes
without a redundant conversion-enable bit.

`lhs_read_bits` and `rhs_read_bits` encode 16-bit one-beat or 32-bit two-beat
collection independently. FP16/BF16 use one beat. FP32 uses little-endian
phase order: low 16 bits
first and high 16 bits second over the same fixed stream pair. The assembled
operand and all internal/feedback/accumulator tokens remain 32 bits. FP32 tail
traffic is serialized over the corresponding result pair in the same order.
The collector retains a complete operand through the following execute cycle,
giving repeated FP32 traffic a low/high/execute cadence without overwriting a
resident operand.

VXM unit tests are separated by boundary. `lpu_vxm_icu_map_tb` checks all
eight heterogeneous local FIFOs plus the global FIFO in the physical ICU, and
`lpu_vxm_control_tb` checks four-Tile local/global propagation.
Each FP16 opcode also has its own top-level test (`lpu_vxm_bypass_tb` through
`lpu_vxm_rsqrt_tb`), backed by a shared harness that programs external LUT
storage for Special operations. `lpu_vxm_alu_tb` remains the combined ALU
regression.

The full C-model `TspSliceSystem` currently constructs its MEM region through
`TileArrayModel::LegacyLocalLinear()`: a MEM Read injects at the slice group's
input boundary. The standalone `MemArrayModel` defaults to downstream-boundary
placement. RTL follows the full-system mapping because existing workloads and
their `read_latency()` schedules use it. This distinction is captured in code
comments and in the generated East/West regression.

The remaining MXM modes are subsequent implementation stages. VXM subnormal
values intentionally use the C-model FTZ policy. The Special ALU and
programmable LUT storage remain separate modules; Tile integration encodes the
requesting Stage, while Slice integration provides fixed-phase adjacent-Tile
sharing and tagged one-cycle response routing around the Lane-level SRAMs.
SXM ShiftSelect and Distribute are
intentionally still control/ISA-only. Their interfaces should consume the
already stable ISA and control-wave blocks; no new encoding should be
introduced without first updating the C model codec tests.

For an isolated MEM/SXM beat in the current C-model topology, the generator
uses `capture_cycle - (14 - group)` for East reads and
`capture_cycle + (14 - group)` for West writes. This accounts for the
next-state commit at the MEM boundary before SXM can observe or MEM can consume
the value. The generator runs and verifies the C model before publishing any
RTL vectors.

## Cycle rules

1. Instructions dispatch from ICU queues on a rising edge.
2. Control pulses enter tile 0 and advance one tile per rising edge.
3. Stream stages read current inputs and publish next-state outputs on the next
   rising edge.
4. Multiple consumers must OR their consume bits before driving a stream stage;
   this preserves the C model's broadcast semantics.
5. Two different producers targeting the same next-state cell assert
   `conflict_o`.
6. Transpose control advances through four tiles; Permute is a single physical
   instruction and may read a captured tile only after one full cycle.
7. When a wavefront reuses one Transpose tile in the same cycle, Permute reads
   and releases the old bank contents before the new Transpose capture commits.
8. Passive traffic crosses the SXM boundary-14 register in one cycle. MXM
   Direct16/activation consumers and returning FP32 results are scheduled
   against this physical hop.

For small simulations, `lpu_top.ACTIVE_MEM_COLUMNS` can elaborate a prefix of
the 52 physical columns in each hemisphere while preserving architectural queue
numbering. Its synthesis/default value is 52.
