`timescale 1ns/1ps
`default_nettype none
module tb_features;
  reg clk=0,rst_n=0,frame_end=0;
  reg [4:0] btn=0;
  wire [13:0] x;
  wire [12:0] y;
  wire [8:0] p1,p2;
  wire [3:0] s1,s2;
  pong_game dut(clk,rst_n,frame_end,btn,x,y,p1,p2,s1,s2);
  integer a,l,d,i,evx,evy,expected,oldx,oldy,travel_x,travel_y;
  real theta,mag;
  task cycle;begin #5;clk=1;#5;clk=0;end endtask
  task frame;begin frame_end=1;cycle;frame_end=0;end endtask
  task reset;begin rst_n=0;cycle;rst_n=1;btn=0;end endtask
  initial begin
    reset;
    repeat(50)frame;
    if(x!==5056||y!==3776||dut.hits!==0||!dut.serving)$fatal(1,"idle drift");
    btn=5;frame;
    if(p1!==196||p2!==196)$fatal(1,"paddle rate must be exactly 12 px/frame");
    btn=15;frame;if(p1!==196||p2!==196)$fatal(1,"opposing buttons");
    btn=5;repeat(50)frame;if(p1!==8||p2!==8)$fatal(1,"top clamp");
    btn=10;repeat(50)frame;if(p1!==408||p2!==408)$fatal(1,"bottom clamp");
    reset;btn=16;frame;btn=0;if(dut.serving)$fatal(1,"serve");
    // Independent trigonometric reference verifies every table entry, direction,
    // magnitude, and preservation of the four fractional position bits.
    for(l=0;l<4;l=l+1)for(a=0;a<8;a=a+1)for(d=0;d<4;d=d+1)begin
      dut.hits=l*3;dut.angle=a;dut.dx=(d&1)!=0;dut.dy=(d&2)!=0;
      dut.ball_x=5059;dut.ball_y=3781;
      theta=(10.0+5.0*a)*3.141592653589793/180.0;
      evx=$rtoi(16.0*(4+2*l)*$cos(theta)+0.5);
      evy=$rtoi(16.0*(4+2*l)*$sin(theta)+0.5);
      frame;
      if(x!==5059+((d&1)?evx:-evx)||y!==3781+((d&2)?evy:-evy))
        $fatal(1,"vector mismatch level=%0d angle=%0d direction=%0d",l,a,d);
      mag=$sqrt(1.0*evx*evx+1.0*evy*evy)/16.0;
      if(mag<(4+2*l)-0.05||mag>(4+2*l)+0.05)$fatal(1,"speed normalization");
    end
    // Pixel positions travel in 1-pixel increments, not 4-pixel bursts.
    dut.hits=0;dut.angle=0;dut.dx=1;dut.dy=1;dut.ball_x=5056;dut.ball_y=3776;
    for(i=0;i<32;i=i+1)begin
      oldx=x/16;oldy=y/16;frame;travel_x=x/16-oldx;travel_y=y/16-oldy;
      if(travel_x<3||travel_x>4||travel_y<0||travel_y>1)$fatal(1,"coarse pixel stepping");
    end
    // Both sides, all contact offsets including centre and partial edge grazes.
    for(d=0;d<2;d=d+1)for(i=-35;i<=35;i=i+1)begin
      dut.serving=0;dut.hits=0;dut.angle=0;dut.dy=1;dut.dx=d!=0;
      dut.pad1_y=208;dut.pad2_y=208;
      dut.ball_x=d?607*16:25*16;
      dut.ball_y=(236+i)*16-11;
      frame;
      expected=(i<0?-i:i)/4;if(expected>7)expected=7;
      if(dut.hits!==1||dut.angle!==expected[2:0]||dut.dx==d||dut.dy!==(i>=0))
        $fatal(1,"contact side=%0d offset=%0d",d,i);
      frame;if(dut.hits!==1)$fatal(1,"duplicate hit");
    end
    // Each 3rd hit raises speed; time alone does not; maximum saturates.
    dut.hits=0;
    for(i=1;i<=18;i=i+1)begin
      dut.ball_x=25*16;dut.ball_y=236*16;dut.dx=0;dut.dy=1;dut.angle=0;
      frame;expected=i<9?i:9;
      if(dut.hits!==expected[3:0]||dut.speed!==expected/3)$fatal(1,"hit threshold %0d",i);
    end
    dut.hits=9;dut.angle=0;dut.dx=0;dut.ball_x=32*16;dut.ball_y=236*16;
    frame;if(dut.dx!==1||x<=24*16||x>=32*16)$fatal(1,"swept paddle crossing");
    dut.hits=9;dut.angle=7;dut.dx=1;dut.dy=0;dut.ball_x=5056;dut.ball_y=129;
    frame;if(y!==240||dut.dy!==1)$fatal(1,"top reflection loses overshoot");
    dut.dy=1;dut.ball_x=5056;dut.ball_y=7423;
    frame;if(y!==7312||dut.dy!==0)$fatal(1,"bottom reflection loses overshoot");
    dut.angle=0;dut.dx=0;dut.ball_x=16;dut.ball_y=3776;frame;
    if(s2!==1||!dut.serving||dut.hits!==0||x!==5056||y!==3776)$fatal(1,"score/reset rally");
    btn=16;frame;if(dut.serving)$fatal(1,"auto serve");
    reset;if(s1!==0||s2!==0||p1!==208||p2!==208)$fatal(1,"reset");
    $display("PASS: 128 normalized vectors, subpixel travel, 142 mirrored contacts, speed thresholds, paddle rate/clamps, swept collisions, wall reflection, scores/reset/serve");
    $finish;
  end
endmodule
