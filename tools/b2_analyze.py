#!/usr/bin/env python3
"""Analyze rvv-board2 screening log (b2screen.log).

RESULT <ARM>-<POINT> <db_bench raw line with 'X ops/sec'>
Pairing: i-th RESULT occurrence of a given (arm, point) = round i.
"""
import re
import statistics
import sys
from collections import defaultdict

ARMS = ["BSP", "BV5", "BV5NS"]
POINTS = ["Bread8", "Aseek8", "fill1", "Bread1", "Aseek1"]


def main(path):
    data = defaultdict(list)  # (arm, point) -> [ops/sec per round]
    anomalies = []
    with open(path) as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln.startswith("RESULT "):
                continue
            m = re.match(r"RESULT (\S+?)-(\S+) (.*)", ln)
            if not m:
                anomalies.append("unparsed: " + ln)
                continue
            arm, point, rest = m.groups()
            om = re.search(r"([\d.]+) ops/sec", rest)
            if not om:
                anomalies.append("no ops/sec: " + ln)
                continue
            data[(arm, point)].append(float(om.group(1)))

    print("== medians (ops/sec, higher better) ==")
    print(f"{'point':8s} " + " ".join(f"{a:>12s}" for a in ARMS) + "  rounds")
    for p in POINTS:
        row = []
        ns = []
        for a in ARMS:
            v = data.get((a, p), [])
            ns.append(len(v))
            row.append(f"{statistics.median(v):12.1f}" if v else f"{'-':>12s}")
        print(f"{p:8s} " + " ".join(row) + f"  {ns}")

    print("\n== paired per-round comparisons (B vs A: % = median of per-round (B-A)/A, signs = B>A / B<A) ==")
    pairs = [("BV5", "BSP"), ("BV5NS", "BSP"), ("BV5NS", "BV5")]
    for b, a in pairs:
        print(f"-- {b} vs {a} --")
        for p in POINTS:
            va, vb = data.get((a, p), []), data.get((b, p), [])
            n = min(len(va), len(vb))
            if n == 0:
                print(f"  {p:8s} no data")
                continue
            deltas = [(vb[i] - va[i]) / va[i] * 100 for i in range(n)]
            pos = sum(1 for d in deltas if d > 0)
            neg = sum(1 for d in deltas if d < 0)
            med_delta = statistics.median(deltas)
            medpct = (statistics.median(vb[:n]) - statistics.median(va[:n])) / statistics.median(va[:n]) * 100
            print(f"  {p:8s} med-of-deltas {med_delta:+6.2f}%  (median-vs-median {medpct:+6.2f}%)  signs +{pos}/-{neg} of {n}  "
                  + " ".join(f"{d:+.2f}" for d in deltas))

    if anomalies:
        print("\n== anomalies ==")
        for a_ in anomalies:
            print(" ", a_)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "b2screen.log")
