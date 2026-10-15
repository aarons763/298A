#!/bin/sh
# Build and run the pixel-exact Verilator checker (Linux / WSL / macOS).
#   ./run.sh [frames] [mode] [seed]     mode: idle | ai | lazy | random
# Every frame is compared pixel-by-pixel with a C++ reference model of the
# game; VESA sync timing and the scores on uio_out are checked too.
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -O3 -Wno-fatal --prefix Vtop \
  --top-module tt_um_aarons763_pong_vga ../src/project.v ../src/pong_vga_sync.v tb.cpp -o Vtop >/dev/null
./obj_dir/Vtop "${1:-600}" "${2:-random}" "${3:-1}"
