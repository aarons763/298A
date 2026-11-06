## How it works

This design implements two-player Pong with 640 by 480 VGA output. A 25.175 MHz input clock and 800 by 525 total raster clocks produce approximately 59.94 frames per second. The game updates once per frame in vertical blanking; it does not need a frame buffer.

Ball positions retain 1/16-pixel fractions and are rendered at one-pixel resolution. Paddle contact selects an angle between 10 and 45 degrees from horizontal, mirrored above and below the paddle midpoint. A constant velocity table approximates normalized speeds of 4, 6, 8, and 10 pixels per frame. The speed rises every three paddle hits, saturates after nine, and resets when a point is scored. Paddles move 12 pixels per frame and stop at the walls.

The ball is 8 by 8 pixels and each paddle is 8 by 64 pixels. Four-bit player scores wrap from 15 to 0 and are exposed on the bidirectional pins, configured as outputs. The design occupies one GF180 tile; physical fit is checked by the GDS and precheck flows.

## How to test

Provide a 25.175 MHz clock, assert `rst_n` low for several clock edges, then release it high. The ball remains at the center until `ui_in[4]` is high at a frame boundary. Holding that input high automatically serves again after each point.

Use `ui_in[0]` and `ui_in[1]` for player 1 up/down, and `ui_in[2]` and `ui_in[3]` for player 2 up/down. Inputs are active high. Holding both directions for one player stops that paddle. Read player 1's score on `uio_out[3:0]` and player 2's on `uio_out[7:4]`.

To simulate in VGA Playground, load the repository or paste `src/project.v` followed by `src/pong_vga_sync.v` into the editor. Keys 0 through 4 toggle inputs; R resets. The Playground FPS indicator measures browser presentation speed rather than the circuit's VGA timing.

Local tests include `cd test && make` for VGA timing, `sh sim/run.sh 1600 rally` for pixel/reference checks, and the directed Icarus test in `sim/tb_features.v`. The GitHub workflow also runs GDS, Tiny Tapeout precheck, and gate-level timing tests.

## External hardware

Use a TinyVGA Pmod and a VGA monitor. Dedicated outputs use the TinyVGA mapping: bit 0 R1, bit 1 G1, bit 2 B1, bit 3 VSYNC, bit 4 R0, bit 5 G0, bit 6 B0, and bit 7 HSYNC. HSYNC and VSYNC are active low.

Buttons or an external microcontroller drive the four movement inputs and serve input. Rotary encoders must be decoded externally into these inputs; a one-frame movement pulse moves a paddle 12 pixels. All bidirectional pins are score outputs and must not be driven externally.
