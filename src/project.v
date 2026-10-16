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
  function [15:0] velocity;
    input [4:0] selection;
    begin
      case(selection)
        5'd0: velocity={8'd63,8'd11};
        5'd1: velocity={8'd62,8'd17};
        5'd2: velocity={8'd60,8'd22};
        5'd3: velocity={8'd58,8'd27};
        5'd4: velocity={8'd55,8'd32};
        5'd5: velocity={8'd52,8'd37};
        5'd6: velocity={8'd49,8'd41};
        5'd7: velocity={8'd45,8'd45};
        5'd8: velocity={8'd95,8'd17};
        5'd9: velocity={8'd93,8'd25};
        5'd10: velocity={8'd90,8'd33};
        5'd11: velocity={8'd87,8'd41};
        5'd12: velocity={8'd83,8'd48};
        5'd13: velocity={8'd79,8'd55};
        5'd14: velocity={8'd74,8'd62};
        5'd15: velocity={8'd68,8'd68};
        5'd16: velocity={8'd126,8'd22};
        5'd17: velocity={8'd124,8'd33};
        5'd18: velocity={8'd120,8'd44};
        5'd19: velocity={8'd116,8'd54};
        5'd20: velocity={8'd111,8'd64};
        5'd21: velocity={8'd105,8'd73};
        5'd22: velocity={8'd98,8'd82};
        5'd23: velocity={8'd91,8'd91};
        5'd24: velocity={8'd158,8'd28};
        5'd25: velocity={8'd155,8'd41};
        5'd26: velocity={8'd150,8'd55};
        5'd27: velocity={8'd145,8'd68};
        5'd28: velocity={8'd139,8'd80};
        5'd29: velocity={8'd131,8'd92};
        5'd30: velocity={8'd123,8'd103};
        5'd31: velocity={8'd113,8'd113};
        default: velocity={8'd63,8'd11};
      endcase
    end
  endfunction

  function [8:0] paddle_next;
    input [8:0] pos;
    input up,down;
    begin
      if (up && !down) paddle_next = pos < 9'd20 ? 9'd8 : pos-9'd12;
      else if (down && !up) paddle_next = pos > 9'd396 ? 9'd408 : pos+9'd12;
      else paddle_next=pos;
    end
  endfunction
  // A pure next-state function is evaluated once per frame in simulators.
  // Synthesis builds the same combinational physics feeding the state flops.
  // All blocking assignments below are local function temporaries.
  function automatic [62:0] advance_game;
    input [62:0] state;
    input [4:0] buttons;
    reg [13:0] n_ball_x;
    reg [12:0] n_ball_y;
    reg [8:0] n_pad1_y,n_pad2_y;
    reg [3:0] n_score1,n_score2,n_hits;
    reg n_dx,n_dy,n_serving;
    reg [2:0] n_angle;
    reg [1:0] n_speed;
    reg [7:0] vx,vy;
    reg [8:0] p1_next;
    reg [8:0] p2_next;
    reg signed [15:0] x_trial;
    reg signed [15:0] y_trial;
    reg top_hit;
    reg bot_hit;
    reg signed [15:0] y_wall;
    reg dy_wall;
    reg [12:0] y_safe;
    reg overlap1;
    reg overlap2;
    reg left_hit;
    reg right_hit;
    reg paddle_hit;
    reg signed [15:0] x_reflect;
    reg missed_left;
    reg missed_right;
    reg point;
    reg [8:0] hit_pad;
    reg signed [9:0] offset;
    reg [9:0] distance_from_mid;
    reg [2:0] hit_angle;
    reg n__unused;
    begin
      {n_ball_x,n_ball_y,n_pad1_y,n_pad2_y,n_score1,n_score2,n_dx,n_dy,n_serving,n_hits,n_angle}=state;
      n_speed=n_hits>=9?2'd3:n_hits>=6?2'd2:n_hits>=3?2'd1:2'd0;
      {vx,vy}=velocity({n_speed,n_angle});
      p1_next=paddle_next(n_pad1_y,buttons[0],buttons[1]);
      p2_next=paddle_next(n_pad2_y,buttons[2],buttons[3]);
      x_trial=$signed({2'b0,n_ball_x}) +
                                (n_dx ? $signed({8'd0,vx}) : -$signed({8'd0,vx}));
      y_trial=$signed({3'b0,n_ball_y}) +
                                (n_dy ? $signed({8'd0,vy}) : -$signed({8'd0,vy}));
      top_hit=y_trial < 16'sd128;
      bot_hit=y_trial > 16'sd7424;
      y_wall=top_hit ? 16'sd256-y_trial :
                                   bot_hit ? 16'sd14848-y_trial : y_trial;
      dy_wall=top_hit ? 1'b1 : bot_hit ? 1'b0 : n_dy;
      y_safe=y_wall[12:0];
      overlap1= y_safe < ({p1_next,4'b0}+13'd1024) &&
                  (y_safe+13'd128) > {p1_next,4'b0};
      overlap2= y_safe < ({p2_next,4'b0}+13'd1024) &&
                  (y_safe+13'd128) > {p2_next,4'b0};
      left_hit= !n_dx && n_ball_x >= 14'd384 && x_trial <= 16'sd384 && overlap1;
      right_hit=n_dx && n_ball_x <= 14'd9728 && x_trial >= 16'sd9728 && overlap2;
      paddle_hit=left_hit || right_hit;
      x_reflect=left_hit ? 16'sd768-x_trial :
                                  right_hit ? 16'sd19456-x_trial : x_trial;
      missed_left=x_trial < 16'sd0;
      missed_right=x_trial >= 16'sd10240;
      point=missed_left || missed_right;
      hit_pad=right_hit ? p2_next : p1_next;
      offset=$signed({1'b0,y_safe[12:4]})-
                           $signed({1'b0,hit_pad})-10'sd28;
      distance_from_mid=offset[9] ? $unsigned(-offset) : $unsigned(offset);
      hit_angle=distance_from_mid >= 10'd32 ? 3'd7 : distance_from_mid[4:2];
      n_pad1_y=p1_next; n_pad2_y=p2_next;
      if (n_serving) begin
        n_ball_x=14'd5056; n_ball_y=13'd3776;
        n_hits=4'd0; n_angle=3'd3;
        if (buttons[4]) n_serving=1'b0;
      end else if (point) begin
        n_ball_x=14'd5056; n_ball_y=13'd3776;
        n_serving=1'b1; n_hits=4'd0; n_angle=3'd3;
        if (missed_right) n_score1=n_score1+4'd1;
        else n_score2=n_score2+4'd1;
      end else begin
        n_ball_x=x_reflect[13:0]; n_ball_y=y_safe;
        n_dy=dy_wall;
        if (paddle_hit) begin
          n_dx=left_hit;
          // At a simultaneous wall/paddle event, send the ball into court.
          n_dy=top_hit ? 1'b1 : bot_hit ? 1'b0 : !offset[9];
          n_angle=hit_angle;
          if (n_hits<9) n_hits=n_hits+4'd1;
        end
      end
      n__unused=&{x_reflect[15:14],y_wall[15:13],distance_from_mid[1:0],1'b0};
      advance_game={n_ball_x,n_ball_y,n_pad1_y,n_pad2_y,n_score1,n_score2,n_dx,n_dy,n_serving,n_hits,n_angle};
    end
  endfunction
  always @(posedge clk) begin
    if (!rst_n) begin
      ball_x<=14'd5056; ball_y<=13'd3776; // top-left (316,236)
      pad1_y<=9'd208; pad2_y<=9'd208;
      dx<=1'b1; dy<=1'b1; serving<=1'b1;
      hits<=4'd0; angle<=3'd3;
      score1<=4'd0; score2<=4'd0;
    end else if (frame_end) begin
      {ball_x,ball_y,pad1_y,pad2_y,score1,score2,dx,dy,serving,hits,angle} <= advance_game({ball_x,ball_y,pad1_y,pad2_y,score1,score2,dx,dy,serving,hits,angle},btn);
    end
  end
  wire _unused=&{speed,1'b0};

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
