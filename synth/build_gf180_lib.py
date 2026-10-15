#!/usr/bin/env python3
"""
Build the two data files count_transistors.py needs, from the official
GlobalFoundries GF180MCU 7-track standard-cell library (the one the Tiny
Tapeout GF180 flow uses, gf180mcu_fd_sc_mcu7t5v0):

  pdk/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib  combined Liberty (typical corner)
  pdk/cellinfo.json                              transistors + area per cell

Transistor counts are the number of MOSFETs in each cell's .cdl netlist.
Needs git and network access; takes about a minute. Run once.
"""
import glob, json, os, re, subprocess, sys, tempfile

REPO = "https://github.com/google/globalfoundries-pdk-libs-gf180mcu_fd_sc_mcu7t5v0.git"
CORNER = "tt_025C_5v00"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pdk")


def git(*args, cwd=None):
    subprocess.run(["git", *args], cwd=cwd, check=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        lib = os.path.join(td, "sc")
        git("clone", "--depth", "1", "--filter=blob:none", "--no-checkout", REPO, lib)
        files = subprocess.run(["git", "ls-tree", "-r", "--name-only", "HEAD"], cwd=lib,
                               check=True, capture_output=True, text=True).stdout.split()
        want = [f for f in files if f.endswith(".cdl") or f.endswith(f"__{CORNER}.lib")]
        want.append(f"liberty/gf180mcu_fd_sc_mcu7t5v0__{CORNER}.lib")
        for i in range(0, len(want), 200):  # keep the command line short
            git("checkout", "HEAD", "--", *want[i:i + 200], cwd=lib)

        # Combined liberty = library header + every cell group
        hdr = open(os.path.join(lib, "liberty", f"gf180mcu_fd_sc_mcu7t5v0__{CORNER}.lib")).read()
        hdr = hdr[:hdr.rstrip().rfind("}")]
        parts, area = [hdr], {}
        for f in sorted(glob.glob(os.path.join(lib, "cells", "*", f"*__{CORNER}.lib"))):
            t = re.sub(r"/\*.*?\*/", "", open(f).read(), flags=re.S)
            m = re.search(r"cell\((\S+)\)\s*\{\s*area\s*:\s*([\d.]+)", t)
            if m:
                area[m.group(1)] = float(m.group(2))
            parts.append(t)
        parts.append("\n}\n")
        open(os.path.join(OUT, f"gf180mcu_fd_sc_mcu7t5v0__{CORNER}.lib"), "w").write("".join(parts))

        tc = {}
        for f in sorted(glob.glob(os.path.join(lib, "cells", "*", "*.cdl"))):
            name = os.path.basename(f)[:-4]
            tc[name] = sum(1 for line in open(f) if re.match(r"^\s*M", line))
        json.dump({"transistors": tc, "area": area},
                  open(os.path.join(OUT, "cellinfo.json"), "w"), indent=1)
    print(f"wrote {OUT}: {len(area)} cells")


if __name__ == "__main__":
    sys.exit(main())
