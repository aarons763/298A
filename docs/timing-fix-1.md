# Fix 1: frame physics multicycle paths

Baseline: GitHub main c651ab7 (12-pixel paddles). The separate local hold-control
test revision is not part of this timing-only change. Video counters/decodes,
reset distribution, renderer, and game physics are unchanged.

`frame_buttons[4:0]` samples the five input pins on the rising clock edge whose
pre-edge scan counters are hcount=0, vcount=480. Game state updates at the edge
whose pre-edge counters are hcount=799, vcount=524: 35,999 clocks later. The next
game-state update is 420,000 clocks after the previous one. Reset also restarts
the scan counters at zero, preventing a frame update immediately after reset.
Buttons changing after capture take effect at the following frame's capture;
this moves input sampling about 1.43 ms earlier than before. Frame-held controls
and all physics rules retain their behavior. This is not switch debouncing or a
quadrature decoder.

`src/pong.sdc` starts with an unmodified copy of LibreLane 3.0.3's
`librelane/scripts/base.sdc`; its clock, I/O delay/load/drive, uncertainty,
transition and derating behavior is retained. Both PNR_SDC_FILE and
SIGNOFF_SDC_FILE refer to this file. Configuration below the protected marker is
unchanged.

The appended exception is setup=4 / hold=3, from 63 game-state DFFs plus five
sampled-button DFFs to the 63 game-state DFFs only. DFFs are identified from the
sequential sources of explicitly named Q nets, including flattened aliases at the top
level and the eight score-output nets. Inserted repair buffers are traced back
to the original DFF; each named net must have exactly one DFF source.
Cardinality checks reject missing or
extra DFF selections; PONG_MCP log entries list every selected instance.

No exception starts at an input port or video counter, ends at an output port
or button register, or changes the clock. Reset input, button capture, scan
enable generation, RGB and score output paths remain single-cycle checks.
The original VGA tests are unchanged. The additional RTL-only cocotb test
checks capture timing, post-capture input changes, stable state until frame_end,
the resulting paddle/serve update, the next sample, and reset restart.

For signoff, inspect the generated SDC and post-route reports: launch sets must
contain only the 68 selected DFFs and destinations only the 63 game DFFs. The
relaxed paths should have a four-cycle capture edge (158.8 ns); reset, video
counter, capture-input and output paths must retain a one-cycle capture edge.
Hold=3 compensates the setup shift; it does not grant three cycles for hold.
