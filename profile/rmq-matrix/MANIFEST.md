# RocketMQ dual-arm matrix — FINAL 24-cell manifest (2026-08-29)

accounting.txt is append-only and contains every completed accounting line,
including runs later superseded; THE final result for each cell is the LAST
line for that cell name. This manifest lists the 24 final cells explicitly.

| cell | protocol | accounting (final line) |
|---|---|---|
| scalar-s1024-normal-ab | v5b (no warm-up) | `cell=scalar-s1024-normal-ab put=1384817 backlog_final=0 drain_s=0` |
| rvv-s1024-normal-ab | v5b (no warm-up) | `cell=rvv-s1024-normal-ab put=1366854 backlog_final=0 drain_s=0` |
| rvv-s1024-normal-ba | v5b (no warm-up) | `cell=rvv-s1024-normal-ba put=1372553 backlog_final=0 drain_s=0` |
| scalar-s1024-normal-ba | v5b (no warm-up) | `cell=scalar-s1024-normal-ba put=1372728 backlog_final=0 drain_s=0` |
| scalar-s1024-backlog-ab | v5b (no warm-up) | `cell=scalar-s1024-backlog-ab put=1674789 backlog_final=0 drain_s=0` |
| rvv-s1024-backlog-ab | v5b (no warm-up) | `cell=rvv-s1024-backlog-ab put=1763354 backlog_final=0 drain_s=0` |
| rvv-s1024-backlog-ba | v5b (no warm-up) | `cell=rvv-s1024-backlog-ba put=1632753 backlog_final=0 drain_s=0` |
| scalar-s1024-backlog-ba | v5b (no warm-up) | `cell=scalar-s1024-backlog-ba put=1713280 backlog_final=0 drain_s=0` |
| scalar-s16384-normal-ab | v6.1 (warm-up45s + JIT-exclude + tmp-reap) | `cell=scalar-s16384-normal-ab put=997060 backlog_final=0 drain_s=0` |
| rvv-s16384-normal-ab | v6.1 (warm-up45s + JIT-exclude + tmp-reap) | `cell=rvv-s16384-normal-ab put=981774 backlog_final=0 drain_s=0` |
| rvv-s16384-normal-ba | v6.1 (warm-up45s + JIT-exclude + tmp-reap) | `cell=rvv-s16384-normal-ba put=979494 backlog_final=0 drain_s=0` |
| scalar-s16384-normal-ba | v6.2 (warm-up45s + JIT-exclude + tmp-reap + SF-60s rule) | `cell=scalar-s16384-normal-ba put=994122 backlog_final=0 drain_s=0 send_failed_60s=0` |
| scalar-s16384-backlog-ab | v6.2 (warm-up45s + JIT-exclude + tmp-reap + SF-60s rule) | `cell=scalar-s16384-backlog-ab put=1090378 backlog_final=0 drain_s=0 send_failed_60s=0` |
| rvv-s16384-backlog-ab | v6.2 (warm-up45s + JIT-exclude + tmp-reap + SF-60s rule) | `cell=rvv-s16384-backlog-ab put=1080710 backlog_final=0 drain_s=0 send_failed_60s=0` |
| rvv-s16384-backlog-ba | v6.2 (warm-up45s + JIT-exclude + tmp-reap + SF-60s rule) | `cell=rvv-s16384-backlog-ba put=1099573 backlog_final=0 drain_s=0 send_failed_60s=0` |
| scalar-s16384-backlog-ba | v6.2 (warm-up45s + JIT-exclude + tmp-reap + SF-60s rule) | `cell=scalar-s16384-backlog-ba put=1082316 backlog_final=0 drain_s=0 send_failed_60s=0` |
| scalar-s131072-normal-ab | v6.2 | `cell=scalar-s131072-normal-ab put=370465 backlog_final=0 drain_s=0 send_failed_60s=0` |
| rvv-s131072-normal-ab | v6.2 | `cell=rvv-s131072-normal-ab put=372144 backlog_final=0 drain_s=0 send_failed_60s=0` |
| rvv-s131072-normal-ba | v6.2 | `cell=rvv-s131072-normal-ba put=370161 backlog_final=0 drain_s=0 send_failed_60s=0` |
| scalar-s131072-normal-ba | v6.2 | `cell=scalar-s131072-normal-ba put=367874 backlog_final=0 drain_s=0 send_failed_60s=1` |
| scalar-s131072-backlog-ab | v6.3 (v6.2 + producer -w 4) | `cell=scalar-s131072-backlog-ab put=340078 backlog_final=0 drain_s=15 send_failed_60s=0` |
| rvv-s131072-backlog-ab | v6.3 (v6.2 + producer -w 4) | `cell=rvv-s131072-backlog-ab put=326236 backlog_final=0 drain_s=0 send_failed_60s=0` |
| rvv-s131072-backlog-ba | v6.3 (v6.2 + producer -w 4) | `cell=rvv-s131072-backlog-ba put=306237 backlog_final=0 drain_s=0 send_failed_60s=0` |
| scalar-s131072-backlog-ba | v6.3 (v6.2 + producer -w 4) | `cell=scalar-s131072-backlog-ba put=317741 backlog_final=0 drain_s=0 send_failed_60s=0` |

## Non-final accounting lines (kept, never deleted)

- `cell=scalar-s16384-normal-ab put=933463 backlog_final=0 drain_s=0...` — v5b run, ABORT send_failed_nonzero (broker cold-start fast-fail); dir scalar-s16384-normal-ab.ABORTED-0135
- `cell=scalar-s16384-normal-ab put=1068316 backlog_final=0 drain_s=0...` — v6.1 run under 98%-full tmpfs (memory pressure) — SUPERSEDED by 02:14 rerun; dir scalar-s16384-normal-ab.TMPPRESSURE-0202
- `cell=scalar-s16384-normal-ba put=993808 backlog_final=0 drain_s=0...` — v6.1 run, ABORT send_failed_nonzero (1 client cold-start blip) — SUPERSEDED by v6.2 rerun; dir scalar-s16384-normal-ba.COLDBLIP-0239
- `cell=scalar-s131072-backlog-ab put=384966 backlog_final=0 drain_s=30 send_failed_60s=0...` — v6.2 run at -w 8 (saturating) — SUPERSEDED by v6.3 -w 4 rerun; dir scalar-s131072-backlog-ab.W8-SUPERSEDED

## Aborted cells with NO accounting line (died before accounting)

- scalar-s16384-normal-ab.CRASHED-0150 — v6 run, broker JVM SIGSEGV (JDK21 C2 JIT, pure-Java remoting frame; hs_err preserved in dir)
- rvv-s16384-normal-ab.TMPFULL-0203 — v6r2 run, broker boot failed: rocksdbjni jar extraction ENOSPC on 98%-full tmpfs
- rvv-s131072-backlog-ab.W8-SATURATED-0416 — v6.2 run at -w 8, in-window send failures from broker saturation when the mid-run consumer joined (root cause for the pre-registered -w 4 change)

## Exact put accounting per (size, scene) — ab+ba sums, RVV vs scalar

| size×scene | scalar put | rvv put | Δ |
|---|---|---|---|
| 1024 normal | 2757545 | 2739407 | -0.658% |
| 1024 backlog | 3388069 | 3396107 | +0.237% |
| 16384 normal | 1991182 | 1961268 | -1.502% |
| 16384 backlog | 2172694 | 2180283 | +0.349% |
| 131072 normal | 738339 | 742305 | +0.537% |
| 131072 backlog | 657819 | 632473 | -3.853% |
