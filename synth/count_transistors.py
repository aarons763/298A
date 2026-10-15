#!/usr/bin/env python3
"""
Transistor / area estimate for a Tiny Tapeout GF180 design.

Runs Yosys with a script that mirrors LibreLane's default synthesis
(SYNTH_STRATEGY "AREA 0") against gf180mcu_fd_sc_mcu7t5v0, then multiplies
the cell counts by the transistor count of each cell's SPICE (.cdl) netlist.

Usage:  python3 synth/count_transistors.py [--hier] [--budget N] src/project.v
  --hier       also report a per-module breakdown (hierarchy kept, so there is
               no cross-block optimisation and the parts can sum a bit above
               the flat total)
  --budget N   exit with an error if the total exceeds N transistors
  --top M      top module (default: the first tt_um_* module in the file)

Needs yosys on PATH and the files made by build_gf180_lib.py (run it once).

Numbers are post-synthesis logic only. Place-and-route adds clock-tree and
repair buffers, tie cells, fill/decap/tap cells on top of this.
"""
import argparse, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PDK = os.environ.get("GF180_SC_DIR", os.path.join(HERE, "pdk"))
LIB = os.path.join(PDK, "gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib")
CELLINFO = os.path.join(PDK, "cellinfo.json")
PFX = "gf180mcu_fd_sc_mcu7t5v0__"
TILE_UM2 = 340 * 160  # GF180 1x1 tile

# LibreLane construct_abc_script.py, strategy "AREA 0" (default)
ABC_AREA0 = """fx
mfs
strash
drf -l
balance; drw -l; drf -l; balance; drw -l; drw -l -z; balance; drf -l -z; drw -l -z; balance
retime -M 5
scleanup
fraig_store; balance; fraig_store; balance; drw -l; drf -l; balance; drw -l; drw -l -z; balance; drf -l -z; drw -l -z; balance; fraig_store; balance; drw -l; drf -l; balance; drw -l; drw -l -z; balance; drf -l -z; drw -l -z; balance; fraig_store; balance; drw -l; drf -l; balance; drw -l; drw -l -z; balance; drf -l -z; drw -l -z; balance; fraig_store; fraig_restore
amap -m -Q 0.1 -F 20 -A 20 -C 5000

retime
&get -n
&st
&dch
&nf
&put

stime -p
print_stats -m
"""


def yosys_script(files, top, flatten, stat_json, abc_path, constr_path):
    rd = "\n".join(f"read_verilog -sv {f}" for f in files)
    return f"""
{rd}
hierarchy -check -top {top}
proc
{"flatten" if flatten else ""}
opt_expr
opt_clean
opt -nodffe -nosdff
fsm
opt
wreduce
peepopt
opt_clean
alumacc
share
opt
memory -nomap
opt_clean
opt -fast -full
memory_map
opt -full
techmap
opt -fast
opt -fast
abc -fast
opt -fast
dfflibmap -liberty {LIB}
abc -script {abc_path} -D 20000 -constr {constr_path} -liberty {LIB}
setundef -zero
hilomap -hicell {PFX}tieh Z -locell {PFX}tiel ZN
splitnets
opt_clean -purge
tee -q -o {stat_json} stat -json -liberty {LIB}
"""


def run(files, top, flatten):
    with tempfile.TemporaryDirectory() as td:
        abc = os.path.join(td, "area0.abc")
        con = os.path.join(td, "abc.constr")
        sj = os.path.join(td, "stat.json")
        open(abc, "w").write(ABC_AREA0)
        open(con, "w").write(f"set_driving_cell {PFX}inv_2\nset_load 0.0729\n")
        ys = os.path.join(td, "s.ys")
        open(ys, "w").write(yosys_script(files, top, flatten, sj, abc, con))
        r = subprocess.run(["yosys", "-q", "-s", ys], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stdout + r.stderr)
        txt = open(sj).read()
        return json.loads(txt[txt.index("{"):])


def tally(cells, info):
    tr, area, rows = 0, 0.0, []
    for cell, n in sorted(cells.items()):
        t = info["transistors"].get(cell)
        a = info["area"].get(cell)
        if t is None:
            sys.exit(f"unknown cell {cell}")
        tr += t * n
        area += a * n
        rows.append((cell.replace(PFX, ""), n, t, t * n, a * n))
    return tr, area, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", default=None)
    ap.add_argument("--hier", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--budget", type=int, default=None)
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    if not (os.path.exists(LIB) and os.path.exists(CELLINFO)):
        sys.exit(f"missing {PDK}/: run  python3 synth/build_gf180_lib.py  first")
    info = json.load(open(CELLINFO))
    top = a.top
    if top is None:
        src = open(a.files[0]).read()
        top = re.search(r"^\s*module\s+(tt_um_\w+)", src, re.M).group(1)

    st = run(a.files, top, flatten=True)
    mod = st["modules"]["\\" + top]
    cells = mod["num_cells_by_type"]
    tr, area, rows = tally(cells, info)
    ffs = sum(n for c, n in cells.items() if re.search(r"__(s?dff|lat)", c))
    if not a.quiet:
        print(f"\n== {top}  (flattened, GF180 7-track, LibreLane AREA 0 script)")
        print(f"{'cell':<12}{'count':>6}{'T/cell':>8}{'T':>7}{'um^2':>10}")
        for c, n, t, tt, aa in sorted(rows, key=lambda r: -r[3]):
            print(f"{c:<12}{n:>6}{t:>8}{tt:>7}{aa:>10.1f}")
    print(f"TOTAL: {tr} transistors, {sum(cells.values())} cells, {ffs} flip-flops, "
          f"{area:.0f} um^2 = {100*area/TILE_UM2:.1f}% of a 1x1 tile")

    if a.hier:
        st = run(a.files, top, flatten=False)
        print("\n== per-block breakdown (hierarchy kept)")
        for m, d in st["modules"].items():
            c = {k: v for k, v in d["num_cells_by_type"].items() if k.startswith(PFX)}
            t, ar, _ = tally(c, info)
            f = sum(n for k, n in c.items() if re.search(r"__(s?dff|lat)", k))
            print(f"{m.lstrip(chr(92)):<28}{t:>6} T  {f:>3} FF  {ar:>8.0f} um^2")
    if a.budget is not None:
        ok = tr <= a.budget
        print(f"BUDGET: {tr} / {a.budget} transistors -> {'OK' if ok else 'OVER BUDGET'}"
              f" ({a.budget - tr:+d} margin)")
        if not ok:
            sys.exit(1)
    return tr


if __name__ == "__main__":
    main()

