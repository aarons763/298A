// Verilator harness for the Pong VGA design.
//
//   ./Vtop <frames> <mode> [seed] [outdir] [dump_every]
//     mode: idle | ai | lazy | random | script:<file>
//
// Every frame is rendered from the uo_out pins and compared, pixel by pixel,
// against an independent C++ reference model of the game. Sync timing is
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
  int speed_frames[4]={0,0,0,0},angle_hits[8]={0,0,0,0,0,0,0,0};
  int pixel(int x,int y) const {
    bool ball=x>=X/16 && x<X/16+8 && y>=Y/16 && y<Y/16+8;
    bool pad=((x>=16 && x<24)&&(y>=p1 && y<p1+64)) ||
             ((x>=616 && x<624)&&(y>=p2 && y<p2+64));
    if(ball||pad)return 3;
    return y<8 || y>=472 ? 1 : 0;
  }
  void end_of_frame(int ui) {
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
      hits=std::min(9,hits+1);paddle_hits++;angle_hits[angle]++;
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

  Model m;
  int errors = 0, pix_errors = 0;
  auto err = [&](const char *msg, int a = 0, int b = 0) {
    if (errors++ < 20) printf("ERROR @frame cyc=%llu: %s (%d, %d)\n", (unsigned long long)cyc, msg, a, b);
  };
  static uint8_t img[480][640];
  int prev_h = 1, prev_v = 1, nh = 0, nv = 0;
  uint64_t last_hfall = 0, last_vfall = 0;
  int ui = 0, hold = 0;
  bool max_both_pressed = false;

  // Pixel (x, y) is on the pins while the design's hcount = x, vcount = y,
  // i.e. during the clock cycle before the edge that moves to x+1.
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
      bool lazy=(mode=="lazy" && (fr/300)%2) || (mode=="ailate" && m.hits>=9);
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
        if (r != g || g != b) err("non-grey pixel", hc, vc);
        img[vc][hc] = r;
        int want = m.pixel(hc, vc);
        if (r != want) { pix_errors++; if (pix_errors < 10) printf("PIX f%d (%d,%d) got %d want %d\n", fr, hc, vc, r, want); }
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
        if (!(vc == 490 && hc == 1)) err("vsync fell at wrong place", hc, vc);
        if (last_vfall && cyc - last_vfall != 800 * 525) err("vsync period", (int)(cyc - last_vfall));
        last_vfall = cyc; nv++;
      }
      if (!prev_v && V && !(vc == 492 && hc == 1)) err("vsync rose at wrong place", hc, vc);
      prev_h = H; prev_v = V;
    }
    // ---- advance the reference model and compare scores
    m.end_of_frame(ui);
    int uio = t->uio_out;
    if (t->uio_oe != 0xff) err("uio_oe not 0xff");
    if ((uio & 15) != m.s1 || (uio >> 4) != m.s2) err("score mismatch", uio, m.s1 | m.s2 << 4);

    if (dump_every && fr % dump_every == 0 && !outdir.empty()) {
      char fn[512];
      snprintf(fn, sizeof fn, "%s/f%05d.pgm", outdir.c_str(), fr);
      FILE *f = fopen(fn, "wb");
      fprintf(f, "P5 640 480 3\n");
      fwrite(img, 1, sizeof img, f);
      fclose(f);
    }
    if (frames <= 40 || fr % 100 == 0 || getenv("VERBOSE"))
      printf("F%05d ui=%02x ball=(%3d,%3d) d=(%d,%d) serve=%d pads=(%3d,%3d) score=%d:%d hits=%d\n",
             fr, ui, m.X/16, m.Y/16, m.dx, m.dy, m.serving, m.p1, m.p2, m.s1, m.s2, m.hits);
  }
  printf("SUMMARY frames=%d hsync=%d vsync=%d points=%d paddle_hit_px_rows=%d wall_bounces=%d "
         "score=%d:%d max_speed=%d frames_at_speed=%d/%d/%d/%d pixel_mismatches=%d errors=%d%s\n",
         frames, nh, nv, m.points, m.paddle_hits, m.wall_bounces, m.s1, m.s2, m.max_speed,
         m.speed_frames[0], m.speed_frames[1], m.speed_frames[2], m.speed_frames[3], pix_errors, errors,
         max_both_pressed ? " (both-buttons exercised)" : "");
  printf("ANGLE_HITS");
  for(int a=0;a<8;a++)printf(" %ddeg=%d",10+5*a,m.angle_hits[a]);
  printf("\n");
  delete t;
  return (errors || pix_errors) ? 1 : 0;
}
