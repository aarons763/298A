# SPDX-License-Identifier: Apache-2.0
#
# ECE 298A Pong VGA - G8: buttons move the paddles on the real screen output.
#
# This runs the whole chip and checks only its pins (ui_in in, colour bits
# out), so it also runs on the gate-level netlist. It looks down the pixel
# columns where the paddles are drawn and finds each paddle's top and bottom
# edge, before and after one game update. The left paddle is drawn as a pencil
# (pink eraser at the top, dark graphite point at the bottom) and the right as
# a pen (dark blue cap and tip). Both columns are beside the building, where
# the sunset sky is plain orange at these heights.

import cocotb

from test_vga_sync import FRAME, H_TOTAL, start, sample_at

SKY = 0b11_10_01        # orange sunset sky beside the building
PENCIL_TOP, PENCIL_TIP = 0b11_10_10, 0b01_01_01   # eraser, graphite point
PEN_TOP, PEN_TIP = 0b00_00_10, 0b00_00_10         # dark blue cap and tip
P1_UP, P2_DOWN = 0b00001, 0b01000
LEFT_COL, RIGHT_COL = 20, 620           # inside the paddles' columns (16-23, 616-623)


def edge_checks(x, top):
    """The pixels just above, at, and at the bottom of a paddle whose top edge
    should be on line `top` (the paddle is 64 lines tall)."""
    first, last = (PEN_TOP, PEN_TIP) if x >= 512 else (PENCIL_TOP, PENCIL_TIP)
    return [(top - 1, x, SKY), (top, x, first), (top + 63, x, last), (top + 64, x, SKY)]


async def check_frame(dut, t0, frame, checks):
    """Sample every (line, column, colour) check of one frame. The simulation
    only moves forward in time, so the pixels are read in screen order."""
    for line, x, want in sorted(checks):
        _, _, rgb = await sample_at(dut, t0, frame * FRAME + line * H_TOTAL + x)
        assert rgb == want, f"frame {frame}, column {x}, line {line}: rgb {rgb:06b}, want {want:06b}"


@cocotb.test()
async def test_paddles_move_on_screen(dut):
    """G8: holding P1 up and P2 down moves the left paddle up 12 px and the
    right paddle down 12 px, starting with the next frame drawn."""
    t0 = await start(dut)
    dut.ui_in.value = P1_UP | P2_DOWN

    # frame 0: both paddles where reset put them, top edge on line 208
    await check_frame(dut, t0, 0, edge_checks(LEFT_COL, 208) + edge_checks(RIGHT_COL, 208))

    # the buttons are read at line 480 and applied at the end of the frame,
    # so frame 1 shows the left paddle at 196 and the right paddle at 220
    await check_frame(dut, t0, 1, edge_checks(LEFT_COL, 196) + edge_checks(RIGHT_COL, 220))
