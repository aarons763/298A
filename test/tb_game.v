`default_nettype none
`timescale 1ns / 1ps

/* Testbench for the game logic on its own (pong_game), used by test_game.py.

   In the full chip, frame_end pulses once every 420,000 clocks. Here Python
   drives frame_end directly, so one game frame takes only a few clocks and a
   long rally simulates in seconds. Run it with:  make -f Makefile.game
*/
module tb_game ();

  // Record every signal into tb_game.fst for GTKWave / Surfer.
  initial begin
    $dumpfile("tb_game.fst");
    $dumpvars(0, tb_game);
    #1;
  end

  // Inputs, driven from Python
  reg clk;
  reg rst_n;
  reg frame_end;
  reg [4:0] btn;  // {serve, p2_down, p2_up, p1_down, p1_up}

  // Outputs of the game logic
  wire [13:0] ball_x;  // Q4: 16 steps per pixel
  wire [12:0] ball_y;
  wire [8:0] pad1_y, pad2_y;  // top edge of each paddle, whole pixels
  wire [3:0] score1, score2;

  // The same values in whole pixels, easier to read in the waveform.
  wire [9:0] ball_px = ball_x[13:4];
  wire [8:0] ball_py = ball_y[12:4];

  pong_game game (
      .clk(clk),
      .rst_n(rst_n),
      .frame_end(frame_end),
      .btn(btn),
      .ball_x(ball_x),
      .ball_y(ball_y),
      .pad1_y(pad1_y),
      .pad2_y(pad2_y),
      .score1(score1),
      .score2(score2)
  );

endmodule
