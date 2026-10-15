/*
 * ECE 298A - Pong VGA (Tiny Tapeout, GF180 1x1 tile)
 * Team: Noah Webster, Aaron Sun
 *
 * Three blocks:
 *   pong_vga_sync  - VESA 640x480 @ 60 Hz sync generator (25.175 MHz pixel clock)
 *   pong_game      - paddles, ball, bounces, scores; moves once per frame
 *   pong_render    - purely combinational pixel renderer (no frame buffer)
 *
 * Game grid: 1 unit = 4x4 pixels, so the playfield is 160 x 120 units.
 * Flip-flops dominate the area budget, so every state bit is justified below.
 *
 * Inputs : ui_in[0] P1 up, [1] P1 down, [2] P2 up, [3] P2 down, [4] serve
 * Outputs: uo_out = TinyVGA Pmod; uio_out = {P2 score, P1 score} (0-15 each)
 */

`default_nettype none

module tt_um_aarons763_pong_vga (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock (25.175 MHz pixel clock)
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------- sync
  wire [9:0] hcount, vcount;
  wire       hsync, vsync, visible, frame_end;

  pong_vga_sync sync_gen (
      .clk      (clk),
      .rst_n    (rst_n),
      .hcount   (hcount),
      .vcount   (vcount),
      .hsync    (hsync),
      .vsync    (vsync),
      .visible  (visible),
      .frame_end(frame_end)
  );

  // ---------------------------------------------------------------- game
  wire [7:0] ball_hc;
  wire [6:0] ball_vc, pad1_y, pad2_y;
  wire [3:0] score1, score2;
  wire       pad_hit, pad_lower;

  pong_game game (
      .clk      (clk),
      .rst_n    (rst_n),
      .hcount   (hcount),
      .vcount   (vcount),
      .frame_end(frame_end),
      .btn      (ui_in[4:0]),
      .pad_hit  (pad_hit),
      .pad_lower(pad_lower),
      .ball_hc  (ball_hc),
      .ball_vc  (ball_vc),
      .pad1_y   (pad1_y),
      .pad2_y   (pad2_y),
      .score1   (score1),
      .score2   (score2)
  );

  // ---------------------------------------------------------------- render
  wire [1:0] R, G, B;

  pong_render render (
      .hcount   (hcount),
      .vcount   (vcount),
      .visible  (visible),
      .ball_hc  (ball_hc),
      .ball_vc  (ball_vc),
      .pad1_y   (pad1_y),
      .pad2_y   (pad2_y),
      .pad_hit  (pad_hit),
      .pad_lower(pad_lower),
      .R        (R),
      .G        (G),
      .B        (B)
  );

  // TinyVGA Pmod pinout
  assign uo_out  = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};

  // Scores on the bidirectional pins so the demo board (RP2040) can read them.
  // (A score register that drove no output would be deleted by synthesis.)
  assign uio_out = {score2, score1};
  assign uio_oe  = 8'hFF;

  wire _unused = &{ena, ui_in[7:5], uio_in, 1'b0};

endmodule

// =====================================================================
// VESA 640x480 @ 60 Hz sync generator
// =====================================================================
module pong_vga_sync (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [9:0] hcount,     // 0..799, pixel column
    output reg  [9:0] vcount,     // 0..524, line
    output reg        hsync,      // active low, registered (glitch-free)
    output reg        vsync,      // active low, registered (glitch-free)
    output wire       visible,    // inside the 640x480 active area
    output wire       frame_end   // 1-cycle pulse on the last pixel of the frame
);
  // Back porches (48 px, 33 lines) complete the 800 x 525 totals.
  localparam H_VISIBLE = 640, H_FRONT = 16, H_SYNC = 96;
  localparam V_VISIBLE = 480, V_FRONT = 10, V_SYNC = 2;
  localparam H_SYNC_START = H_VISIBLE + H_FRONT;            // 656
  localparam H_SYNC_END   = H_SYNC_START + H_SYNC;          // 752 (exclusive)
  localparam V_SYNC_START = V_VISIBLE + V_FRONT;            // 490
  localparam V_SYNC_END   = V_SYNC_START + V_SYNC;          // 492 (exclusive)

  // End-of-line / end-of-frame detect. Only the bits that are '1' in 799
  // (11_0001_1111) and 524 (10_0000_1100) are checked: because the counters
  // never exceed those values, no other count has all of those bits set.
  wire h_end = &{hcount[9:8], hcount[4:0]};
  wire v_end = vcount[9] & vcount[3] & vcount[2];

  assign frame_end = h_end & v_end;
  assign visible   = (hcount < H_VISIBLE) && (vcount < V_VISIBLE);

  always @(posedge clk) begin
    if (!rst_n || h_end) hcount <= 10'd0;
    else                 hcount <= hcount + 10'd1;

    if (!rst_n || frame_end) vcount <= 10'd0;
    else                     vcount <= vcount + {9'd0, h_end};

    // Registered syncs. hsync is decoded one pixel early so that it lines up
    // exactly with hcount (low for hcount = 656..751). vsync is low for
    // lines 490..491 (one pixel late, which is irrelevant for vsync).
    hsync <= ~((hcount >= H_SYNC_START - 1) && (hcount < H_SYNC_END - 1));
    vsync <= ~((vcount >= V_SYNC_START) && (vcount < V_SYNC_END));
  end
endmodule

// =====================================================================
// Game state.
//
// Paddles are ordinary position registers (top row, in 4-px units).
//
// The ball uses "motion counters", the technique of Atari's 1972 Pong
// board: instead of storing X/Y and comparing them with the beam, two
// counters run in step with the beam and the ball is drawn while both read
// 0 or 1. ball_hc counts 4-px units along every line (200 per line) and
// ball_vc counts 4-line rows down the visible frame (120 per frame), so:
//     ball_hc = (beam_x_unit - ball_x) mod 200
//     ball_vc = (beam_y_row  - ball_y) mod 120
// Adding or dropping one count once per frame moves the ball one unit
// left/right (up/down). This replaces two position registers,
// two up/down adders and the renderer's ball comparators with two
// incrementers and a handful of constant decodes.
// =====================================================================
module pong_game (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [9:0] hcount,
    input  wire [9:0] vcount,
    input  wire       frame_end,  // once-per-frame update strobe
    input  wire [4:0] btn,        // {serve, p2_down, p2_up, p1_down, p1_up}
    input  wire       pad_hit,    // renderer: a ball pixel overlaps a paddle pixel
    input  wire       pad_lower,  // renderer: ...in the lower half of that paddle
    output reg  [7:0] ball_hc,    // horizontal motion counter, 0..199
    output reg  [6:0] ball_vc,    // vertical motion counter, 0..120
    output reg  [6:0] pad1_y,     // top of left paddle, 2..102
    output reg  [6:0] pad2_y,     // top of right paddle, 2..102
    output reg  [3:0] score1,
    output reg  [3:0] score2
);
  localparam [6:0] PAD_START = 7'd52;   // rows 52..67 (centred)
  // Serve position: ball_x = 79, ball_y = 59 (pixels 316..323 x 236..243).
  // Values the counters must hold at the start of a frame for that:
  localparam [7:0] HC_SERVE = 8'd121;   // (0 - 79) mod 200
  localparam [6:0] VC_SERVE = 7'd61;    // (0 - 59) mod 120

  wire tick = frame_end;

  // -------------------------------------------------- paddles
  // Up/down counters kept between the walls (rows 2..117, 16 rows tall).
  // pad_y stays within [2, 102], so the edge tests only need these bits:
  //   2   = 000_0010 is the only value with bits 6..2 = 0 and bit 0 = 0
  //   102 = 110_0110 is the only value with bits 6, 5, 2, 1 set
  // Holding both buttons = no move.
  wire p1_top = ~|{pad1_y[6:2], pad1_y[0]};
  wire p2_top = ~|{pad2_y[6:2], pad2_y[0]};
  wire p1_bot = &{pad1_y[6:5], pad1_y[2:1]};
  wire p2_bot = &{pad2_y[6:5], pad2_y[2:1]};
  wire p1_up = tick & btn[0] & ~btn[1] & ~p1_top;
  wire p1_dn = tick & btn[1] & ~btn[0] & ~p1_bot;
  wire p2_up = tick & btn[2] & ~btn[3] & ~p2_top;
  wire p2_dn = tick & btn[3] & ~btn[2] & ~p2_bot;

  always @(posedge clk) begin
    if (!rst_n) begin
      pad1_y <= PAD_START;
      pad2_y <= PAD_START;
    end else begin
      // +1, -1 (= +127) or +0; the "hold" case needs no extra mux
      pad1_y <= pad1_y + {{6{p1_up}}, p1_up | p1_dn};
      pad2_y <= pad2_y + {{6{p2_up}}, p2_up | p2_dn};
    end
  end

  // -------------------------------------------------- ball
  reg dx;       // 1 = moving right
  reg dy;       // 1 = moving down
  reg serving;  // ball parked at the centre until SERVE

  wire unit_end = &hcount[1:0];                         // last pixel of a 4-px unit
  wire line_end = &{hcount[9:8], hcount[4:0]};          // hcount == 799
  wire row_end  = line_end & (&vcount[1:0]) &           // last line of a visible
                  ~vcount[9] & ~(&vcount[8:5]);         // 4-line row (vcount < 480)
  // hcount 792..799 on line 524 (vblank); hcount <= 799, so bits 9,8,4,3
  // being set is enough to place us in 792..799.
  wire tail     = vcount[9] & vcount[3] & vcount[2] &
                  hcount[9] & hcount[8] & hcount[4] & hcount[3];

  // Horizontal move, once per frame just before frame_end: to move right,
  // skip the increment at hcount 795 (end of unit 198); to move left, add an
  // extra increment at hcount 797 (mid unit 199). Both are off-screen.
  wire stall   = tail & ~hcount[2] &  hcount[1] & hcount[0] & ~serving &  dx;
  wire extra   = tail &  hcount[2] & ~hcount[1] & hcount[0] & ~serving & ~dx;
  wire hc_step = (unit_end & ~stall) | extra;

  // Wrap-point decodes. ball_hc stays within [0, 199] and ball_vc within
  // [0, 120], so each constant only needs its '1' bits (and 118 is reached
  // before 119, so its extra match doesn't matter).
  wire hc_199 = &{ball_hc[7:6], ball_hc[2:0]};          // 1100_0111
  wire vc_119 = &{ball_vc[6:4], ball_vc[2:0]};          // 111_0111
  wire vc_118 = &{ball_vc[6:4], ball_vc[2:1]};          // 111_0110
  wire vc_120 = &ball_vc[6:3];                          // 111_1000

  // Vertical move: ball_vc wraps once per frame (120 rows), on the row just
  // above the ball, so wrapping one row early/late moves the ball up/down
  // before it is drawn (no tearing). The walls keep ball_y in [2, 116], so
  // that wrap row is always on screen and there is exactly one per frame.
  wire vc_wrap = ~serving ? (dy ? vc_120 : vc_118) : vc_119;

  // Checked at frame_end (after this frame's horizontal move), when ball_hc
  // holds its value for unit 199,
  // (199 - ball_x) mod 200, and ball_vc holds (0 - ball_y) mod 120:
  //   out    : ball_x in 160..199, i.e. it went past a paddle (ball_hc < 40)
  //   at_top : ball_y == 2   (ball_vc == 118 = 111_0110; ball_vc is 4..118)
  //   at_bot : ball_y == 116 (ball_vc == 4   = 000_0100)
  wire out    = ~|ball_hc[7:6] & ~(ball_hc[5] & (ball_hc[4] | ball_hc[3]));
  wire at_top = &{ball_vc[6:4], ball_vc[2:1]};
  wire at_bot = ~|{ball_vc[6:3], ball_vc[1:0]};

  wire point  = tick & out;
  wire park   = ~rst_n | (tick & (serving | out));      // (re)centre the ball

  always @(posedge clk) begin
    if (park)
      ball_hc <= HC_SERVE;
    else if (hc_step)
      ball_hc <= hc_199 ? 8'd0 : ball_hc + 8'd1;

    if (park)
      ball_vc <= VC_SERVE;
    else if (row_end)
      ball_vc <= vc_wrap ? 7'd0 : ball_vc + 7'd1;

    // Direction bits are not used for drawing, so paddle hits reported by the
    // renderer (pixel overlap of ball and paddle) update them immediately,
    // mid-frame. A hit always sends the ball away from that paddle (so it
    // can't get stuck inside it) and steers it by the half it touched.
    // Wall bounces are applied at frame_end.
    if (!rst_n) begin
      dx <= 1'b1;
      dy <= 1'b1;
    end else if (pad_hit) begin
      dx <= ~hcount[9];          // left half of the screen -> go right
      dy <= pad_lower;
    end else if (tick & at_top) begin
      dy <= 1'b1;
    end else if (tick & at_bot) begin
      dy <= 1'b0;
    end

    if (!rst_n)    serving <= 1'b1;
    else if (tick) serving <= out | (serving & ~btn[4]);
  end

  // -------------------------------------------------- scores
  always @(posedge clk) begin
    if (!rst_n) begin
      score1 <= 4'd0;
      score2 <= 4'd0;
    end else begin
      score1 <= score1 + {3'd0, point & dx};    // ball left on the right: P1 scores
      score2 <= score2 + {3'd0, point & ~dx};   // ball left on the left:  P2 scores
    end
  end

  wire _unused = &{hcount[7:5], vcount[4], 1'b0};
endmodule

// =====================================================================
// Pixel renderer: purely combinational, computes each pixel from the beam
// position and the game state. Priority: ball/paddles > net/walls > bg.
// =====================================================================
module pong_render (
    input  wire [9:0] hcount,
    input  wire [9:0] vcount,
    input  wire       visible,
    input  wire [7:0] ball_hc,
    input  wire [6:0] ball_vc,
    input  wire [6:0] pad1_y,
    input  wire [6:0] pad2_y,
    output wire       pad_hit,
    output wire       pad_lower,
    output wire [1:0] R,
    output wire [1:0] G,
    output wire [1:0] B
);
  localparam [6:0] PAD1_COL = 7'd2;    // x = 16..23 (8-pixel columns)
  localparam [6:0] PAD2_COL = 7'd77;   // x = 616..623
  localparam [6:0] NET_COL  = 7'd80;   // x = 320..323 (4-pixel units)

  wire [7:0] xu = hcount[9:2];        // 4-pixel units
  wire [6:0] yu = vcount[8:2];

  // ball: 2x2 units (8x8 px) where both motion counters read 0 or 1
  wire ball = ~|{ball_hc[7:1], ball_vc[6:1]};

  // paddles: the two paddles are never on the same column, so they share one
  // subtractor; hcount[9] tells which half of the screen we are in.
  wire       pad_col = (hcount[9:3] == PAD1_COL) || (hcount[9:3] == PAD2_COL);
  wire [6:0] pad_top = hcount[9] ? pad2_y : pad1_y;
  wire [6:0] pad_d   = yu - pad_top;                    // row within paddle
  wire       paddle  = pad_col && (pad_d[6:4] == 3'd0); // 0 <= pad_d < 16

  // Visible pixels have xu <= 159 and yu <= 119 (everything below is gated
  // by 'visible'), so these decodes skip bits that can't differ.
  wire net  = (xu[6:0] == NET_COL) && vcount[4];        // xu == 80, dashed
  wire wall = (yu[6:1] == 6'd0) ||                      // rows 0-1
              (&{yu[6:4], yu[2:1]});                    // rows 118-119

  assign pad_hit   = visible && ball && paddle;
  assign pad_lower = pad_d[3];

  wire white = visible && (ball || paddle);
  wire grey  = visible && (net || wall);

  assign R = {white, white | grey};
  assign G = {white, white | grey};
  assign B = {white, white | grey};

  wire _unused = &{hcount[1:0], vcount[9], vcount[3:0], pad_d[2:0], xu[7],
                   ball_hc[0], ball_vc[0], 1'b0};
endmodule
