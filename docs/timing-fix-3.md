# Registered colour and aligned sync outputs

The six RGB bits and both syncs share a new output-register stage. The rendered
pixel and its sync timing therefore move together, one clock behind the internal
scan counters. No video-counter, visible-window or frame-end logic changes.
The six colour bits may map to fewer physical flops because this renderer uses
equal red, green and blue values.

HSYNC already decodes one pixel early (655 through 750) before its existing
register. That decode stays unchanged. VSYNC now anticipates its line transitions
on pixel 799 of lines 489 and 491, removing its former one-pixel lateness.
After the shared output stage, HSYNC is low at displayed pixels 656 through 751,
and VSYNC is low throughout displayed lines 490 and 491, starting at pixel 0.

Test changes:

- The VGA helper shifts the output pixel-zero origin by one clock, in addition
  to Fix 2's two reset-release clocks.
- VSYNC_FALL changes from 392001 to 392000 relative to that output origin,
  reflecting the corrected vertical boundary. Pulse width remains 1600 clocks.
- Every line width, porch, sync width, visible boundary and frame-period check
  remains exact. No tolerance has been added.
- The button-capture test subtracts the output latency to keep checking internal
  state at the same scan edges as before.
- The C++ checker uses the same output origin and exact VSYNC boundary; the game
  reference model and pixel comparisons are unchanged.

The output stage continuously samples black during blanking. It does not add a
reset mux to the colour path; after synchronous reset settles, the normal renderer
and sync decode produce the reset picture, as checked on the pins.
