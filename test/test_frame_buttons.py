"""RTL checks for the stability assumptions behind the scoped multicycle SDC.

The pin-level VGA suite remains unchanged and also runs on the gate netlist.
These additional checks inspect named RTL registers, so skip them at gate level.
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, Timer
from test_vga_sync import start, sample_at, FRAME

STATE = ("ball_x", "ball_y", "pad1_y", "pad2_y", "score1", "score2",
         "dx", "dy", "serving", "hits", "angle")


@cocotb.test(skip=os.environ.get("GATES") == "yes")
async def test_frame_button_capture(dut):
    t0 = await start(dut)
    top = dut.user_project
    game = top.game
    snapshot = lambda: tuple(int(getattr(game, n).value) for n in STATE)
    capture = 480 * 800 + 1  # edge whose pre-edge counters are (0,480)
    assert FRAME - capture == 35_999
    dut.ui_in.value = 0b10101  # both paddles up, serve
    await sample_at(dut, t0, capture - 1)
    before = snapshot()
    assert int(top.frame_buttons.value) == 0
    await sample_at(dut, t0, capture)
    assert int(top.frame_buttons.value) == 0b10101
    assert snapshot() == before, "capture must not update game state"
    dut.ui_in.value = 0b01010  # change every relevant control after capture
    await sample_at(dut, t0, capture + 4)
    assert int(top.frame_buttons.value) == 0b10101
    assert snapshot() == before
    await sample_at(dut, t0, FRAME - 1)
    assert snapshot() == before, "game state must hold until frame_end"
    await sample_at(dut, t0, FRAME)
    assert int(game.pad1_y.value) == 196
    assert int(game.pad2_y.value) == 196
    assert int(game.serving.value) == 0
    assert int(game.score1.value) == int(game.score2.value) == 0
    after = snapshot()
    await sample_at(dut, t0, FRAME + capture)
    assert int(top.frame_buttons.value) == 0b01010
    assert snapshot() == after
    dut.ui_in.value = 0
    await sample_at(dut, t0, 2 * FRAME - 1)
    assert int(top.frame_buttons.value) == 0b01010
    assert snapshot() == after
    await sample_at(dut, t0, 2 * FRAME)
    assert int(game.pad1_y.value) == int(game.pad2_y.value) == 208
    # Reset restarts both the scan and all sampled/state registers together.
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(top.frame_buttons.value) == 0
    assert int(top.hcount.value) == int(top.vcount.value) == 0
    assert int(game.pad1_y.value) == int(game.pad2_y.value) == 208
