# FTLPU-VMODEL

SystemVerilog implementation and verification workspace for the FTLPU LPU.

The repository currently contains a minimal compilable shell. The LPU
microarchitecture and external interface should be defined before functional
RTL is added.

## Layout

```text
rtl/              Synthesizable SystemVerilog RTL
sim/filelist.f    Ordered source list used by simulation and lint
sim/tb/           Testbenches
scripts/          Local lint and simulation entry points
```

## Prerequisites

Install at least one supported open-source tool:

- [Verilator](https://verilator.org/) for lint
- [Icarus Verilog](https://steveicarus.github.io/iverilog/) for the smoke test

Ensure `verilator` and/or `iverilog` are available on `PATH`.

## Quick start

From the repository root:

```powershell
./scripts/lint.ps1
./scripts/smoke.ps1
```

The smoke test only validates that the repository skeleton compiles and that
reset can be applied. It is not a functional LPU test.

## Conventions

- Use SystemVerilog (`.sv` / `.svh`) for all new design files.
- Use active-low asynchronous reset named `rst_ni` unless the block
  specification requires otherwise.
- Use `_i`, `_o`, and `_io` suffixes for input, output, and bidirectional ports.
- Keep synthesizable RTL under `rtl/`; keep verification-only code under
  `sim/`.
- Add source files to `sim/filelist.f` in dependency order.
- Do not commit generated simulation or waveform files.

