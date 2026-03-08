# LibreSDR B220 Mini FPGA

FPGA gateware for the LibreSDR B220 Mini (XC7A200T + AD9361 + FX3).
UHD-compatible — reports as USRP B210 (`COMPAT_MAJOR=16`, `COMPAT_MINOR=1`).

## Build

Requires Vivado 2025.2 ML Standard with Artix-7 device support.

```bash
vivado -mode batch -source build.tcl
```

Output: `libresdr_b210.bin` — copy to `$UHD_IMAGES_DIR/usrp_b210_fpga.bin`.

For Docker-based builds (recommended on Apple Silicon), see
[filmil/vivado-docker](https://github.com/filmil/vivado-docker) or the
adapted fork at [gretel/vivado-docker](https://github.com/gretel/vivado-docker)
which adds Rosetta x86_64 workarounds for OrbStack.

### Placement directive

`build.tcl` uses `place_design -directive ExtraTimingOpt` and
`phys_opt_design -directive AggressiveExplore`. This is required for
reproducible placement on XC7A200T — Vivado's default placer is sensitive
to minor constant changes (e.g. version fields) and can produce layouts
that fail on hardware despite meeting timing.

## RTL Audit Fixes

All fixes target the Artix-7 / Vivado 2025.2 toolchain. Upstream Ettus code
was written for Spartan-6 / ISE where some of these issues were latent.

### Clock Domain Crossing

| File | Issue | Fix |
|------|-------|-----|
| `libresdr_b210.v` | `PPS_IN_EXT` used unsynchronized in combinational mux | 2-stage synchronizer into `ref_pll_clk` |
| `libresdr_b210.v` | `sync_10M` crosses `sync_200M` -> `ref_pll_clk` without CDC | 2-stage synchronizer into `ref_pll_clk` |
| `libresdr_b210.v` | `is10meg` (MMCM locked) async to `ref_pll_clk` domain | 2-stage synchronizer into `ref_pll_clk` |
| `libresdr_b210.v` | `ext_ref_locked` crosses `ref_pll_clk` -> `bus_clk` unsynchronized | 2-stage synchronizer into `bus_clk` |
| `b200_core.v` | `pps_ref` crosses `ref_pll_clk` -> `radio_clk` without CDC | 2-stage synchronizer into `radio_clk` |
| `b200_core.v` | `lock_state` / `lock_state_r` missing placement hint | `(* ASYNC_REG = "TRUE" *)` |
| `b205_ref_pll.v` | `refsmp` / `refclksmp` CDC flops missing placement hint | `(* ASYNC_REG = "TRUE" *)` |
| `timekeeper_legacy.v` | PPS edge detector flops missing placement hint | `(* ASYNC_REG = "TRUE" *)` |

### Timing Constraints (XDC)

| File | Issue | Fix |
|------|-------|-----|
| `b210.xdc` | No `create_clock` for external 10 MHz input | `create_clock -period 100.0 [get_ports CLKIN_10MHz]` |
| `b210.xdc` | `PPS_IN_EXT` not constrained | `set_false_path -from [get_ports PPS_IN_EXT]` |
| `b210.xdc` | Two unrelated 200 MHz MMCM outputs not grouped | `set_clock_groups -asynchronous` |
| `b210.xdc` | Synchronizer instances not false-pathed | `set_false_path` to `synchronizer_false_path` pins |

### Combinational Blocking Assignment (COMBDLY)

Non-blocking `<=` in combinational `always @*` blocks changed to blocking `=`.
Vivado may synthesize incorrect logic from the ambiguous `<=` form — the
`radio_ctrl_proc.v` fix is **functionally required** on Artix-7 / Vivado 2025.2
(without it, radio control packets fail).

| File | Assignments fixed |
|------|-------------------|
| `radio_ctrl_proc.v` | 9 (2 blocks) |
| `b200_core.v` | 5 |
| `radio_legacy.v` | 11 |
| `new_rx_control.v` | 17 |
| `chdr_12sc_to_16sc.v` | 7 |
| `chdr_16sc_to_12sc.v` | 7 |
| `chdr_16sc_to_32f.v` | 4 |
| `chdr_32f_to_16sc.v` | 4 |
| `chdr_8sc_to_16sc.v` | 4 |
| `context_packet_gen.v` | 4 |

### Incomplete Case Statements (CASEINCOMPLETE)

| File | Fix |
|------|-----|
| `iic.v` | Added `default` to 2 case blocks |
| `iic_control.v` | Added `default`, cleaned up indentation |
| `ltc2630_spi.v` | Added `default` |
| `serial_to_settings.v` | Added `default` |

### Logic Bugs

| File | Issue | Fix |
|------|-------|-----|
| `chdr_16sc_to_12sc.v` | `q1`/`i1` positive saturation clips at `12'h3FF` (1023) instead of `12'h7FF` (2047) | Changed to `12'h7FF` |
| `cvita_uart.v` | Missing `else` before case statement; spurious semicolon after `begin` | Added `else`, removed semicolon |

## Hardware

![Board](pics/board.jpg)
![Specs](pics/specs.webp)
![Schematic](pics/wiring.webp)
