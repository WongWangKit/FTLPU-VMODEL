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
| MXM | one 32 x 32 array per hemisphere, two total |
| VXM | 16 ALU queues, shared by all lanes |
| SXM | one per hemisphere |
| ICU queues | 132 |

The physical topology is:

```text
MXM1 <-> SXM.W <-> MEM.W(52) <-> VXM <-> MEM.E(52) <-> SXM.E <-> MXM0
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

Schedules are loaded while `run_i=0`. Raising `run_i` freezes queue loading and
starts one dispatch decision per queue per cycle. This directly implements the
C model's offline-schedule contract. `NOP` and `Repeat` use the same 32-bit
encoding. MEM queues additionally apply the signed 12-bit Repeat stride to SRAM
row address bits `[30:15]`.

## Implemented RTL boundary

- Architectural constants and MEM/MXM/VXM/SXM instruction decoders.
- All 132 independent ICU queues, including NOP and Repeat timing.
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
- One physical MXM per hemisphere split into control-wave, Direct16 weight
  buffer, vector compute/accumulation, FP32 result emission, and stream-bridge
  modules.
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

### MXM module boundaries

| Module | Hardware responsibility |
| --- | --- |
| `lpu_mxm_control` | Advances independent load, dequant, and compute instructions through four physical tiles. |
| `lpu_mxm_dequantizer` | Converts signed INT8 weights times a BF16 scale into BF16 with round-to-nearest-even. |
| `lpu_mxm_weight_buffer` | Consumes full-cell or per-column Direct16/INT8 East streams and owns two buffers of four-by-four 8x8 weight cells plus inner-column validity. |
| `lpu_mxm_dot_bank` | Implements the 32 parallel eight-element FP32 dot products for one active physical tile. |
| `lpu_mxm_compute` | Selects the active tile, runs one or eight dot-bank rows, accumulates four tile contributions, and emits Vector or Block8 transactions. |
| `lpu_mxm_accumulator` | Owns four 8192 x 8 FP32 banks, performs read-modify-write accumulation, and emits/clears four staggered stream segments. |
| `lpu_mxm_block_accumulator` | Owns four 1024 x 8 x 8 FP32 banks and emits 16-stream BF16 Block8 results or 32-stream FP32 reads. |
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
present under `rtl/`. Design Compiler L-2016.03 successfully analyzes the MXM
source hierarchy, including the four-bank accumulator and INT8/BF16
dequantizer plus the Block8 compute/wide-accumulator sources, and elaborates/checks
the isolated 32-output dot bank. Its
pre-optimization check reports dead intermediate cells inside the expanded
custom FP functions; a later compile pass must remove and recheck those cells.
The first compute implementation deliberately expands the four 8x8 tile
contributions in parallel, and full-slice elaboration was not completed during
this milestone because that network is very large. Treat the current block as
functionally synthesizable, not yet PPA-qualified. Pipelining or resource
sharing the dot-product bank is required before timing/area signoff.
The accumulator is represented as four 8192 x 256-bit segment banks plus valid
state. Its bounded storage and single-segment update path are synthesizable,
but the current asynchronous read-modify-write model and resettable validity
array still require technology-specific SRAM mapping before PPA signoff.

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
