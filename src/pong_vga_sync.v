/*
 * ECE 298A - Pong VGA: video timing block (owner: Noah Webster)
 *
 * VESA 640x480 @ 60 Hz sync generator for a 25.175 MHz pixel clock.
 *
 *            visible  front porch  sync pulse  back porch   total
 *   pixels     640        16           96          48        800 per line
 *   lines      480        10            2          33        525 per frame
 *
 *   line rate  = 25.175 MHz / 800 = 31.469 kHz
 *   frame rate = 31.469 kHz / 525 = 59.94 Hz
 *   Both syncs are active low (negative polarity), as VESA specifies for
 *   this mode.
 *
 * Outputs to the rest of the chip:
 *   hcount    0..799, the pixel column (0..639 is on screen)
 *   vcount    0..524, the line         (0..479 is on screen)
 *   visible   1 while (hcount, vcount) is inside the 640x480 picture
 *   frame_end 1 for one clock, on the very last pixel of each frame
 *             (hcount 799, vcount 524); the game logic updates on it
 *   hsync     low exactly while hcount = 656..751
 *   vsync     low for lines 490..491 (it switches 1 pixel after the line
 *             starts; that 40 ns offset doesn't matter to a monitor)
 *
 * Size: 962 transistors on its own (22 flip-flops = 528 T, logic = 434 T).
 * Measured against alternatives (Oct 14, 2026); see TRANSISTOR_BUDGET.md:
 *   - The two counters are 850 T of the 962 and are already at the
 *     minimum for binary counters in this cell library. They must be
 *     binary because the renderer and game use hcount/vcount bits as
 *     coordinates.
 *   - The end-of-line/frame tests below look only at the '1' bits of 799
 *     and 524 (see the comment there). The game logic uses the same
 *     tests, so synthesis builds that logic once for both blocks. Writing
 *     them as plain "== 799" / "== 524" costs +162 T for the whole chip.
 *   - Registered (flip-flop) sync outputs cost 16-38 T over plain logic,
 *     and the reset on the counters costs 16-24 T. Both are kept; see
 *     the comments where they are used.
 */

`default_nettype none

module pong_vga_sync (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [9:0] hcount,     // 0..799, pixel column
    output reg  [9:0] vcount,     // 0..524, line
    output reg        hsync,      // active low, registered (glitch-free)
    output reg        vsync,      // active low, registered (glitch-free)
    output wire       visible,    // inside the 640x480 picture
    output wire       frame_end   // 1-clock pulse on the last pixel of the frame
);
  // Back porches (48 px, 33 lines) complete the 800 x 525 totals.
  localparam H_VISIBLE = 640, H_FRONT = 16, H_SYNC = 96;
  localparam V_VISIBLE = 480, V_FRONT = 10, V_SYNC = 2;
  localparam H_SYNC_START = H_VISIBLE + H_FRONT;            // 656
  localparam H_SYNC_END   = H_SYNC_START + H_SYNC;          // 752 (first pixel after)
  localparam V_SYNC_START = V_VISIBLE + V_FRONT;            // 490
  localparam V_SYNC_END   = V_SYNC_START + V_SYNC;          // 492 (first line after)

  // End of line / end of frame. Only the bits that are '1' in 799
  // (11_0001_1111) and 524 (10_0000_1100) are checked: the counters never
  // go above those values, so no other reachable count has all of those
  // bits set. pong_game uses exactly the same tests (line_end, tail), so
  // synthesis shares the gates. Changing them here means changing them
  // there too, or the chip gets ~160 transistors bigger.
  //
  // If a counter ever holds an impossible value (e.g. after a glitch on
  // the supply), it still recovers by itself: from any hcount above 799 a
  // count with bits 9, 8 and 4..0 set comes within 32 clocks, and from any
  // vcount above 524 one with bits 9, 3 and 2 set comes within 16 lines.
  wire h_end = &{hcount[9:8], hcount[4:0]};
  wire v_end = vcount[9] & vcount[3] & vcount[2];

  assign frame_end = h_end & v_end;
  assign visible   = (hcount < H_VISIBLE) && (vcount < V_VISIBLE);

  always @(posedge clk) begin
    // Synchronous reset, folded into the same gate as the end-of-line clear,
    // so it is nearly free. Without it simulation (including the
    // gate-level runs) would see X (unknown) forever.
    if (!rst_n || h_end) hcount <= 10'd0;
    else                 hcount <= hcount + 10'd1;

    if (!rst_n || frame_end) vcount <= 10'd0;
    else                     vcount <= vcount + {9'd0, h_end};

    // Sync outputs come straight from flip-flops. A sync made of plain
    // logic can have tiny spikes ("glitches") when several counter bits
    // change at once, and a monitor can mistake a spike on HSYNC for an
    // extra line. hsync is decoded one pixel early (655..750) so that,
    // after the flip-flop's one-clock delay, it is low exactly for
    // hcount = 656..751.
    hsync <= ~((hcount >= H_SYNC_START - 1) && (hcount < H_SYNC_END - 1));
    vsync <= ~((vcount >= V_SYNC_START) && (vcount < V_SYNC_END));
  end
endmodule
