/* Pong VGA: pixel-resolution rendering and Q4 subpixel physics.
 * 25.175 MHz / (800*525) = 59.940476 Hz. Gameplay advances once per frame.
 * Pins and 1x1 GF180 tile are unchanged. No frame buffer or derived clocks.
 * The picture: the University of Waterloo's Engineering 5 building at sunset,
 * a Canada goose for the ball and a pencil and a pen for the paddles.
 */
`default_nettype none
module tt_um_aarons763_pong_vga (
    input wire [7:0] ui_in, output wire [7:0] uo_out,
    input wire [7:0] uio_in, output wire [7:0] uio_out,
    output wire [7:0] uio_oe, input wire ena, clk, rst_n
);
  // Both assertion and release are synchronous. Only the first stage sees
  // the external reset pin; all functional logic uses the second stage.
  (* ASYNC_REG = "TRUE" *) reg reset_meta_n, reset_sync_n;
  always @(posedge clk) begin
    reset_meta_n <= rst_n;
    reset_sync_n <= reset_meta_n;
  end
  wire [9:0] hcount, vcount;
  wire hsync, vsync, visible, frame_end;
  pong_vga_sync sync_gen(clk,reset_sync_n,hcount,vcount,hsync,vsync,visible,frame_end);
  wire [13:0] ball_x;
  wire [12:0] ball_y;
  wire [8:0] pad1_y,pad2_y;
  wire [3:0] score1,score2;
  // Capture once at the start of vertical blanking. The physics inputs then
  // remain stable for 35,999 clocks before frame_end loads the game state.
  // Reset also restarts the scan counters, so the first update after reset
  // cannot occur until after this capture. See the scoped exception in pong.sdc.
  reg [4:0] frame_buttons;
  always @(posedge clk) begin
    if (!reset_sync_n) frame_buttons <= 5'b0;
    else if (vcount == 10'd480 && hcount == 10'd0)
      frame_buttons <= ui_in[4:0];
  end
  // dx keeps the game's register name so the Q-net patterns in pong.sdc
  // still match whichever name survives flattening.
  wire dx;
  pong_game game(clk,reset_sync_n,frame_end,frame_buttons,ball_x,ball_y,pad1_y,pad2_y,score1,score2,dx);
  wire [1:0] R,G,B;
  pong_render render(hcount,vcount,visible,ball_x[13:4],ball_y[12:4],pad1_y,pad2_y,dx,R,G,B);
  // One output stage for all six colour bits and both syncs. The displayed
  // pixel trails the scan counters by one clock; syncs travel with that pixel.
  reg [7:0] video_out;
  always @(posedge clk) begin
    video_out <= {hsync,B[0],G[0],R[0],vsync,B[1],G[1],R[1]};
  end
  assign uo_out=video_out;
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
    output reg [3:0] score1,score2,
    output reg dx // moving right; the renderer turns the goose to face its way
);
  reg dy; // moving down
  reg serving;
  reg [3:0] hits; // saturates at 15: tiers 4,6,8,10,12,14 pixels/frame
  reg [2:0] angle; // 10,15,20,25,30,35,40,45 degrees from horizontal
  // Speed tier: one step every 3 paddle hits this rally (0-2 hits -> 0 ... 15 -> 5).
  wire [2:0] speed = hits >= 15 ? 3'd5 : hits >= 12 ? 3'd4 : hits >= 9 ? 3'd3 :
                     hits >= 6 ? 3'd2 : hits >= 3 ? 3'd1 : 3'd0;
  function [15:0] velocity;
    input [5:0] selection;
    begin
      case (selection)
        6'd0: velocity={8'd63,8'd11};
        6'd1: velocity={8'd62,8'd17};
        6'd2: velocity={8'd60,8'd22};
        6'd3: velocity={8'd58,8'd27};
        6'd4: velocity={8'd55,8'd32};
        6'd5: velocity={8'd52,8'd37};
        6'd6: velocity={8'd49,8'd41};
        6'd7: velocity={8'd45,8'd45};
        6'd8: velocity={8'd95,8'd17};
        6'd9: velocity={8'd93,8'd25};
        6'd10: velocity={8'd90,8'd33};
        6'd11: velocity={8'd87,8'd41};
        6'd12: velocity={8'd83,8'd48};
        6'd13: velocity={8'd79,8'd55};
        6'd14: velocity={8'd74,8'd62};
        6'd15: velocity={8'd68,8'd68};
        6'd16: velocity={8'd126,8'd22};
        6'd17: velocity={8'd124,8'd33};
        6'd18: velocity={8'd120,8'd44};
        6'd19: velocity={8'd116,8'd54};
        6'd20: velocity={8'd111,8'd64};
        6'd21: velocity={8'd105,8'd73};
        6'd22: velocity={8'd98,8'd82};
        6'd23: velocity={8'd91,8'd91};
        6'd24: velocity={8'd158,8'd28};
        6'd25: velocity={8'd155,8'd41};
        6'd26: velocity={8'd150,8'd55};
        6'd27: velocity={8'd145,8'd68};
        6'd28: velocity={8'd139,8'd80};
        6'd29: velocity={8'd131,8'd92};
        6'd30: velocity={8'd123,8'd103};
        6'd31: velocity={8'd113,8'd113};
        6'd32: velocity={8'd189,8'd33};
        6'd33: velocity={8'd185,8'd50};
        6'd34: velocity={8'd180,8'd66};
        6'd35: velocity={8'd174,8'd81};
        6'd36: velocity={8'd166,8'd96};
        6'd37: velocity={8'd157,8'd110};
        6'd38: velocity={8'd147,8'd123};
        6'd39: velocity={8'd136,8'd136};
        6'd40: velocity={8'd221,8'd39};
        6'd41: velocity={8'd216,8'd58};
        6'd42: velocity={8'd210,8'd77};
        6'd43: velocity={8'd203,8'd95};
        6'd44: velocity={8'd194,8'd112};
        6'd45: velocity={8'd183,8'd128};
        6'd46: velocity={8'd172,8'd144};
        6'd47: velocity={8'd158,8'd158};
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
    reg [2:0] n_speed;
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
      n_speed=n_hits>=15?3'd5:n_hits>=12?3'd4:n_hits>=9?3'd3:n_hits>=6?3'd2:n_hits>=3?3'd1:3'd0;
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
          if (n_hits<15) n_hits=n_hits+4'd1;
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

// Draws one pixel. The scene is Engineering 5 (E5), University of Waterloo,
// seen head-on at sunset (after Google Street View photos). Seen straight on,
// every edge is horizontal or vertical, and most sit on 8, 16 or 32 pixel
// steps, so each test is a short comparison of the counters' upper bits.
// Front to back: the goose (ball); the pencil and pen (paddles); the end
// walls; the sidewalk, stairs, walkway, fence and grass; the building; the
// clouds; the sunset sky.
module pong_render (
    input wire [9:0] hcount,vcount,
    input wire visible,
    input wire [9:0] ball_x,
    input wire [8:0] ball_y,pad1_y,pad2_y,
    input wire dx,             // the goose faces the way it flies
    output reg [1:0] R,G,B
);
  wire [9:0] bx=hcount-ball_x;   // pixel position relative to the ball
  wire [8:0] by=vcount[8:0]-ball_y;
  wire [8:0] py=hcount[9]?pad2_y:pad1_y;
  wire [8:0] pd=vcount[8:0]-py;
  wire paddle=((hcount[9:3]==7'd2)||(hcount[9:3]==7'd77))&&(pd[8:6]==0);
  wire wall=(vcount<10'd8)||(vcount>=10'd472);

  wire [6:0] hx=hcount[9:3];     // 8-pixel column
  wire [6:0] vy=vcount[9:3];     // 8-pixel row
  wire [4:0] hb=hcount[9:5];     // 32-pixel column
  wire [4:0] vb=vcount[9:5];     // 32-pixel row
  wire [1:0] bayer={hcount[0]^vcount[0],vcount[0]};  // 2x2 ordered dither

  // ------------------------------------------------------------ the goose
  // A Canada goose, drawn from an 8x8 picture at triple size (24x24, each
  // picture pixel 3x3) and centred on the ball, so it reaches 8 px past the
  // ball's 8x8 hit box on each side. 2 bits per pixel, row 0 first; the art
  // faces right and is flipped when the ball moves left:
  //   ......KK  ......KW  ......K.  .....K..  BBBBBK..  .BBBBBB.  ..BBBB..  ...K.K..
  // K=1 black head, neck and feet, W=2 white cheek, B=3 grey-brown body.
  localparam [127:0] GOOSE=128'h04400ff03ffc07ff0400100090005000;
  wire [9:0] gbx=bx+10'd8;                       // 0..23 across the goose
  wire [8:0] gby=by+9'd8;
  wire goose_box=(gbx[9:5]==5'd0)&&(gbx[4:3]!=2'd3)&&(gby[8:5]==4'd0)&&(gby[4:3]!=2'd3);
  function [2:0] third;                           // n/3 for n = 0..23
    input [4:0] n;
    third=(n<5'd3)?3'd0:(n<5'd6)?3'd1:(n<5'd9)?3'd2:(n<5'd12)?3'd3:
          (n<5'd15)?3'd4:(n<5'd18)?3'd5:(n<5'd21)?3'd6:3'd7;
  endfunction
  wire [2:0] gx0=third(gbx[4:0]);
  wire [2:0] gx=dx?gx0:~gx0;
  wire [1:0] goose_px=GOOSE[{third(gby[4:0]),gx,1'b0}+:2];
  wire goose=goose_box&&(goose_px!=2'd0);
  wire [5:0] goose_rgb=(goose_px==2'd1) ? 6'b00_00_00 :
                       (goose_px==2'd2) ? 6'b11_11_11 : 6'b01_01_01;

  // ----------------------------------------------- the pencil and the pen
  // Same 8x64 box as the paddle. Rows: 0-5 eraser / cap, 6-9 metal band,
  // 10-53 body (three shades for the facets), 54-59 the wood cone narrowing
  // (6, 4, 2 wide), 60-63 the point. Yellow pencil on the left, blue pen on
  // the right. All-zero means transparent.
  wire [5:0] pr=pd[5:0];
  wire [2:0] pc=hcount[2:0];
  wire outer=(pc==3'd0)||(pc==3'd7);
  wire pen=hcount[9];
  wire [2:0] cone_lo=(pr<6'd56) ? 3'd1 : (pr<6'd58) ? 3'd2 : 3'd3;
  reg [5:0] pencil_rgb;
  always @(*) begin
    if (pr<6'd6)        pencil_rgb=outer ? 6'd0 : pen ? 6'b00_00_10 : 6'b11_10_10;
    else if (pr<6'd10)  pencil_rgb=outer ? 6'd0 : (pr==6'd7) ? 6'b01_01_01 : pen ? 6'b11_11_11 : 6'b10_10_10;
    else if (pr<6'd54)  pencil_rgb=outer ? 6'd0
                                  : (pc<3'd3) ? (pen ? 6'b00_01_11 : 6'b11_10_00)
                                  : (pc<3'd5) ? (pen ? 6'b01_10_11 : 6'b11_11_01)
                                  : (pen ? 6'b00_01_10 : 6'b10_10_00);
    else if (pr<6'd60)  pencil_rgb=((pc>=cone_lo)&&(pc<=3'd7-cone_lo))
                                  ? (pen ? 6'b10_10_10 : 6'b11_10_01) : 6'd0;
    else                pencil_rgb=((pc==3'd3)||(pc==3'd4)) ? (pen ? 6'b00_00_10 : 6'b01_01_01) : 6'd0;
  end

  // ------------------------------------------------------------ the sky
  // Sunset: dusky purple at the top, through pink and salmon, to orange near
  // the horizon. One key colour per 64 lines, blended with the dither (it
  // fakes in-between shades on a 64-colour display); orange below y 256.
  function [5:0] sky_key;
    input [2:0] k;
    case (k)
      3'd0: sky_key=6'b01_00_10;    // dusky purple
      3'd1: sky_key=6'b10_01_10;    // pink
      3'd2: sky_key=6'b11_01_01;    // salmon
      default: sky_key=6'b11_10_01; // orange
    endcase
  endfunction
  wire [2:0] sky_k=vcount[8] ? 3'd3 : {1'b0,vcount[7:6]};
  wire [5:0] sky_rgb=(vcount[5:4]>bayer)?sky_key(sky_k+3'd1):sky_key(sky_k);
  // Clouds, y 32-63: a row of big round puffs centred in each 32-px block,
  // with smaller puffs centred on the block edges filling the gaps above and
  // below, so the cloud is scalloped all round. Both use the counters' low
  // bits folded about the puff centre (no adders beyond 5 bits).
  wire [3:0] cfx=hcount[3:0]^{4{~hcount[4]}};    // 0 at a block centre
  wire [3:0] efx=hcount[3:0]^{4{hcount[4]}};     // 0 at a block edge
  wire [3:0] cfy=vcount[3:0]^{4{~vcount[4]}};
  wire big_puff=({1'b0,cfx}+{1'b0,cfy})<5'd19;
  wire small_puff=({1'b0,efx}+{1'b0,cfy})<5'd12;
  wire cloud_cols=((hb>=5'd2)&&(hb<5'd5))||((hb>=5'd15)&&(hb<5'd17));
  wire cloud_inner=((hcount>=10'd80)&&(hcount<10'd144))||((hcount>=10'd496)&&(hcount<10'd528));
  wire cloud=(vb==5'd1)&&((cloud_cols&&big_puff)||(cloud_inner&&small_puff));

  // ------------------------------------------------------------ the building
  // Outline x 32-607. Rooftop mechanical level x 120-519, y 72-95: dark
  // louvred panels with a glass centre. Panel facade y 96-351 in eight
  // 32-row floors (to y 319 on the left, where the glass starts lower).
  wire bldg_x=(hb>=5'd1)&&(hb<5'd19);
  wire roof=(hx>=7'd15)&&(hx<7'd65)&&(vy>=7'd9)&&(vy<7'd12);
  wire roof_glass=roof&&(hx>=7'd37)&&(hx<7'd43);
  wire louvre=(vcount[1:0]==2'd0);
  wire right_part=hb>=5'd9;                       // x >= 288
  wire glass_lower=bldg_x&&(right_part ? (vb>=5'd8) : (vb>=5'd10))&&(vy<7'd48); // to y 383
  wire facade=bldg_x&&(vb>=5'd3)&&(vy<7'd48)&&!glass_lower;
  wire trim=bldg_x&&(vy>=7'd12)&&(vy<7'd48)&&((hcount[9:1]==9'd16)||(hcount[9:1]==9'd303)); // corner edges
  wire cornice=bldg_x&&(vcount[9:1]==9'd48);      // y 96-97
  // Folded panels, 64 px wide and one 32-row floor tall, aligned to the
  // building's left edge. Each panel is a shallow four-sided point: the top,
  // left, right and bottom faces meet at the centre, each lit differently.
  // u and v are the distances from the panel centre (0..31 across, 0..15
  // down); the top or bottom face is where 2v > u.
  wire [5:0] pu={~hcount[5],hcount[4:0]};         // 0..63 across the panel
  wire [4:0] ux=pu[5] ? pu[4:0] : ~pu[4:0];       // distance from the centre
  wire [3:0] vy4=vcount[4] ? vcount[3:0] : ~vcount[3:0];
  wire vertical_face={vy4,1'b0}>ux;
  // Four greys, two of them made by checkerboard dithering between levels:
  // top face darkest, left face mid grey, right face light grey, bottom white.
  wire chk=bayer[1];
  wire [5:0] panel_rgb=vertical_face ? (vcount[4] ? 6'b11_11_11                         // bottom
                                                  : (chk ? 6'b01_01_01 : 6'b10_10_10)) // top
                                     : (pu[5] ? (chk ? 6'b11_11_11 : 6'b10_10_10)     // right
                                              : 6'b10_10_10);                             // left
  wire panel_edge=(vcount[4:0]==5'd0)||(pu==6'd0);
  // Atrium: a two-storey glass recess x 288-351, y 160-255, with a white
  // column, floor slabs, a balcony rail and plants on the ledge.
  wire atrium=(hx>=7'd36)&&(hx<7'd44)&&(vb>=5'd5)&&(vb<5'd8);
  wire atrium_column=(hcount[9:2]==8'd80);
  wire atrium_slab=(vcount[4:1]==4'd0);
  wire atrium_mullion=(hcount[3:0]==4'd0);
  wire atrium_rail=(vcount[4:0]==5'd26);
  wire plants=(vcount[9:2]==8'd63)&&(hcount[1]^hcount[3]);
  // Glass storeys: mullions every 8 px, transoms at each floor, and the upper
  // band of each pane reflecting the sky.
  wire mullion=(hcount[2:0]==3'd0);
  wire transom=(vcount[4:0]==5'd0)||(vcount[4:0]==5'd1);
  // Concrete wall on the left of the ground floor, with a capping band and vents.
  wire concrete=(hx>=7'd10)&&(hx<7'd24)&&(vy>=7'd42)&&(vy<7'd48);
  wire concrete_cap=concrete&&(vy==7'd42)&&(vcount[2:1]==2'd0);
  wire vent=((hx==7'd21)||(hx==7'd12))&&(vy==7'd43)&&vcount[1];
  // Entrance on the second floor (y 320-351) at the top of the stairs: three
  // pairs of glass doors, under a dark canopy.
  wire doors=(hx>=7'd37)&&(hx<7'd43)&&(vy>=7'd40)&&(vy<7'd44);
  wire canopy=(hx>=7'd36)&&(hx<7'd44)&&(vcount[9:2]==8'd79);
  wire door_frame=(hcount[3:0]==4'd0)||(vy==7'd40);

  // ------------------------------------------------------------ the ground
  // Stairs x 288-351 climb from the walkway (y 431) to a landing at the
  // second-floor doors (y 352-355), in front of the ground floor, between
  // concrete side walls, with three handrails. Below: the walkway, a black
  // fence along the grass, and the sidewalk (y 448-471).
  wire stair_x=(hx>=7'd36)&&(hx<7'd44);
  wire stair_wall=((hx==7'd35)||(hx==7'd44))&&(vy>=7'd44)&&(vy<7'd54);
  wire landing=stair_x&&(vcount[9:2]==8'd88);
  wire stairs=stair_x&&(vy>=7'd44)&&(vy<7'd54);
  wire handrail=(hcount==10'd298)||(hcount==10'd319)||(hcount==10'd341);
  wire walkway=(hx>=7'd34)&&(hx<7'd46)&&(vy>=7'd54);
  wire fence=(vy==7'd52)&&((hcount[2:0]==3'd0)||(vcount[2:0]==3'd0));
  wire sidewalk=(vy>=7'd56);

  reg [5:0] scene;
  always @(*) begin
    if (wall)                     scene=((vcount==10'd3)||(vcount==10'd4)||(vcount==10'd475)||(vcount==10'd476))
                                        ? 6'b11_10_00 : 6'b00_00_00;     // black and UW gold
    else if (sidewalk)            scene=6'b10_10_10;
    else if (stair_wall)          scene=(vcount[9:2]==8'd88) ? 6'b11_11_11 : 6'b10_10_10;
    else if (landing)             scene=6'b10_10_10;
    else if (stairs)              scene=handrail ? 6'b11_11_11
                                      : (vcount[1:0]==2'd0) ? 6'b01_01_01 : 6'b10_10_10;
    else if (walkway)             scene=(vcount[3:0]==4'd0) ? 6'b10_01_01 : 6'b10_10_10;
    else if (vy>=7'd48)           scene=fence ? 6'b00_00_00 : bayer[1] ? 6'b00_10_00 : 6'b00_01_00; // grass
    else if (roof)                scene=roof_glass ? ((mullion||(vcount[2:0]==3'd0)) ? 6'b01_01_01 : 6'b01_10_11)
                                      : ((hcount[4:0]==5'd0)||louvre) ? 6'b00_00_00 : 6'b01_01_01;
    else if (trim||cornice)       scene=6'b11_11_11;
    else if (atrium)              scene=atrium_column ? 6'b11_11_11
                                      : plants ? 6'b00_10_00
                                      : (atrium_slab||atrium_rail) ? 6'b10_10_10
                                      : atrium_mullion ? 6'b01_01_10 : 6'b00_00_01;
    else if (canopy)              scene=6'b01_01_01;
    else if (doors)               scene=door_frame ? 6'b10_10_10 : 6'b00_00_01;
    else if (concrete)            scene=concrete_cap ? 6'b11_11_11
                                      : (vent||(hcount[4:0]==5'd0)) ? 6'b01_01_01 : 6'b10_10_10;
    else if (glass_lower)         scene=(mullion||transom) ? 6'b10_10_10
                                      : (vcount[4:3]==2'd1) ? 6'b01_10_10        // sky reflection
                                      : bayer[0] ? 6'b00_10_10 : 6'b00_01_01;    // dark teal glass
    else if (facade)              scene=panel_edge ? 6'b10_10_10 : panel_rgb;
    else if (cloud)               scene=bayer==2'd3 ? 6'b11_01_10 : 6'b11_10_10; // sunlit pink
    else                          scene=sky_rgb;
  end

  always @(*) begin
    if (!visible)                         {R,G,B}=6'b00_00_00;
    else if (goose)                       {R,G,B}=goose_rgb;
    else if (paddle&&(pencil_rgb!=6'd0))  {R,G,B}=pencil_rgb;
    else                                  {R,G,B}=scene;
  end
  wire _unused=&{pd[8:6],1'b0};
endmodule
