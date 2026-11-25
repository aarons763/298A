# SPDX-License-Identifier: Apache-2.0
#
# ECE 298A Pong VGA - game logic tests (pong_game)
#
# These tests drive pong_game on its own through tb_game.v. Python pulses
# frame_end itself, so one game frame takes a few clocks instead of the
# 420,000 a real video frame takes. That makes long rallies practical.
#
#   G1 reset state      G2 paddles      G3 serve      G4 wall bounce
#   G5 paddle bounce    G6 speed tiers  G7 scoring    + a long rally
#
# Run from test/:  make -f Makefile.game          (all, a few seconds)
#                  make -f Makefile.game COCOTB_TEST_FILTER=test_rally
# Waveform:        gtkwave tb_game.fst
#
# Units: positions are Q4 fixed point, 16 steps per pixel. ball_x = 5056
# means pixel 5056 / 16 = 316. The waveform also shows ball_px and ball_py,
# the same positions in whole pixels.

import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

# ------------------------------------------------------------------ the rules
PX = 16                               # Q4: sub-pixel steps per pixel
SERVE_X, SERVE_Y = 5056, 3776         # ball parked at pixel (316, 236)
PAD_START = 208                       # paddle top edge after reset, pixels
PAD_TOP, PAD_BOTTOM = 8, 408          # paddle travel limits, pixels
PAD_STEP = 12                         # paddle move per frame, pixels
PAD_HEIGHT = 64
TOP_LIMIT, BOTTOM_LIMIT = 128, 7424   # ball top edge limits: 8 px and 464 px
LEFT_FACE, RIGHT_FACE = 384, 9728     # where the ball meets a paddle: 24 px, 608 px
COURT_RIGHT = 10240                   # 640 px: past this the ball is out

P1_UP, P1_DOWN, P2_UP, P2_DOWN, SERVE = 1, 2, 4, 8, 16

# velocity table from project.v, index = speed * 8 + angle, values (vx, vy)
# in sixteenths of a pixel per frame
VELOCITY = [
    (63, 11), (62, 17), (60, 22), (58, 27), (55, 32), (52, 37), (49, 41), (45, 45),
    (95, 17), (93, 25), (90, 33), (87, 41), (83, 48), (79, 55), (74, 62), (68, 68),
    (126, 22), (124, 33), (120, 44), (116, 54), (111, 64), (105, 73), (98, 82), (91, 91),
    (158, 28), (155, 41), (150, 55), (145, 68), (139, 80), (131, 92), (123, 103), (113, 113),
    (189, 33), (185, 50), (180, 66), (174, 81), (166, 96), (157, 110), (147, 123), (136, 136),
    (221, 39), (216, 58), (210, 77), (203, 95), (194, 112), (183, 128), (172, 144), (158, 158),
]
ANGLE_DEG = [10, 15, 20, 25, 30, 35, 40, 45]

STATE = ("ball_x", "ball_y", "pad1_y", "pad2_y", "score1", "score2",
         "dx", "dy", "serving", "hits", "angle")


def speed_of(hits):
    """Speed tier from paddle hits this rally: one step every 3 hits,
    0-2 -> 0, 3-5 -> 1, ... 12-14 -> 4, 15 -> 5."""
    return min(hits // 3, 5)


def velocity(hits, angle):
    return VELOCITY[speed_of(hits) * 8 + angle]


# ------------------------------------------------------------------ helpers
async def start(dut):
    """Start a 100 MHz clock (only the order of events matters) and reset."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.btn.value = 0
    dut.frame_end.value = 0
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


def state(dut):
    """Read every game register (including the internal ones) into a dict."""
    return {name: int(getattr(dut.game, name).value) for name in STATE}


async def frame(dut, btn=0):
    """One game frame: hold the buttons, raise frame_end for exactly one rising
    clock edge (that edge loads the next state), then return the new state."""
    dut.btn.value = btn
    dut.frame_end.value = 1
    await FallingEdge(dut.clk)
    dut.frame_end.value = 0
    await FallingEdge(dut.clk)        # one quiet clock, so frames are easy to see
    return state(dut)


async def place(dut, **values):
    """Put the game into a chosen state by writing its registers directly.
    The game only updates on frame_end, so the values stay until the next frame."""
    defaults = dict(serving=0, hits=0, angle=0, pad1_y=PAD_START, pad2_y=PAD_START)
    defaults.update(values)
    for name, value in defaults.items():
        getattr(dut.game, name).value = value
    await FallingEdge(dut.clk)


# ------------------------------------------------------------------ G1
@cocotb.test()
async def test_reset_state(dut):
    """G1: after reset the ball is parked at the centre, waiting for a serve."""
    await start(dut)
    assert state(dut) == dict(ball_x=SERVE_X, ball_y=SERVE_Y, pad1_y=PAD_START,
                              pad2_y=PAD_START, score1=0, score2=0, dx=1, dy=1,
                              serving=1, hits=0, angle=3)
    assert int(dut.ball_px.value) == 316 and int(dut.ball_py.value) == 236


# ------------------------------------------------------------------ G2
def paddle_model(pos, up, down):
    if up and not down:
        return PAD_TOP if pos < PAD_TOP + PAD_STEP else pos - PAD_STEP
    if down and not up:
        return PAD_BOTTOM if pos > PAD_BOTTOM - PAD_STEP else pos + PAD_STEP
    return pos


@cocotb.test()
async def test_paddles(dut):
    """G2: a held button moves its paddle 12 px per frame until it stops at
    8 px (top) or 408 px (bottom); both buttons together do nothing."""
    await start(dut)
    p1 = p2 = PAD_START
    for n in range(20):                       # P1 holds up, P2 holds down
        s = await frame(dut, P1_UP | P2_DOWN)
        p1, p2 = paddle_model(p1, True, False), paddle_model(p2, False, True)
        assert (s["pad1_y"], s["pad2_y"]) == (p1, p2), f"frame {n}: {s}"
    assert (p1, p2) == (PAD_TOP, PAD_BOTTOM)  # both reached their limits
    s = await frame(dut, P1_UP | P1_DOWN | P2_UP | P2_DOWN)
    assert (s["pad1_y"], s["pad2_y"]) == (PAD_TOP, PAD_BOTTOM), "both buttons must not move"
    assert (s["ball_x"], s["ball_y"], s["serving"]) == (SERVE_X, SERVE_Y, 1), \
        "the ball stays parked without a serve"


# ------------------------------------------------------------------ G3
@cocotb.test()
async def test_serve(dut):
    """G3: the ball waits until SERVE, then leaves at 25 degrees, 4 px per frame."""
    await start(dut)
    for _ in range(5):
        s = await frame(dut)
        assert (s["ball_x"], s["ball_y"], s["serving"]) == (SERVE_X, SERVE_Y, 1)
    s = await frame(dut, SERVE)               # this frame only releases the ball
    assert s["serving"] == 0 and (s["ball_x"], s["ball_y"]) == (SERVE_X, SERVE_Y)
    vx, vy = velocity(0, 3)                   # speed 0, angle 3 (25 degrees)
    for n in range(1, 4):
        s = await frame(dut)
        assert (s["ball_x"], s["ball_y"]) == (SERVE_X + n * vx, SERVE_Y + n * vy)
    deg = math.degrees(math.atan2(vy, vx))
    speed = math.hypot(vx, vy) / PX
    dut._log.info(f"serve: {vx}/16 px right, {vy}/16 px down per frame = "
                  f"{deg:.1f} degrees at {speed:.2f} px/frame")
    assert abs(deg - 25) < 0.5 and abs(speed - 4) < 0.1


# ------------------------------------------------------------------ G4
@cocotb.test()
async def test_wall_bounce(dut):
    """G4: a ball that would go past a wall is reflected back by the same
    amount it overshot, and its vertical direction flips."""
    await start(dut)
    vx, vy = velocity(0, 0)                   # 63, 11

    await place(dut, ball_x=SERVE_X, ball_y=BOTTOM_LIMIT - 5, dx=1, dy=1)
    s = await frame(dut)
    trial = BOTTOM_LIMIT - 5 + vy             # 6 past the bottom limit
    assert s["ball_y"] == BOTTOM_LIMIT - (trial - BOTTOM_LIMIT), s
    assert s["dy"] == 0 and s["ball_x"] == SERVE_X + vx

    await place(dut, ball_x=SERVE_X, ball_y=TOP_LIMIT + 5, dx=1, dy=0)
    s = await frame(dut)
    trial = TOP_LIMIT + 5 - vy                # 6 past the top limit
    assert s["ball_y"] == TOP_LIMIT + (TOP_LIMIT - trial), s
    assert s["dy"] == 1


# ------------------------------------------------------------------ G5
def ball_top_for(pad_y, offset_px):
    """Ball top edge (Q4) that puts the ball's centre offset_px below the
    paddle's centre: ball centre = top + 4, paddle centre = pad + 32."""
    return (pad_y + 28 + offset_px) * PX


@cocotb.test()
async def test_paddle_bounce(dut):
    """G5: hitting a paddle flips the ball's horizontal direction; where it hits
    sets the new angle (centre 10 degrees, each 4 px further out +5, edges 45)."""
    await start(dut)
    vx, vy = velocity(0, 0)

    cases = [   # (offset of ball centre from paddle centre in px, angle, dy after)
        (0, 0, 1),      # dead centre: 10 degrees (offset 0 counts as the lower half)
        (12, 3, 1),     # 12 px below centre: 12 // 4 = 3 -> 25 degrees, going down
        (-12, 3, 0),    # 12 px above centre: 25 degrees, going up
        (32, 7, 1),     # bottom edge: 45 degrees
        (-32, 7, 0),    # top edge: 45 degrees
    ]
    for offset, angle, dy in cases:
        # left paddle: ball moving left, about to cross the paddle face at 24 px
        y_after = ball_top_for(PAD_START, offset)
        await place(dut, ball_x=LEFT_FACE + 30, ball_y=y_after + vy, dx=0, dy=0)
        s = await frame(dut)
        x_trial = LEFT_FACE + 30 - vx
        assert s["dx"] == 1, f"offset {offset}: should now move right"
        assert s["ball_x"] == 2 * LEFT_FACE - x_trial, f"offset {offset}: {s}"
        assert (s["angle"], s["dy"], s["hits"]) == (angle, dy, 1), f"offset {offset}: {s}"
        dut._log.info(f"left paddle, {offset:+d} px from centre -> "
                      f"{ANGLE_DEG[s['angle']]} degrees, {'down' if s['dy'] else 'up'}")

    # right paddle, centre hit
    await place(dut, ball_x=RIGHT_FACE - 30, ball_y=ball_top_for(PAD_START, 0) - vy, dx=1, dy=1)
    s = await frame(dut)
    assert s["dx"] == 0 and s["ball_x"] == 2 * RIGHT_FACE - (RIGHT_FACE - 30 + vx)
    assert s["hits"] == 1

    # no paddle there: the ball passes the face and keeps going
    await place(dut, ball_x=LEFT_FACE + 30, ball_y=SERVE_Y, dx=0, dy=0, pad1_y=PAD_TOP)
    s = await frame(dut)
    assert s["dx"] == 0 and s["hits"] == 0 and s["ball_x"] == LEFT_FACE + 30 - vx

    # the hit counter stops at 15
    await place(dut, ball_x=LEFT_FACE + 30, ball_y=ball_top_for(PAD_START, 0) - vy,
                dx=0, dy=1, hits=15)
    s = await frame(dut)
    assert s["dx"] == 1 and s["hits"] == 15


# ------------------------------------------------------------------ G6
@cocotb.test()
async def test_speed_tiers(dut):
    """G6: the ball speeds up after 3, 6, 9, 12 and 15 paddle hits: about 4,
    6, 8, 10, 12 and 14 px per frame, at the same angle."""
    await start(dut)
    for hits, want_px in [(0, 4), (2, 4), (3, 6), (6, 8), (9, 10), (11, 10), (12, 12), (15, 14)]:
        await place(dut, ball_x=SERVE_X, ball_y=SERVE_Y, dx=1, dy=1, hits=hits)
        s = await frame(dut)
        step_x, step_y = s["ball_x"] - SERVE_X, s["ball_y"] - SERVE_Y
        assert (step_x, step_y) == velocity(hits, 0), f"hits {hits}: step {step_x}, {step_y}"
        px = math.hypot(step_x, step_y) / PX
        dut._log.info(f"{hits} hits: moves {step_x}/16, {step_y}/16 per frame = {px:.2f} px/frame")
        assert abs(px - want_px) < 0.1

    # the 3rd hit itself raises the speed for the following frames
    vx, _ = velocity(2, 0)
    await place(dut, ball_x=LEFT_FACE + 30, ball_y=ball_top_for(PAD_START, 0), dx=0, dy=1, hits=2)
    s = await frame(dut)
    assert s["hits"] == 3
    before = s["ball_x"]
    s = await frame(dut)
    assert s["ball_x"] - before == velocity(3, s["angle"])[0]


# ------------------------------------------------------------------ G7
@cocotb.test()
async def test_scoring(dut):
    """G7: a ball that gets past a paddle scores for the other player, then the
    ball is parked at the centre for the next serve."""
    await start(dut)
    parked = dict(ball_x=SERVE_X, ball_y=SERVE_Y, serving=1, hits=0, angle=3)

    # past the right paddle (moved out of the way): player 1 scores
    await place(dut, ball_x=COURT_RIGHT - 20, ball_y=SERVE_Y, dx=1, dy=1, hits=5, pad2_y=PAD_TOP)
    s = await frame(dut)
    assert (s["score1"], s["score2"]) == (1, 0)
    assert {k: s[k] for k in parked} == parked
    assert s["dx"] == 1, "the next serve goes toward the player who missed"

    # past the left paddle: player 2 scores
    await place(dut, ball_x=20, ball_y=SERVE_Y, dx=0, dy=1, pad1_y=PAD_TOP)
    s = await frame(dut)
    assert (s["score1"], s["score2"]) == (1, 1)
    assert {k: s[k] for k in parked} == parked

    s = await frame(dut, SERVE)
    assert s["serving"] == 0


# ------------------------------------------------------------------ rally
@cocotb.test()
async def test_rally(dut):
    """A long game with both paddles steered by Python. Every frame it checks the
    ball stays inside the walls and moves exactly by the velocity table entry
    for its speed and angle. Open tb_game.fst afterwards to watch the ball."""
    await start(dut)
    frames, hits_seen, wall_bounces, points, top_hits = 3000, 0, 0, 0, 0
    give_up = 2600                                # player 2 stops moving here, so a point is scored
    prev = state(dut)
    for n in range(frames):
        btn = SERVE if prev["serving"] and n < give_up else 0
        ball_mid = prev["ball_y"] // PX + 4
        aim = ((n // 150) % 5 - 2) * 8            # hit off-centre by -16..16 px, so angles vary
        for pad, up, down in (("pad1_y", P1_UP, P1_DOWN), ("pad2_y", P2_UP, P2_DOWN)):
            if pad == "pad2_y" and n >= give_up:
                continue
            error = (prev[pad] + PAD_HEIGHT // 2 + aim) - ball_mid
            if error > 6:
                btn |= up
            elif error < -6:
                btn |= down
        s = await frame(dut, btn)

        assert TOP_LIMIT <= s["ball_y"] <= BOTTOM_LIMIT, f"frame {n}: ball left the court {s}"
        assert s["hits"] <= 15 and s["angle"] <= 7
        moving = not prev["serving"] and not s["serving"]
        if moving and s["dx"] == prev["dx"] and s["dy"] == prev["dy"]:
            vx, vy = velocity(prev["hits"], prev["angle"])
            step = (s["ball_x"] - prev["ball_x"], s["ball_y"] - prev["ball_y"])
            want = (vx if s["dx"] else -vx, vy if s["dy"] else -vy)
            assert step == want, f"frame {n}: moved {step}, table says {want}"
        if moving and s["dx"] != prev["dx"]:
            hits_seen += 1
        if moving and s["dy"] != prev["dy"] and s["dx"] == prev["dx"]:
            wall_bounces += 1
        if s["score1"] + s["score2"] != prev["score1"] + prev["score2"]:
            points += 1
        top_hits = max(top_hits, s["hits"])
        prev = s

    dut._log.info(f"{frames} frames ({frames / 59.94:.0f} s of play): {hits_seen} paddle hits, "
                  f"{wall_bounces} wall bounces, {points} points, top hit count {top_hits}, "
                  f"final score {prev['score1']}-{prev['score2']}")
    assert top_hits == 15, "the rally should reach top speed (14 px/frame)"
    assert wall_bounces >= 5
    assert (prev["score1"], prev["score2"], prev["serving"]) == (1, 0, 1), \
        "player 2 stopped, so player 1 scores once and the ball waits for a serve"
