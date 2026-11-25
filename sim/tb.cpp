// Verilator harness for the Pong VGA design.
//
//   ./Vtop <frames> <mode> [seed] [outdir] [dump_every]
//     mode: idle | ai | lazy | random | script:<file>
//
// Every frame is rendered from the uo_out pins and compared, pixel by pixel,
// against an independent C++ reference model of the game and of the picture
// (Engineering 5 at sunset, goose ball, pencil and pen paddles). Sync timing is
// checked on the pins against the VESA 640x480@60 numbers. Scores are
// checked on uio_out. Exit code != 0 on any mismatch.
#include "Vtop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cmath>
#include <algorithm>

static Vtop *t;
static uint64_t cyc = 0;
static void tick() {
  t->clk = 0; t->eval();
  t->clk = 1; t->eval();
  cyc++;
}

// ------------------------------------------------------------ reference model
struct Model {
  int X=316*16,Y=236*16,dx=1,dy=1,serving=1;
  int p1=208,p2=208,s1=0,s2=0,hits=0,angle=3;
  int points=0,paddle_hits=0,wall_bounces=0,max_speed=0;
  int speed_frames[6]={0,0,0,0,0,0},angle_hits[8]={0,0,0,0,0,0,0,0};
  // The picture, written independently of the Verilog from the same
  // description: Engineering 5 at sunset, a Canada goose for the ball, a
  // pencil and a pen for the paddles. Returns the colour as 0xRGB, two bits
  // per channel (0..3 each). x, y are the visible pixel (0..639, 0..479).
  static int c6(int rrggbb) {                       // 6-bit RRGGBB -> 0xRGB
    return ((rrggbb>>4)&3)<<8 | ((rrggbb>>2)&3)<<4 | (rrggbb&3);
  }
  int pixel(int x,int y) const {
    int bit=0; (void)bit;
    int bx=(x-X/16)&1023, by=((y&511)-Y/16)&511;     // wrap like the hardware
    int hx=x>>3, vy=y>>3, hb=x>>5, vb=y>>5;
    int bayer=(((x^y)&1)<<1)|(y&1);
    int chk=bayer>>1;
    // goose: 8x8 art at triple size (24x24), centred on the ball, facing its way
    static const char *goose_art[8]={"......KK","......KW","......K.",".....K..",
                                     "BBBBBK..",".BBBBBB.","..BBBB..","...K.K.."};
    int gbx=(bx+8)&1023, gby=(by+8)&511;
    if(gbx<24 && gby<24){
      int gx=dx ? gbx/3 : 7-gbx/3, gy=gby/3;
      char ch=goose_art[gy][gx];
      if(ch=='K')return c6(0b000000);
      if(ch=='W')return c6(0b111111);
      if(ch=='B')return c6(0b010101);
    }
    // pencil (left, yellow) and pen (right, blue) in the paddle boxes
    int py=x>=512 ? p2 : p1;
    int pd=((y&511)-py)&511;
    if((hx==2 || hx==77) && pd<64){
      int pr=pd, pc=x&7; bool outer=pc==0||pc==7, pen=x>=512;
      int c=-1;
      if(pr<6)        c=outer?-1: pen?0b000010:0b111010;
      else if(pr<10)  c=outer?-1: pr==7?0b010101: pen?0b111111:0b101010;
      else if(pr<54)  c=outer?-1: pc<3?(pen?0b000111:0b111000)
                                : pc<5?(pen?0b011011:0b111101)
                                :      (pen?0b000110:0b101000);
      else if(pr<60){ int lo=pr<56?1:pr<58?2:3;
                      c=(pc>=lo && pc<=7-lo)?(pen?0b101010:0b111001):-1; }
      else            c=(pc==3||pc==4)?(pen?0b000010:0b010101):-1;
      if(c>=0)return c6(c);
    }
    // end walls: black with a UW gold stripe
    if(y<8 || y>=472) return c6((y==3||y==4||y==475||y==476)?0b111000:0);
    // ground
    if(vy>=56) return c6(0b101010);                                      // sidewalk
    bool stair_x=hx>=36 && hx<44;
    if((hx==35||hx==44) && vy>=44 && vy<54) return c6(y>=352&&y<356 ? 0b111111 : 0b101010);
    if(stair_x && y>=352 && y<356) return c6(0b101010);                  // landing
    if(stair_x && vy>=44 && vy<54){
      if(x==298||x==319||x==341) return c6(0b111111);                    // handrails
      return c6((y&3)==0 ? 0b010101 : 0b101010);                         // steps
    }
    if(hx>=34 && hx<46 && vy>=54) return c6((y&15)==0 ? 0b100101 : 0b101010); // walkway
    if(vy>=48){
      if(vy==52 && ((x&7)==0 || (y&7)==0)) return c6(0);                 // fence
      return c6((bayer&2) ? 0b001000 : 0b000100);                        // grass
    }
    // building
    bool bldg_x=hb>=1 && hb<19;
    bool roof=hx>=15 && hx<65 && vy>=9 && vy<12;
    bool mullion=(x&7)==0;
    if(roof){
      if(hx>=37 && hx<43) return c6((mullion||(y&7)==0) ? 0b010101 : 0b011011);
      return c6(((x&31)==0 || (y&3)==0) ? 0 : 0b010101);
    }
    bool right_part=hb>=9;
    bool glass_lower=bldg_x && (right_part ? vb>=8 : vb>=10) && vy<48;
    bool facade=bldg_x && vb>=3 && vy<48 && !glass_lower;
    bool trim=bldg_x && vy>=12 && vy<48 && (x/2==16 || x/2==303);
    bool cornice=bldg_x && y/2==48;
    if(trim||cornice) return c6(0b111111);
    if(hx>=36 && hx<44 && vb>=5 && vb<8){                                // atrium
      if(x/4==80) return c6(0b111111);                                   // column
      if(y/4==63 && (((x>>1)^(x>>3))&1)) return c6(0b001000);            // plants
      if((y&31)<2 || (y&31)==26) return c6(0b101010);                    // slabs, rail
      return c6((x&15)==0 ? 0b010110 : 0b000001);
    }
    if(hx>=36 && hx<44 && y/4==79) return c6(0b010101);                  // canopy
    if(hx>=37 && hx<43 && vy>=40 && vy<44){                              // doors
      if((x&15)==0 || vy==40) return c6(0b101010);
      return c6(0b000001);
    }
    if(hx>=10 && hx<24 && vy>=42 && vy<48){                              // concrete wall
      if(vy==42 && ((y>>1)&3)==0) return c6(0b111111);
      bool vent=(hx==21||hx==12) && vy==43 && ((y>>1)&1);
      return c6((vent || (x&31)==0) ? 0b010101 : 0b101010);
    }
    if(glass_lower){
      if(mullion || (y&31)<2) return c6(0b101010);
      if(((y>>3)&3)==1) return c6(0b011010);                             // reflection
      return c6((bayer&1) ? 0b001010 : 0b000101);
    }
    if(facade){
      int pu=((~x>>5)&1)<<5 | (x&31);                                    // 0..63 across a panel
      if((y&31)==0 || pu==0) return c6(0b101010);                        // panel edges
      int ux=(pu&32) ? (pu&31) : (~pu&31);
      int v4=((y>>4)&1) ? (y&15) : (~y&15);
      if(2*v4>ux) return c6(((y>>4)&1) ? 0b111111 : (chk ? 0b010101 : 0b101010)); // bottom, top
      return c6((pu&32) ? (chk ? 0b111111 : 0b101010) : 0b101010);       // right, left
    }
    // clouds
    int cfx=(x&15)^(((x>>4)&1)?0:15), efx=(x&15)^(((x>>4)&1)?15:0), cfy=(y&15)^(((y>>4)&1)?0:15);
    bool cols=(hb>=2&&hb<5)||(hb>=15&&hb<17), inner=(x>=80&&x<144)||(x>=496&&x<528);
    if(vb==1 && ((cols && cfx+cfy<19) || (inner && efx+cfy<12)))
      return c6(bayer==3 ? 0b110110 : 0b111010);
    // sunset sky
    static const int keys[4]={0b010010,0b100110,0b110101,0b111001};
    int k=(y>=256) ? 3 : (y>>6)&3;
    int k2=std::min(k+1,3);
    return c6(((y>>4)&3)>bayer ? keys[k2] : keys[k]);
  }
  void end_of_frame(int ui) { physics(ui); }
  void physics(int ui) {
    auto move=[](int p,bool up,bool dn) {
      return std::clamp(p+(up==dn?0:up?-12:12),8,408);
    };
    p1=move(p1,ui&1,ui&2); p2=move(p2,ui&4,ui&8);
    if(serving) {
      X=316*16;Y=236*16;hits=0;angle=3;
      if(ui&16)serving=0;
      return;
    }
    int level=hits/3, speed=4+2*level;
    double theta=(10+5*angle)*3.14159265358979323846/180;
    int vx=std::lround(16*speed*std::cos(theta));
    int vy=std::lround(16*speed*std::sin(theta));
    int nx=X+(dx?vx:-vx),ny=Y+(dy?vy:-vy);
    bool top=ny<8*16,bot=ny>464*16;
    int next_dy=dy;
    if(top){ny=16*16-ny;next_dy=1;wall_bounces++;}
    if(bot){ny=928*16-ny;next_dy=0;wall_bounces++;}
    bool left=!dx && X>=24*16 && nx<=24*16 && ny<(p1+64)*16 && ny+128>p1*16;
    bool right=dx && X<=608*16 && nx>=608*16 && ny<(p2+64)*16 && ny+128>p2*16;
    speed_frames[level]++;max_speed=std::max(max_speed,level);
    if(nx<0 || nx>=640*16) {
      if(nx<0)s2=(s2+1)%16;else s1=(s1+1)%16;
      points++;X=316*16;Y=236*16;serving=1;hits=0;angle=3;
      return;
    }
    dy=next_dy;
    if(left || right) {
      int offset=ny/16+4-((right?p2:p1)+32);
      angle=std::min(7,std::abs(offset)/4);
      dx=left;dy=top?1:bot?0:offset>=0;
      hits=std::min(15,hits+1);paddle_hits++;angle_hits[angle]++;
      nx=2*(left?24:608)*16-nx;
    }
    X=nx;Y=ny;
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vtop;
  int frames = argc > 1 ? atoi(argv[1]) : 3;
  std::string mode = argc > 2 ? argv[2] : "idle";
  unsigned seed = argc > 3 ? atoi(argv[3]) : 1;
  std::string outdir = argc > 4 ? argv[4] : "";
  int dump_every = argc > 5 ? atoi(argv[5]) : 0;
  srand(seed);
  std::vector<int> script;
  if (mode.rfind("script:", 0) == 0) {
    FILE *f = fopen(mode.c_str() + 7, "r");
    unsigned v;
    while (fscanf(f, "%x", &v) == 1) script.push_back(v);
    fclose(f);
  }

  // reset
  t->ena = 1; t->ui_in = 0; t->uio_in = 0; t->rst_n = 0;
  for (int i = 0; i < 10; i++) tick();
  t->rst_n = 1;
  // Release traverses the two reset synchronizer stages before pixel 0.
  for (int i = 0; i < 2; i++) tick();
  tick(); // one shared RGB/sync output stage: displayed pixel 0

  Model m;
  int errors = 0, pix_errors = 0;
  auto err = [&](const char *msg, int a = 0, int b = 0) {
    if (errors++ < 20) printf("ERROR @frame cyc=%llu: %s (%d, %d)\n", (unsigned long long)cyc, msg, a, b);
  };
  static uint8_t img[480][640][3];
  int prev_h = 1, prev_v = 1, nh = 0, nv = 0;
  uint64_t last_hfall = 0, last_vfall = 0;
  int ui = 0, hold = 0;
  bool max_both_pressed = false;

  // Beam position below tracks the displayed pixel, one clock behind the
  // internal counters because RGB and both syncs share an output stage.
  int hc = 0, vc = 0;  // our own beam position, reset-aligned with the DUT
  for (int fr = 0; fr < frames; fr++) {
    // ---- inputs for this frame (held for the whole frame)
    if (!script.empty()) ui = script[fr < (int)script.size() ? fr : script.size() - 1];
    else if (mode == "ai" || mode == "lazy" || mode == "ailate" || mode == "rally") {
      int c=m.Y/16+4;
      ui=0x10;
      int aim1=(fr/70)%48+8,aim2=(fr/90)%48+8;
      if(mode=="rally" || mode=="ailate")aim1=aim2=32;
      if(c<m.p1+aim1-6)ui|=1;else if(c>m.p1+aim1+6)ui|=2;
      bool lazy=(mode=="lazy" && (fr/300)%2) || (mode=="ailate" && m.hits>=15);
      if(lazy)ui|=8;
      else if(c<m.p2+aim2-6)ui|=4;else if(c>m.p2+aim2+6)ui|=8;
    } else if (mode == "edge") {
      // Park P2 at row 100: the first serve contacts its outermost band.
      ui = fr < 12 ? 0x18 : 0x10;
    } else if (mode == "random") {
      if (hold-- <= 0) { ui = rand() & 0x1f; hold = rand() % 40; }
      if ((ui & 3) == 3 || (ui & 12) == 12) max_both_pressed = true;
    }
    t->ui_in = ui;

    // ---- simulate one frame (800 x 525 clocks)
    for (int i = 0; i < 800 * 525; i++) {
      if (hc < 640 && vc < 480) {
        uint8_t o = t->uo_out;
        int r = ((o >> 0) & 1) << 1 | ((o >> 4) & 1);
        int g = ((o >> 1) & 1) << 1 | ((o >> 5) & 1);
        int b = ((o >> 2) & 1) << 1 | ((o >> 6) & 1);
        int got = r << 8 | g << 4 | b;
        img[vc][hc][0] = r; img[vc][hc][1] = g; img[vc][hc][2] = b;
        int want = m.pixel(hc, vc);
        if (got != want) { pix_errors++; if (pix_errors < 10) printf("PIX f%d (%d,%d) got %03x want %03x\n", fr, hc, vc, got, want); }
      } else if (t->uo_out & 0x77) {
        err("RGB not blank outside the visible area", hc, vc);
      }
      tick();
      if (++hc == 800) { hc = 0; if (++vc == 525) vc = 0; }
      // sync checks on the pins
      int H = (t->uo_out >> 7) & 1, V = (t->uo_out >> 3) & 1;
      if (prev_h && !H) {
        if (hc != 656) err("hsync fell at wrong hcount", hc, vc);
        if (last_hfall && cyc - last_hfall != 800) err("hsync period", (int)(cyc - last_hfall));
        last_hfall = cyc; nh++;
      }
      if (!prev_h && H && hc != 752) err("hsync rose at wrong hcount", hc, vc);
      if (prev_v && !V) {
        if (!(vc == 490 && hc == 0)) err("vsync fell at wrong place", hc, vc);
        if (last_vfall && cyc - last_vfall != 800 * 525) err("vsync period", (int)(cyc - last_vfall));
        last_vfall = cyc; nv++;
      }
      if (!prev_v && V && !(vc == 492 && hc == 0)) err("vsync rose at wrong place", hc, vc);
      prev_h = H; prev_v = V;
    }
    // ---- advance the reference model and compare scores
    m.end_of_frame(ui);
    int uio = t->uio_out;
    if (t->uio_oe != 0xff) err("uio_oe not 0xff");
    if ((uio & 15) != m.s1 || (uio >> 4) != m.s2) err("score mismatch", uio, m.s1 | m.s2 << 4);

    if (dump_every && fr % dump_every == 0 && !outdir.empty()) {
      char fn[512];
      snprintf(fn, sizeof fn, "%s/f%05d.ppm", outdir.c_str(), fr);
      FILE *f = fopen(fn, "wb");
      fprintf(f, "P6 640 480 3\n");
      fwrite(img, 1, sizeof img, f);
      fclose(f);
    }
    if (frames <= 40 || fr % 100 == 0 || getenv("VERBOSE"))
      printf("F%05d ui=%02x ball=(%3d,%3d) d=(%d,%d) serve=%d pads=(%3d,%3d) score=%d:%d hits=%d\n",
             fr, ui, m.X/16, m.Y/16, m.dx, m.dy, m.serving, m.p1, m.p2, m.s1, m.s2, m.hits);
  }
  printf("SUMMARY frames=%d hsync=%d vsync=%d points=%d paddle_hit_px_rows=%d wall_bounces=%d "
         "score=%d:%d max_speed=%d frames_at_speed=%d/%d/%d/%d/%d/%d pixel_mismatches=%d errors=%d%s\n",
         frames, nh, nv, m.points, m.paddle_hits, m.wall_bounces, m.s1, m.s2, m.max_speed,
         m.speed_frames[0], m.speed_frames[1], m.speed_frames[2], m.speed_frames[3],
         m.speed_frames[4], m.speed_frames[5], pix_errors, errors,
         max_both_pressed ? " (both-buttons exercised)" : "");
  printf("ANGLE_HITS");
  for(int a=0;a<8;a++)printf(" %ddeg=%d",10+5*a,m.angle_hits[a]);
  printf("\n");
  delete t;
  return (errors || pix_errors) ? 1 : 0;
}
