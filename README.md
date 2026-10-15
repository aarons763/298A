# Pong VGA (ECE 298A, Tiny Tapeout GF180 1×1)

A two-player Pong game for Tiny Tapeout, output on the TinyVGA Pmod at 640×480 @ 60 Hz. The ball speeds up the longer a rally lasts. It synthesizes to **3,784 transistors**, against a 4,000 budget. See `TRANSISTOR_BUDGET.md` for the tally and history.

| Path | What it is |
|---|---|
| `src/project.v` | Top `tt_um_aarons763_pong_vga`, `pong_game` (Aaron), `pong_render` (Noah) |
| `src/pong_vga_sync.v` | Video timing block `pong_vga_sync` (Noah) |
| `test/test_vga_sync.py` | cocotb tests for the video timing, checked on the output pins (`cd test && make`) |
| `info.yaml` | TT metadata (top module, 25.175 MHz clock, pinout) for the repo root |
| `synth/count_transistors.py` | GF180 transistor/area counter (`--hier`, `--budget 4000`); pass both source files |
| `synth/build_gf180_lib.py` | One-time download of the GF180 cell library data the counter needs |
| `.github/workflows/transistors.yaml` | CI job that reports the count on every push and fails over budget |
| `sim/tb.cpp`, `sim/run.sh` | Verilator checker: each frame is compared pixel by pixel with a C++ reference model; also checks VESA timing and scores |
| `TRANSISTOR_BUDGET.md` | Budget log |

## Pins

- `ui_in[0]` P1 up, `[1]` P1 down, `[2]` P2 up, `[3]` P2 down, `[4]` serve.
- `uo_out`: TinyVGA Pmod (R1 G1 B1 VSYNC R0 G0 B0 HSYNC).
- `uio_out[3:0]` P1 score, `uio_out[7:4]` P2 score (0–15, wraps). All `uio` pins are outputs.
- Rotary encoders: decode them on the MCU and drive `ui_in[3:0]` like buttons. The paddle moves 1 unit (4 px) for every frame a pin is held high, so hold the pin for one frame (about 17 ms) per knob click. Decoding on the chip was measured at +250 to +330 transistors, which doesn't fit alongside the speed-up.

## VGA Playground

- **Now:** open https://vga-playground.com and replace the contents of the `project.v` tab with `src/project.v` followed by `src/pong_vga_sync.v` (paste one after the other). It recompiles automatically.
- **After pushing to the repo** (with this `info.yaml`): https://vga-playground.com/?repo=https://github.com/aarons763/298A
- **Controls:** keys `0`–`4` (or the ui_in buttons) *toggle* input bits; they aren't momentary. Turn `4` on to serve; leaving it on auto-serves after every point. `0`/`1` move P1 up/down until pressed again, and `2`/`3` do the same for P2. `R` resets.

## Design notes

- **Grid.** 1 unit = 4×4 px, so the playfield is 160×120 units. Paddles are 2×16 units, the ball is 2×2 units (8×8 px), and the walls are 2 units thick.
- **Ball motion counters.** This is the Atari 1972 Pong technique. `ball_hc` counts 4-px units along every line (200 per line) and `ball_vc` counts rows down the visible frame (120 per frame). The ball is drawn when both read 0 or 1. Once per frame, one count is dropped or added to move the ball one unit. This removes the ball X/Y registers, their up/down adders and the renderer's comparators (about 440 T saved net).
- **Rally speed-up.** A 4-bit counter (`hits`) counts paddle hits in the current rally and stops at 15; every 4 hits the ball gets faster: 1, 1.5, 2, then 2.5 units per frame across the screen (240 to 600 px/s). Extra steps are extra count-drops/adds on line 524, at most 3 per frame so the ball can't skip over a paddle. Up-down speed stays 1 unit per frame, so fast shots come in flatter. Scoring resets the speed.
- **Collisions are pixel-accurate.** The renderer flags when a ball pixel overlaps a paddle pixel. That sets `dx` to point away from the paddle and `dy` from which half was hit ("english"). Walls and out-of-play are checked at frame end from the counter values.
- **Cheap constant decodes.** Several comparisons check only the '1' bits of a constant, because the counter can never exceed that value. Each one is commented with the invariant it relies on.
- **Synchronous reset only.** HSYNC and VSYNC are registered (glitch-free), and HSYNC lines up exactly with hcount 656–751.

## Status

- Lint-clean under Verilator `-Wall` (as the Playground requires) and compiles under Icarus.
- Runs in the VGA Playground.
- The Verilator checker passed 22,000 frames of this version (AI rallies up to top speed, a player missing at top speed, missed balls, random button mashing) with zero pixel mismatches, plus 1,800 frames of the synthesized gate netlist.
- **Video timing tests (Oct 14):** `test/test_vga_sync.py` checks the pins against the VESA table to the exact clock (5 tests: line timing pixel by pixel, frame timing, reset mid-frame, recovery from impossible counter values, rate calculations). All pass on the RTL and on a GF180 gate-level netlist. Each of 4 deliberately injected timing bugs makes them fail.
- **Still needed:** game-logic cocotb tests (`test/test.py` is still the template). Add the module to `COCOTB_TEST_MODULES` in `test/Makefile`.
