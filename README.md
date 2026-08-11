# FTLPU-VMODEL

SystemVerilog implementation and verification workspace for the FTLPU LPU.
The architecture is aligned with the sibling `FTLPU-CMODEL` repository's
`refactor/cmodel-architecture` branch.

## Current status

The repository now contains the first functional RTL baseline rather than an
empty shell:

- exact C-model hardware constants and ISA field layouts;
- 132 independent ICU queues with NOP, Repeat, interval, and MEM row stride;
- 4-tile northbound control-wave pipelines;
- byte-stream next-state stages with broadcast consumption;
- tile-local, four-tile, and dual-hemisphere MEM blocks with Read, Write, and
  ReadWrite;
- 14-boundary East/West MEM stream fabrics with passive propagation;
- physical SXM Transpose banks and block-Permute datapaths in both hemispheres;
- shared VXM boundary bridge with integer and initial floating-point datapaths;
- two MXM datapaths with Direct16/INT8 weight buffers, BF16/FP16 Vector and
  Block8 compute, narrow and wide accumulator SRAMs, and stream output/readback;
- C-model-generated golden vectors and VCS end-to-end comparison;
- smoke and functional architecture testbenches.

See [docs/architecture.md](docs/architecture.md) for the queue map, topology,
cycle rules, and remaining datapath work.

## Layout

```text
rtl/core/         Constants, ISA decoders, stream/control primitives
rtl/icu/          Generic queue and 132-queue ICU
rtl/mem/          MEM tile, four-tile column, and dual-hemisphere fabric
rtl/mxm/          MXM control, weight storage, vector compute, and routing
rtl/sxm/          Transpose/Permute control and byte datapath
rtl/vxm/          VXM control, operand orchestration, ALU, math, and routing
rtl/lpu_top.sv    Static-schedule loading and architectural dispatch top
sim/tb/           Smoke and functional architecture tests
sim/cmodel/       C-model golden-vector generators
sim/vectors/      Checked-in differential-test vectors
scripts/          Linux and PowerShell lint/simulation entry points
docs/             Architecture and implementation boundary
```

## Prerequisites

Install at least one supported open-source tool:

- [Verilator](https://verilator.org/) for lint
- [Icarus Verilog](https://steveicarus.github.io/iverilog/) for simulation

## Quick start

Linux/macOS:

```bash
./scripts/lint.sh
./scripts/smoke.sh
```

PowerShell:

```powershell
./scripts/lint.ps1
./scripts/smoke.ps1
```

VCS (the local O-2018.09 installation needs the linker compatibility flag
already included by the script):

```bash
./scripts/vcs.sh
```

Regenerate only the C-model golden vectors:

```bash
./scripts/generate_cmodel_vectors.sh
```

The unit-level architecture test verifies ICU NOP/Repeat timing, signed MEM
repeat stride, and an SRAM Read/Write round trip. The VCS system regression
also verifies mirrored transfers across passive SR hops and a 16-stream,
four-tile `MEM -> SXM Transpose -> Permute -> MEM` round trip. Its complete
416-bit packets, schedule, initialization, and expected SRAM image are emitted
by the sibling C model. A second SXM regression performs a complete 32x32 FP16
transpose using four overlapping input beats and seven non-identity wavefront
Permute maps across all four physical tiles.

The VXM datapath supports exact integer operations over
`StreamInt8`, integral immediates, and prior ALU outputs, with saturated Int8
stream output. Its C-model system regression performs
`MEM.W -> VXM Add -> MEM.E` across all 32 physical lanes. The first floating
stage adds FP16/BF16/FP32 stream unpacking, round-to-nearest-even output
conversion, floating ALU feedback, and Pass/Negate/Abs/Min/Max/ReLU/Cast. A
second C-model regression checks an FP16 ReLU followed by BF16 and FP32 casts
across all 32 lanes. Finite normal/zero FP32 Add/Subtract/Multiply use
round-to-nearest-even and have a separate three-stage C-model differential
test. Floating Divide, Clamp, Square, Sqrt, Exp, Log, subnormals, NaNs, and
float-to-Int8 remain explicit-fault cases.

The VXM RTL is split by hardware responsibility: `lpu_vxm_control` advances
the 16 instruction waves, `lpu_vxm_execute` validates and gathers operands,
`lpu_vxm_alu` is a parameterized lane-execution bank,
`lpu_vxm_result_packer` formats result streams, and
`lpu_vxm_stream_bridge` arbitrates passive crossings and active producers.
`lpu_vxm_slice` owns only feedback/sticky state and composes those blocks;
representation and rounding helpers live in `lpu_vxm_math_pkg`.

The MXM datapath supports full-supercell and per-column Direct16 IW followed by
non-overlapping Vector or Block8 Compute using FP16 or BF16
weights/activations. Its Vector C-model differential regression executes a non-symmetric
32x32 permutation matrix through `MEM -> MXM -> MEM` once per weight buffer in
both BF16 and FP16, checking 128 FP32 results. The two passes use different
permutations and opposite output signs so buffer-selection errors cannot alias.
A per-column C-model regression assembles all 32 weight columns through East
streams 0 and 1, checks cell validity only after eight inner-column writes, and
executes another non-symmetric 32x32 permutation. INT8 IW is paired with the
independent dequant queue, consumes eight full-cell weight streams, multiplies
signed bytes by a BF16 scale, and stores BF16 weights. Its C-model regression
uses distinct positive and negative quantized values/scales across all four
supercells. A module-boundary regression also checks missing or incorrectly
paired dequant instructions and overlapping compute waves. A Block8 C-model
regression consumes 16 activation streams, computes eight independent rows,
checks all 256 BF16 stream results, then checks Block8 SRAM destination and
all 256 FP32 results during retained read, read-clear, and zero-after-clear.
The Vector accumulator C-model regression checks continuous row progression with
non-unit row stride, accumulation after a new wave, retained AccumulatorRead,
read-clear, and zero-after-clear across all 32 columns. Overlapping compute
waves remain intentionally unsupported. SXM
ShiftSelect and Distribute remain intentionally unimplemented.

## Conventions

- Use SystemVerilog (`.sv` / `.svh`) for design and verification.
- Use active-low asynchronous reset named `rst_ni`.
- Use `_i`, `_o`, and `_io` suffixes for ports.
- Keep synthesizable RTL under `rtl/` and verification-only code under `sim/`.
- Add source files to `sim/filelist.f` in dependency order.
- Do not commit generated simulation output or waveforms.
- Keep compiler and EDA output under `build/`, and point tool scratch variables
  at `build/tmp/`; project workflows must not place generated artifacts outside
  the repository.
