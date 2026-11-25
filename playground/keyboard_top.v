/*
 * ECE 298A Pong VGA (Engineering 5 at sunset) - VGA Playground version
 *
 * HOW TO RUN
 *   1. Open https://vga-playground.com/?preset=gamepad
 *   2. In the project.v tab, select all (Ctrl+A) and replace it with this file,
 *      followed by src/project.v and then src/pong_vga_sync.v (one after the
 *      other in the same tab). Leave the other tabs (gamepad_pmod.v,
 *      hvsync_generator.v) as they are: this file uses gamepad_pmod.v.
 *   3. Click the gamepad button under the ui_in bits to turn on Gamepad mode.
 *   4. Click the picture once so the page gets your key presses.
 *
 * CONTROLS (hold the key down; let go to stop)
 *   Player 1, left paddle:  Up arrow / Down arrow
 *   Player 2, right paddle: Y (up) / B (down)
 *   Serve:                  A  (or T, the Start button)
 *   Reset:                  Shift+R
 *
 * Without Gamepad mode the old way still works: ui_in bits 0/1 = player 1
 * up/down, 2/3 = player 2 up/down, 7 = serve (each press toggles the bit).
 *
 * This wrapper exists only for the playground. The chip itself
 * (tt_um_aarons763_pong_vga in src/project.v) reads plain
 * buttons on ui_in[4:0]: 0/1 P1 up/down, 2/3 P2 up/down, 4 serve.
 */
`default_nettype none

module tt_um_pong_playground (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
  // The playground sends the keyboard as a Gamepad Pmod on ui_in[6:4].
  wire pad_b, pad_y, pad_select, pad_start, pad_up, pad_down;
  wire pad_left, pad_right, pad_a, pad_x, pad_l, pad_r, pad_present;
  gamepad_pmod_single gamepad (
      .rst_n(rst_n), .clk(clk),
      .pmod_data(ui_in[6]), .pmod_clk(ui_in[5]), .pmod_latch(ui_in[4]),
      .b(pad_b), .y(pad_y), .select(pad_select), .start(pad_start),
      .up(pad_up), .down(pad_down), .left(pad_left), .right(pad_right),
      .a(pad_a), .x(pad_x), .l(pad_l), .r(pad_r), .is_present(pad_present)
  );

  // Map keys onto the chip's button pins.
  wire [7:0] buttons = {3'b000,
                        pad_a | pad_start | ui_in[7], // serve
                        pad_b | ui_in[3],             // player 2 down
                        pad_y | ui_in[2],             // player 2 up
                        pad_down | ui_in[1],          // player 1 down
                        pad_up | ui_in[0]};           // player 1 up

  tt_um_aarons763_pong_vga pong (
      .ui_in(buttons), .uo_out(uo_out),
      .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
      .ena(ena), .clk(clk), .rst_n(rst_n)
  );

  wire _unused = &{pad_select, pad_left, pad_right, pad_x, pad_l, pad_r, pad_present, 1'b0};
endmodule
