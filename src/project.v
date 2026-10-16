/* Pong VGA: pixel-resolution rendering and Q4 subpixel physics.
 * 25.175 MHz / (800*525) = 59.940476 Hz. Gameplay advances once per frame.
 * Pins and 1x1 GF180 tile are unchanged. No frame buffer or derived clocks.
 */
`default_nettype none
module tt_um_aarons763_pong_vga (
    input wire [7:0] ui_in, output wire [7:0] uo_out,
    input wire [7:0] uio_in, output wire [7:0] uio_out,
    output wire [7:0] uio_oe, input wire ena, clk, rst_n
);
  wire [9:0] hcount, vcount;
  wire hsync, vsync, visible, frame_end;
  pong_vga_sync sync_gen(clk,rst_n,hcount,vcount,hsync,vsync,visible,frame_end);
  wire [13:0] ball_x;
  wire [12:0] ball_y;
  wire [8:0] pad1_y,pad2_y;
  wire [3:0] score1,score2;
  pong_game game(clk,rst_n,frame_end,ui_in[4:0],ball_x,ball_y,pad1_y,pad2_y,score1,score2);
  wire [1:0] R,G,B;
  pong_render render(hcount,vcount,visible,ball_x[13:4],ball_y[12:4],pad1_y,pad2_y,R,G,B);
  assign uo_out={hsync,B[0],G[0],R[0],vsync,B[1],G[1],R[1]};
  assign uio_out={score2,score1};
  assign uio_oe=8'hff;
  wire _unused=&{ena,ui_in[7:5],uio_in,ball_x[3:0],ball_y[3:0],1'b0};
endmodule

module pong_game (
    input wire clk,rst_n,frame_end,
    input wire [4:0] btn,
    output reg [13:0] ball_x, // Q4: sixteen subpixels per pixel
    output reg [12:0] ball_y,
    output reg [8:0] pad1_y,pad2_y, // whole pixels
    output reg [3:0] score1,score2
);
  reg dx,dy; // right/down
  reg serving;
  reg [3:0] hits; // saturates at 9: tiers 4,6,8,10 pixels/frame
  reg [2:0] angle; // 10,15,20,25,30,35,40,45 degrees from horizontal
  wire [1:0] speed = hits >= 9 ? 2'd3 : hits >= 6 ? 2'd2 : hits >= 3 ? 2'd1 : 2'd0;
  reg [7:0] vx,vy;
  // Rounded speed*cos(theta), speed*sin(theta) in Q4. Constants are a small
  // combinational lookup: no runtime multipliers, dividers or trig units.
  // Vector magnitude differs from its nominal speed by <0.05 px/frame.
  always @* begin
    case ({speed,angle})
      5'd0: begin vx=8'd63; vy=8'd11; end // 4 px/frame, 10 degrees
      5'd1: begin vx=8'd62; vy=8'd17; end // 4 px/frame, 15 degrees
      5'd2: begin vx=8'd60; vy=8'd22; end // 4 px/frame, 20 degrees
      5'd3: begin vx=8'd58; vy=8'd27; end // 4 px/frame, 25 degrees
      5'd4: begin vx=8'd55; vy=8'd32; end // 4 px/frame, 30 degrees
      5'd5: begin vx=8'd52; vy=8'd37; end // 4 px/frame, 35 degrees
      5'd6: begin vx=8'd49; vy=8'd41; end // 4 px/frame, 40 degrees
      5'd7: begin vx=8'd45; vy=8'd45; end // 4 px/frame, 45 degrees
      5'd8: begin vx=8'd95; vy=8'd17; end // 6 px/frame, 10 degrees
      5'd9: begin vx=8'd93; vy=8'd25; end // 6 px/frame, 15 degrees
      5'd10: begin vx=8'd90; vy=8'd33; end // 6 px/frame, 20 degrees
      5'd11: begin vx=8'd87; vy=8'd41; end // 6 px/frame, 25 degrees
      5'd12: begin vx=8'd83; vy=8'd48; end // 6 px/frame, 30 degrees
      5'd13: begin vx=8'd79; vy=8'd55; end // 6 px/frame, 35 degrees
      5'd14: begin vx=8'd74; vy=8'd62; end // 6 px/frame, 40 degrees
      5'd15: begin vx=8'd68; vy=8'd68; end // 6 px/frame, 45 degrees
      5'd16: begin vx=8'd126; vy=8'd22; end // 8 px/frame, 10 degrees
      5'd17: begin vx=8'd124; vy=8'd33; end // 8 px/frame, 15 degrees
      5'd18: begin vx=8'd120; vy=8'd44; end // 8 px/frame, 20 degrees
      5'd19: begin vx=8'd116; vy=8'd54; end // 8 px/frame, 25 degrees
      5'd20: begin vx=8'd111; vy=8'd64; end // 8 px/frame, 30 degrees
      5'd21: begin vx=8'd105; vy=8'd73; end // 8 px/frame, 35 degrees
      5'd22: begin vx=8'd98; vy=8'd82; end // 8 px/frame, 40 degrees
      5'd23: begin vx=8'd91; vy=8'd91; end // 8 px/frame, 45 degrees
      5'd24: begin vx=8'd158; vy=8'd28; end // 10 px/frame, 10 degrees
      5'd25: begin vx=8'd155; vy=8'd41; end // 10 px/frame, 15 degrees
      5'd26: begin vx=8'd150; vy=8'd55; end // 10 px/frame, 20 degrees
      5'd27: begin vx=8'd145; vy=8'd68; end // 10 px/frame, 25 degrees
      5'd28: begin vx=8'd139; vy=8'd80; end // 10 px/frame, 30 degrees
      5'd29: begin vx=8'd131; vy=8'd92; end // 10 px/frame, 35 degrees
      5'd30: begin vx=8'd123; vy=8'd103; end // 10 px/frame, 40 degrees
      5'd31: begin vx=8'd113; vy=8'd113; end // 10 px/frame, 45 degrees
      default: begin vx=8'd63; vy=8'd11; end
    endcase
  end

  function [8:0] paddle_next;
    input [8:0] pos;
    input up,down;
    begin
      if (up && !down) paddle_next = pos < 9'd20 ? 9'd8 : pos-9'd12;
      else if (down && !up) paddle_next = pos > 9'd396 ? 9'd408 : pos+9'd12;
      else paddle_next=pos;
    end
  endfunction
  wire [8:0] p1_next=paddle_next(pad1_y,btn[0],btn[1]);
  wire [8:0] p2_next=paddle_next(pad2_y,btn[2],btn[3]);
  // Signed wide intermediates detect off-screen motion without wraparound.
  wire signed [15:0] x_trial=$signed({2'b0,ball_x}) +
                                (dx ? $signed({8'd0,vx}) : -$signed({8'd0,vx}));
  wire signed [15:0] y_trial=$signed({3'b0,ball_y}) +
                                (dy ? $signed({8'd0,vy}) : -$signed({8'd0,vy}));
  wire top_hit=y_trial < 16'sd128;   // ball top >= 8 px
  wire bot_hit=y_trial > 16'sd7424;  // ball top <= 464 px
  // Reflect overshoot instead of discarding it, maintaining speed at walls.
  wire signed [15:0] y_wall=top_hit ? 16'sd256-y_trial :
                                   bot_hit ? 16'sd14848-y_trial : y_trial;
  wire dy_wall=top_hit ? 1'b1 : bot_hit ? 1'b0 : dy;
  wire [12:0] y_safe=y_wall[12:0];
  // Swept X crossing tests catch a paddle even when a frame travels farther
  // than its width. Y overlap uses the wall-reflected destination position.
  wire overlap1 = y_safe < ({p1_next,4'b0}+13'd1024) &&
                  (y_safe+13'd128) > {p1_next,4'b0};
  wire overlap2 = y_safe < ({p2_next,4'b0}+13'd1024) &&
                  (y_safe+13'd128) > {p2_next,4'b0};
  wire left_hit= !dx && ball_x >= 14'd384 && x_trial <= 16'sd384 && overlap1;
  wire right_hit=dx && ball_x <= 14'd9728 && x_trial >= 16'sd9728 && overlap2;
  wire paddle_hit=left_hit || right_hit;
  wire signed [15:0] x_reflect=left_hit ? 16'sd768-x_trial :
                                  right_hit ? 16'sd19456-x_trial : x_trial;
  wire missed_left=x_trial < 16'sd0;
  wire missed_right=x_trial >= 16'sd10240;
  wire point=missed_left || missed_right;
  // Ball-centre minus paddle-centre, in pixels. During a hit the magnitude
  // is at most 35 px. Four-pixel bands cover 0..31; edge grazes clamp to 45.
  wire [8:0] hit_pad=right_hit ? p2_next : p1_next;
  wire signed [9:0] offset=$signed({1'b0,y_safe[12:4]})-
                           $signed({1'b0,hit_pad})-10'sd28;
  wire [9:0] distance_from_mid=offset[9] ? $unsigned(-offset) : $unsigned(offset);
  wire [2:0] hit_angle=distance_from_mid >= 10'd32 ? 3'd7 : distance_from_mid[4:2];

  always @(posedge clk) begin
    if (!rst_n) begin
      ball_x<=14'd5056; ball_y<=13'd3776; // top-left (316,236)
      pad1_y<=9'd208; pad2_y<=9'd208;
      dx<=1'b1; dy<=1'b1; serving<=1'b1;
      hits<=4'd0; angle<=3'd3;
      score1<=4'd0; score2<=4'd0;
    end else if (frame_end) begin
      pad1_y<=p1_next; pad2_y<=p2_next;
      if (serving) begin
        ball_x<=14'd5056; ball_y<=13'd3776;
        hits<=4'd0; angle<=3'd3;
        if (btn[4]) serving<=1'b0;
      end else if (point) begin
        ball_x<=14'd5056; ball_y<=13'd3776;
        serving<=1'b1; hits<=4'd0; angle<=3'd3;
        if (missed_right) score1<=score1+4'd1;
        else score2<=score2+4'd1;
      end else begin
        ball_x<=x_reflect[13:0]; ball_y<=y_safe;
        dy<=dy_wall;
        if (paddle_hit) begin
          dx<=left_hit;
          // At a simultaneous wall/paddle event, send the ball into court.
          dy<=top_hit ? 1'b1 : bot_hit ? 1'b0 : !offset[9];
          angle<=hit_angle;
          if (hits<9) hits<=hits+4'd1;
        end
      end
    end
  end
  wire _unused=&{x_reflect[15:14],y_wall[15:13],distance_from_mid[1:0],1'b0};
endmodule

module pong_render (
    input wire [9:0] hcount,vcount,
    input wire visible,
    input wire [9:0] ball_x,
    input wire [8:0] ball_y,pad1_y,pad2_y,
    output wire [1:0] R,G,B
);
  wire [9:0] bx=hcount-ball_x;
  wire [8:0] by=vcount[8:0]-ball_y;
  wire ball=(bx[9:3]==0)&&(by[8:3]==0);
  wire [8:0] py=hcount[9]?pad2_y:pad1_y;
  wire [8:0] pd=vcount[8:0]-py;
  wire paddle=((hcount[9:3]==7'd2)||(hcount[9:3]==7'd77))&&(pd[8:6]==0);
  wire wall=(vcount<10'd8)||(vcount>=10'd472);
  wire white=visible&&(ball||paddle);
  wire grey=visible&&wall;
  assign R={white,white|grey};
  assign G=R;
  assign B=R;
  wire _unused=&{hcount[2:0],bx[2:0],by[2:0],pd[5:0],1'b0};
endmodule
