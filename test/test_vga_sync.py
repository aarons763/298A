# SPDX-License-Identifier: Apache-2.0
#
# ECE 298A Pong VGA - video timing tests (pong_vga_sync, owner: Noah Webster)
#
# Checks the chip's VGA output pins against the VESA 640x480 @ 60 Hz timing
# table, to the exact clock:
#
#             visible  front porch  sync  back porch  total
#   pixels      640        16        96       48       800 per line
#   lines       480        10         2       33       525 per frame
#
# Everything is checked on the output pins only (hsync, vsync and the colour
# bits), so the same tests run on the RTL and on the gate-level netlist.
# The one test that pokes an internal register is skipped at gate level.
#
# How the picture is used: rows 0-7 and 472-479 are the grey top and bottom
# walls, which span the full 640-pixel width, so they show exactly where the
# visible window starts and ends. Everything outside the window must be
# black (the monitor uses that "blanking" level as its black reference).

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

# ------------------------------------------------------------------ VESA table
H_VISIBLE, H_FRONT, H_SYNC, H_BACK = 640, 16, 96, 48
V_VISIBLE, V_FRONT, V_SYNC, V_BACK = 480, 10, 2, 33
H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK            # 800
V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK            # 525
FRAME = H_TOTAL * V_TOTAL                                  # 420,000 clocks

H_SYNC_START = H_VISIBLE + H_FRONT                         # pixel 656
V_SYNC_START = V_VISIBLE + V_FRONT                         # line 490
# vsync comes from a flip-flop that looks at the line number, so it changes
# one clock after the line starts (40 ns; a monitor can't tell).
VSYNC_FALL = V_SYNC_START * H_TOTAL + 1                    # clock 392,001

PIXEL_CLOCK_HZ = 25_175_000
CLK_NS = 40               # simulated clock period (25 MHz; only the count matters)
CLK = CLK_NS * 1000       # the same in simulator steps (1 ps); whole numbers avoid rounding

GREY = 0b01_01_01         # rgb = {R1,R0,G1,G0,B1,B0}: walls and net
BLACK = 0

GATE_LEVEL = os.environ.get("GATES") == "yes"


# ------------------------------------------------------------------ helpers
async def start(dut):
    """Start the clock and reset. Returns the sim time (in steps) of the clock edge
    that starts pixel 0 of line 0, i.e. the last edge with reset held."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0          # no buttons: ball parked, paddles still
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    return await release_reset(dut)


async def release_reset(dut):
    await RisingEdge(dut.clk)    # this edge still sees reset -> counters = 0
    dut.rst_n.value = 1
    return get_sim_time("step")


async def sample_at(dut, t0, clock_index):
    """Jump to the middle of clock period `clock_index` after t0 and return
    (hsync, vsync, rgb). Pixel n of line L is clock_index L*800 + n."""
    target = t0 + clock_index * CLK + CLK // 2
    now = get_sim_time("step")
    assert target > now, "samples must be taken in time order"
    await Timer(target - now, unit="step")
    return int(dut.hsync.value), int(dut.vsync.value), int(dut.rgb.value)


async def clocks_until(dut, t0, edge):
    """Wait for an edge trigger and return how many clocks after t0 it was."""
    await edge
    dt = get_sim_time("step") - t0
    assert dt % CLK == 0, f"edge not on a clock edge ({dt} ps)"
    return dt // CLK


# ------------------------------------------------------------------ tests
@cocotb.test()
async def test_vga_numbers(dut):
    """The timing table adds up to the advertised rates (no hardware involved;
    this documents the VGA calculations next to the tests that rely on them)."""
    line_hz = PIXEL_CLOCK_HZ / H_TOTAL
    frame_hz = line_hz / V_TOTAL
    dut._log.info(f"line rate {line_hz/1e3:.3f} kHz, frame rate {frame_hz:.3f} Hz, "
                  f"{FRAME} clocks per frame")
    assert H_TOTAL == 800 and V_TOTAL == 525
    assert abs(line_hz - 31_469) < 1
    assert abs(frame_hz - 59.94) < 0.01


@cocotb.test()
async def test_line_timing(dut):
    """Every pixel of lines 0 and 1: 640 visible, 16 front porch, 96 sync,
    48 back porch; hsync low exactly for pixels 656..751; vsync stays high."""
    t0 = await start(dut)
    runs = []                                  # (what, length) of each stretch
    for line in range(2):
        for x in range(H_TOTAL):
            hs, vs, rgb = await sample_at(dut, t0, line * H_TOTAL + x)

            want_rgb = GREY if x < H_VISIBLE else BLACK     # line 0/1 = top wall
            want_hs = 0 if H_SYNC_START <= x < H_SYNC_START + H_SYNC else 1
            assert rgb == want_rgb, f"line {line} pixel {x}: rgb {rgb:06b}, want {want_rgb:06b}"
            assert hs == want_hs, f"line {line} pixel {x}: hsync {hs}, want {want_hs}"
            assert vs == 1, f"line {line} pixel {x}: vsync low"

            what = "visible" if rgb else ("sync" if hs == 0 else "blank")
            if runs and runs[-1][0] == what:
                runs[-1][1] += 1
            else:
                runs.append([what, 1])
    dut._log.info("line 0-1 stretches (pixels): " + ", ".join(f"{w} {n}" for w, n in runs))
    # visible 640, front porch 16, sync 96, back porch 48, visible 640, ...
    assert [n for _, n in runs[:4]] == [H_VISIBLE, H_FRONT, H_SYNC, H_BACK]


@cocotb.test()
async def test_frame_timing(dut):
    """Vertical timing over a full frame plus one line: the visible window is
    lines 0..479, vsync is low for exactly 2 lines starting at line 490, and
    the frame repeats every 420,000 clocks."""
    t0 = await start(dut)

    # first hsync pulse: starts at pixel 656 of line 0, lasts 96 clocks
    assert await clocks_until(dut, t0, FallingEdge(dut.hsync)) == H_SYNC_START
    assert await clocks_until(dut, t0, RisingEdge(dut.hsync)) == H_SYNC_START + H_SYNC

    # edges of the visible window, on the bottom wall (line 479) and below it
    checks = [
        (479, 0, GREY), (479, 639, GREY), (479, 640, BLACK),
        (480, 0, BLACK), (489, 300, BLACK),
    ]
    for line, x, want in checks:
        _, _, rgb = await sample_at(dut, t0, line * H_TOTAL + x)
        assert rgb == want, f"line {line} pixel {x}: rgb {rgb:06b}, want {want:06b}"

    # vsync: low for lines 490-491 (2 lines = 1,600 clocks)
    fall = await clocks_until(dut, t0, FallingEdge(dut.vsync))
    rise = await clocks_until(dut, t0, RisingEdge(dut.vsync))
    dut._log.info(f"vsync low from clock {fall} (line {fall // H_TOTAL}, pixel "
                  f"{fall % H_TOTAL}) for {rise - fall} clocks")
    assert fall == VSYNC_FALL
    assert rise - fall == V_SYNC * H_TOTAL

    # back porch is blank, then the next frame starts at line 0 pixel 0
    _, _, rgb = await sample_at(dut, t0, (V_TOTAL - 1) * H_TOTAL + (H_TOTAL - 1))
    assert rgb == BLACK, "last pixel of the frame should be black"
    _, _, rgb = await sample_at(dut, t0, FRAME)
    assert rgb == GREY, "pixel 0 of the next frame should be the top wall"

    # and the frame period is exact
    fall2 = await clocks_until(dut, t0, FallingEdge(dut.vsync))
    assert fall2 - fall == FRAME, f"frame period {fall2 - fall}, want {FRAME}"


@cocotb.test()
async def test_reset_mid_frame(dut):
    """Reset in the middle of a frame restarts the picture at line 0, pixel 0."""
    t0 = await start(dut)
    await Timer(123_457 * CLK_NS, unit="ns")       # somewhere around line 154
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    t0 = await release_reset(dut)

    _, _, rgb = await sample_at(dut, t0, 0)
    assert rgb == GREY, "pixel 0 after reset should be the top wall"
    assert await clocks_until(dut, t0, FallingEdge(dut.hsync)) == H_SYNC_START
    assert await clocks_until(dut, t0, FallingEdge(dut.vsync)) == VSYNC_FALL


@cocotb.test(skip=GATE_LEVEL)
async def test_recovers_from_impossible_count(dut):
    """If the counters ever hold values they can't normally reach (e.g. after
    a supply glitch), the timing fixes itself within one frame, with no reset.
    RTL only: it writes the counter registers directly."""
    t0 = await start(dut)
    await sample_at(dut, t0, 1000)
    sync = dut.user_project.sync_gen
    sync.hcount.value = 1000     # above 799
    sync.vcount.value = 1000     # above 524

    # wait for timing to settle, then measure two full frames' worth of edges
    await FallingEdge(dut.vsync)
    t1 = get_sim_time("step")
    period = await clocks_until(dut, t1, FallingEdge(dut.vsync))
    assert period == FRAME, f"frame period {period} after recovery, want {FRAME}"
    await FallingEdge(dut.hsync)
    line = await clocks_until(dut, get_sim_time("step"), FallingEdge(dut.hsync))
    assert line == H_TOTAL, f"line period {line} after recovery, want {H_TOTAL}"
