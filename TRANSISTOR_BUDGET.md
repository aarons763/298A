# Pong VGA: transistor budget log

Acceptance: **successful GDS, precheck, and gate-level flow for the 1x1 tile**. The previous 4,000-transistor target was an estimate, not a fabrication limit. Counts below are diagnostic or historical.

## Current: subpixel motion, normalized speed, 10-45 degree angles

Preliminary local Yosys 0.52 estimate: **8,680 transistors, 1,137 cells, 85 flip-flops, 24,163 square micrometers**, or 44.4% of nominal 1x1 tile area. Actual acceptance comes from the GitHub GDS/precheck/gate-level jobs, not this percentage alone. Tile dimensions, process, and target density are unchanged. CLOCK_PERIOD is 39.7 ns to match the actual 25.175 MHz VGA clock, replacing the template 20 ns / 50 MHz constraint.

The former motion-counter shortcuts are replaced with Q4 ball coordinates, whole-pixel paddle coordinates, a small 32-entry velocity lookup, and swept horizontal paddle crossing checks. This uses the available area to improve motion and collisions. The transistor CI job now reports count and area without failing at 4,000. Simulation/synthesis errors still fail, and GDS checks are not bypassed.

## Historical revision 2: 3,958 transistors (42 margin against former target)

Hit-based acceleration, angle-preserving shared-axis motion, four contact angle bands, and paddles averaging 3x their original speed. With Yosys 0.52 and the repository AREA 0 flow: **3,958 transistors, 445 cells, 69 flip-flops, 10,926 square micrometers** (20.1% of nominal tile area).

Speed rises by 2 dominant-axis pixels/frame at contacts 3, 6, and 9, from 4 to 10. One saturating four-bit counter replaces the timer. A two-bit pattern counter drives the minor axis at 1/4 or 3/4 of the major axis; swapping axes produces four angle magnitudes from 14 to 76 degrees. This preserves the trajectory ratio as speed changes. Vertical movement is now performed in blanking with per-substep wall direction checks.

Each paddle uses a six-bit position in 8-pixel units. Alternating one/two updates per frame yields 12 pixels/frame average, clamped at the existing bounds. Keeping exact 12-pixel increments with seven-bit paddle registers measured over budget in the tested mappings. The decorative net remains absent.

The VGA horizontal counter's low bit is split from the upper nine. Because the terminal count (799) is odd, the low bit's normal toggle clears it at line end. Yosys equivalence checking proved all 26 equivalence points against the original sync module, including the registered outputs. The five original VGA tests also pass.

Development measurements: the initial implementation was 4,158 transistors; a single saturating hit counter and cheaper fractional stepping reduced it to about 4,100. Compact paddle positions plus the split sync counter brought it under budget. The final source above is the delivered measurement; mapping counts can shift even for equivalent RTL expressions.

The previous delivered timed-acceleration version measured 4,000 with 73 flip-flops. The original Git checkout measured 3,878 on this toolchain; the older 3,784 figure below used a different toolchain.

CI must confirm the count with its Yosys/ABC version. Synthesis does not establish routed tile fit; post-route clock/repair cells are additional. This revision has not been hardened or simulated as a new gate-level netlist.

## Previous version: 3,784 transistors (historical toolchain)

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

## Historical counting procedure (4,000-transistor policy since removed)

`python3 synth/count_transistors.py --hier --budget 4000 src/project.v src/pong_vga_sync.v`

- Yosys 0.33 with the same pass sequence and ABC script as LibreLane's default synthesis (`SYNTH_STRATEGY "AREA 0"`, which the TT GF180 template config doesn't override), mapped to `gf180mcu_fd_sc_mcu7t5v0` at the typical corner.
- Transistors per cell are counted from each cell's official SPICE (`.cdl`) netlist, e.g. `dffq_1` = 24, `nand2_1` = 4, `xor2_1` = 10, `mux2_1` = 12.
- The count covers post-synthesis logic only. Place-and-route adds clock-tree, hold-fix and repair buffers, plus fill/decap/tap cells. TT's CI uses a newer Yosys/ABC, so expect its counts to differ by a few percent. Treat the GitHub Actions report as authoritative once it exists.
- ABC results shift ±20–40 T between logically equivalent RTL rewrites, so don't read much into changes smaller than that.
- `.github/workflows/transistors.yaml` runs this on every push, writes the table to the run summary, and fails if the total goes over 4,000.
