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

static Vtop *t;
static uint64_t cyc = 0;
static void tick() {
  t->clk = 0; t->eval();
  t->clk = 1; t->eval();
  cyc++;
}

// ------------------------------------------------------------ reference model
struct Model {
  int X = 79, Y = 59;       // ball top-left, 4-px units (X is mod 200)
  int dx = 1, dy = 1, serving = 1;
  int p1 = 52, p2 = 52, s1 = 0, s2 = 0;
  int points = 0, paddle_hits = 0, wall_bounces = 0;
  int hits = 0;             // paddle hits this rally (saturates at 15)
  int max_speed = 0;        // highest speed level reached (0..3)
  int speed_frames[4] = {0, 0, 0, 0};

  static bool ball_col(int u, int X) { return u == X || u == (X + 1) % 200; }

  // pixel colour (0..3 per channel, grey = 1, white = 3) of the model frame
  int pixel(int x, int y) const {
    int xu = x / 4, yu = y / 4;
    bool ball = ball_col(xu, X) && (yu == Y || yu == Y + 1);
    bool pad = false;
    if (x >= 16 && x < 24) pad = yu >= p1 && yu < p1 + 16;
    if (x >= 616 && x < 624) pad = yu >= p2 && yu < p2 + 16;
    if (ball || pad) return 3;
    bool net = (xu == 80) && (y & 16);
    bool wall = yu < 2 || yu >= 118;
    return (net || wall) ? 1 : 0;
  }

  // collisions during the frame (raster order; last overlapping pixel wins)
  void collide() {
    for (int yu = Y; yu <= Y + 1; yu++)
      for (int side = 0; side < 2; side++) {
        int p = side ? p2 : p1;
        int c0 = side ? 154 : 4;  // paddle units c0, c0+1
        bool xo = ball_col(c0, X) || ball_col(c0 + 1, X);
        if (xo && yu >= p && yu < p + 16) {
          int away = side ? 0 : 1;
          if (dx != away && hits < 15) hits++;   // a hit that turns the ball
          dx = away;
          dy = (yu - p) >= 8;
          paddle_hits++;
        }
      }
  }

  void end_of_frame(int ui) {
    int L = hits >> 2, steps = 1 + (L >> 1) + ((L & 1) && (Y & 1));
    if (!serving) {
      X = (X + (dx ? steps : 200 - steps)) % 200;           // line 524
      speed_frames[L]++;
      if (L > max_speed) max_speed = L;
    }
    bool out = X >= 160;
    bool at_top = Y == 2, at_bot = Y == 116;
    if (at_top) { dy = 1; wall_bounces++; }
    else if (at_bot) { dy = 0; wall_bounces++; }
    bool u1 = ui & 1, d1 = ui & 2, u2 = ui & 4, d2 = ui & 8, sv = ui & 16;
    if (u1 && !d1 && p1 != 2) p1--;
    if (d1 && !u1 && p1 != 102) p1++;
    if (u2 && !d2 && p2 != 2) p2--;
    if (d2 && !u2 && p2 != 102) p2++;
    if (out) { if (dx) s1 = (s1 + 1) & 15; else s2 = (s2 + 1) & 15; points++; }
    bool park = serving || out;
    serving = out || (serving && !sv);
    if (park) { X = 79; Y = 59; hits = 0; }
    if (!serving) Y += dy ? 1 : -1;                           // next frame
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
    else if (mode == "ai" || mode == "lazy" || mode == "ailate") {
      int c = m.Y + 1;  // ball centre row
      ui = 0x10;        // keep SERVE held -> auto-serve
      int aim1 = (fr / 50) % 12, aim2 = (fr / 70) % 12;  // vary contact point
      if (c < m.p1 + 2 + aim1) ui |= 1; else if (c > m.p1 + 3 + aim1) ui |= 2;
      bool lazy = (mode == "lazy" && (fr / 300) % 2)      // P2 sleeps sometimes
               || (mode == "ailate" && m.hits >= 13);     // P2 gives up at top speed
      if (!lazy) { if (c < m.p2 + 2 + aim2) ui |= 4; else if (c > m.p2 + 3 + aim2) ui |= 8; }
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
    m.collide();
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
             fr, ui, m.X, m.Y, m.dx, m.dy, m.serving, m.p1, m.p2, m.s1, m.s2, m.hits);
  }
  printf("SUMMARY frames=%d hsync=%d vsync=%d points=%d paddle_hit_px_rows=%d wall_bounces=%d "
         "score=%d:%d max_speed=%d frames_at_speed=%d/%d/%d/%d pixel_mismatches=%d errors=%d%s\n",
         frames, nh, nv, m.points, m.paddle_hits, m.wall_bounces, m.s1, m.s2, m.max_speed,
         m.speed_frames[0], m.speed_frames[1], m.speed_frames[2], m.speed_frames[3], pix_errors, errors,
         max_both_pressed ? " (both-buttons exercised)" : "");
  delete t;
  return (errors || pix_errors) ? 1 : 0;
}
