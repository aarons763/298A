# Synchronous reset distribution

The external rst_n pin now drives only the first of two reset synchronizer
flip-flops. The second stage drives video timing, frame-button capture and game
state. Both reset assertion and release remain synchronous; functional registers
observe the changed reset on the third rising edge after the pin changes. Hold
reset low for at least three rising edges. No asynchronous resets or timing
exceptions were added, and the frame-physics exceptions exclude both stages.

The VGA test helper moves its pixel-zero reference by two clocks after external
reset release. Every VESA width, period and pixel-position expectation is
unchanged. The frame-button test waits three clocks for reset assertion to reach
functional registers. The C++ pixel checker likewise waits two release clocks.
The video timing RTL, counters and decodes are unchanged.
