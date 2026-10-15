# Pong VGA: transistor budget log

Target: **≤ 4,000 transistors** (GF180 `gf180mcu_fd_sc_mcu7t5v0`, 1×1 tile).

## Current: 3,784 transistors (216 under budget)

| Block | Transistors | Flip-flops | Area (µm²) |
|---|---:|---:|---:|
| `pong_vga_sync`: sync generator | 964 | 22 | 2,665 |
| `pong_game`: paddles, ball, speed-up, scores | 2,468 | 44 | 6,820 |
| `pong_render`: pixel renderer | 416 | 0 | 1,135 |
| top level (8 tie cells for `uio_oe`) | 16 | 0 | 70 |
| **Whole design (flattened, as the TT flow synthesizes it)** | **3,784** | **66** | **10,500** |

The per-block rows are synthesized with the hierarchy kept, so they add up to slightly more than the flattened total.

Approximate split inside `pong_game`: paddles ≈ 830 T, ball ≈ 1,030 T, rally speed-up ≈ 200 T, scores ≈ 340 T.

Flip-flops account for 1,584 T (24 T each, 42% of the total). Cell area is 19.3% of the 54,400 µm² tile. TT places at 60% density, so by area there's roughly 3× headroom; routing is the real limit.

## Video timing block study (Oct 14, 2026)

The timing block (`pong_vga_sync`, now in `src/pong_vga_sync.v`) was checked to see whether it could get smaller. It can't by any amount that matters, so its logic is unchanged. Each version below was synthesized on its own and inside the whole chip:

| Version of the timing block | Block alone (T) | Whole chip (T) |
|---|---:|---:|
| **Current, kept** | **962** | **3,784** |
| Same logic, moved to its own file | 962 | 3,772 |
| hsync decoded from the counter's +1 value; hand-written window tests | 996 | 3,762 |
| Horizontal counter split so its low 5 bits never need clearing | 968 | 3,768 |
| Sync outputs from plain logic instead of flip-flops (20 FFs) | 924 | 3,768 |
| No reset on the counters | 946 | 3,760 |
| Plain `== 799` / `== 524` end-of-line/frame tests | 992 | **3,946** |

- **Where the 962 T go:** 22 flip-flops = 528 T (20 for the counters, 2 for the syncs); the two counters' logic about 370 T; sync decodes and the visible window about 65 T. The two 10-bit counters (with their flip-flops) are 850 T and are already at the minimum for binary counters in this cell library. They have to be binary because the renderer and game use the bits as coordinates. The theoretical minimum is 19 flip-flops (800 × 525 = 420,000 states), so 22 leaves only 3 to remove, and all of them are needed (see below).
- **All the rewrites land within ±25 T,** which is inside ABC's run-to-run noise (moving the same logic into another file alone changed the count by 12 T). None is worth re-verifying the design for.
- **Kept on purpose:** the registered (flip-flop) sync outputs (a sync made from plain logic can spike when several counter bits change at once, and a monitor may count a spike as an extra line) and the counter reset (without it, simulation and gate-level runs see unknown values forever). Each costs under 40 T.
- **The one thing that matters:** the end-of-line/frame tests check only the '1' bits of 799 and 524, exactly like the game logic's own tests. That lets synthesis build them once for both blocks. Writing them as plain comparisons costs **+162 T** for the whole chip. Keep the timing block and the game logic's decodes identical.
- **Speed:** ABC's estimate of the longest path in the whole chip is 5.7 ns (typical corner, no wire delay). It starts at `hcount[2]` and runs through the renderer into the game state. The 50 MHz target allows 20 ns and the real 25.175 MHz clock allows 39.7 ns, so timing is not a concern.

## History

| Version | Change | Transistors | FFs |
|---|---|---:|---:|
| v1 | Direct implementation: ball X/Y registers + comparators, 4×4 px ball | 3,960 | 64 |
| v2 | 8×8 px ball (2-unit comparators); invariant-based constant decodes | 4,078 | 64 |
| v3 | Collision latches removed (renderer sets dx/dy directly); ball_y LSB dropped (parity invariant) | 4,020 | 61 |
| v4 | Ball "motion counters" (Atari 1972 technique) replace ball position registers, up/down adders and comparators | 3,538 | 62 |
| v4.1 | Horizontal move at a fixed time (fixes a double-step at the left edge found by random testing); symmetric out-of-play test | 3,584 | 62 |
| v5 | Rally speed-up: the ball gets faster every 4 paddle hits (4, 6, 8, then 10 px per frame) and resets when someone scores | **3,784** | **66** |

Feature costs measured on v1: scores ≈ 320 T, 8×8 ball (with comparators) +228 T, registered HSYNC/VSYNC ≈ 72 T, paddle "english" ≈ 66 T, walls ≈ 90 T, net ≈ 58 T.

Measured but not built: two on-chip rotary-encoder (quadrature) decoders in place of the buttons cost +252 T with one sampling flip-flop per wire, or +334 T with the safer two. Together with the speed-up that is 3,992–4,088 T, at or over budget, so the encoders are decoded on the MCU, which drives the existing up/down pins.

## How the number is produced

`python3 synth/count_transistors.py --hier --budget 4000 src/project.v`

- Yosys 0.33 with the same pass sequence and ABC script as LibreLane's default synthesis (`SYNTH_STRATEGY "AREA 0"`, which the TT GF180 template config doesn't override), mapped to `gf180mcu_fd_sc_mcu7t5v0` at the typical corner.
- Transistors per cell are counted from each cell's official SPICE (`.cdl`) netlist, e.g. `dffq_1` = 24, `nand2_1` = 4, `xor2_1` = 10, `mux2_1` = 12.
- The count covers post-synthesis logic only. Place-and-route adds clock-tree, hold-fix and repair buffers, plus fill/decap/tap cells. TT's CI uses a newer Yosys/ABC, so expect its counts to differ by a few percent. Treat the GitHub Actions report as authoritative once it exists.
- ABC results shift ±20–40 T between logically equivalent RTL rewrites, so don't read much into changes smaller than that.
- `.github/workflows/transistors.yaml` runs this on every push, writes the table to the run summary, and fails if the total goes over 4,000.
