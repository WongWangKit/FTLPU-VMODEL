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
| VXM | 16 ALU queues, shared by all lanes |
| SXM | one per hemisphere |
| ICU queues | 138 |

The physical topology is:

```text
MXM.W[0:1] <-> SXM.W <-> MEM.W(52) <-> VXM <-> MEM.E(52) <-> SXM.E <-> MXM.E[0:1]
```

## ICU queue map

The RTL uses a uniform 416-bit queue payload so that the largest, 13-word SXM
packet fits without a side channel. Narrower instruction types occupy the low
bits.

| Queue indices | Consumer | Payload bits |
| --- | --- | ---: |
| 0..103 | MEM | 47 |
| 104..105 | MXM weight load, one queue per hemisphere | 48 |
| 106..107 | MXM BF16 dequant scale, one queue per hemisphere | 16 |
| 108..109 | MXM compute / accumulator read, one queue per hemisphere | 48 |
| 110..111 | Reserved | - |
| 112..127 | VXM ALU | 128 |
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
- All 138 independent ICU queues, including runtime refill, NOP, and Repeat
  timing.
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
- A shared boundary-0 VXM bridge with passive West-to-opposite-East routing,
  16 northbound ALU controls, per-lane ALU feedback state, and an exact integer
  subset covering `StreamInt8`, integral immediates, arithmetic, and saturated
  Int8 output.
- A C-model/VCS `MEM.W -> VXM Add -> MEM.E` comparison across all 32 lanes.
- Synthesizable FP16/BF16/FP32 stream conversion, sign/compare/ReLU operations,
  and format-aware floating ALU feedback.
- A C-model/VCS FP16 ReLU -> BF16 Cast -> FP32 Cast chain covering 2-byte and
  4-byte output packing across all 32 lanes.
- Synthesizable FP32 Add/Subtract/Multiply with guard/round/sticky alignment,
  normalization, and round-to-nearest-even, checked against C-model results
  containing non-exact decimal immediates.
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
| `lpu_vxm_control` | Advances each of the 16 ALU instruction waves through four tiles. |
| `lpu_vxm_execute` | Validates issued operations, gathers stream/immediate/feedback operands, consumes successful West operands, and dispatches the lane bank. |
| `lpu_vxm_alu` | Executes a parameterized bank of independent integer or floating-point lane operations and reports per-operation faults. |
| `lpu_vxm_result_packer` | Converts successful lane results to the selected output format and detects active-producer collisions. |
| `lpu_vxm_math_pkg` | Provides reusable FP16/BF16/FP32 conversion, rounding, integral-immediate, and Int8 saturation helpers. |
| `lpu_vxm_stream_bridge` | Arbitrates external East traffic, unconsumed cross-hemisphere West traffic, and active VXM result producers. |
| `lpu_vxm_slice` | Composes the VXM blocks and owns feedback registers plus sticky fault/conflict state. |

The tile/ALU/lane coordinates are flattened only at the ALU-bank interface.
The stateful control and feedback ownership remains in `lpu_vxm_slice`, while
execute, ALU, result packing, and bridge routing are independently reviewable
combinational blocks. This is an implementation hierarchy change only; it does
not alter the C-model instruction encoding or cycle contract.

The full C-model `TspSliceSystem` currently constructs its MEM region through
`TileArrayModel::LegacyLocalLinear()`: a MEM Read injects at the slice group's
input boundary. The standalone `MemArrayModel` defaults to downstream-boundary
placement. RTL follows the full-system mapping because existing workloads and
their `read_latency()` schedules use it. This distinction is captured in code
comments and in the generated East/West regression.

The remaining MXM modes and VXM arithmetic pipelines for Divide, Clamp, Square,
Sqrt, Exp, Log, subnormal arithmetic, and exceptional-value propagation are
subsequent implementation stages. SXM ShiftSelect and Distribute are
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
