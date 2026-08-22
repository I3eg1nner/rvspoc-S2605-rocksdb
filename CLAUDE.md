# Agent Instructions — rvspoc-s2605-rocksdb task workspace

(Copy this file to the task workspace root as CLAUDE.md.)

This is a KDA-style task workspace for RVSPOC 2026 S2605 (RocksDB
v11.1.1 -> RV64GCV + RVV). The contract and starter prompt live in the
rvv-wiki repo: `~/code/RVV-LLM/contests/rvspoc-s2605/`
(task-contract.md, session-prompt.md). Deadline: 2026-08-31 AoE.

## Rules

- Skills: `rvv-wiki` for knowledge (query before designing; cite page
  ids; out-of-scope topics get a calibrated negative), `rvv-measure`
  for numbers (board = `ssh rvv-board`; QEMU never for timing).
- docs/draft.md before code; docs/plan.md is the executable plan; keep
  both current — future sessions cold-start from these files, not from
  chat memory.
- One candidate at a time. Every candidate gets a row in
  candidates.jsonl (name, parent, status, reject-reason) and its
  numbers in benchmark.csv (with environment). Rejected candidates keep
  their reason.
- Correctness gates for every candidate: differential vs scalar at
  non-VL-multiple shapes; QEMU vlen=128/256/512 AND the hostile flags
  (-cpu ...,rvv_ta_all_1s=true,rvv_ma_all_1s=true); then rvv-board;
  x86 cross-build unchanged.
- Persisted formats (CRC, bloom bits, hashes) must be bit-identical to
  scalar — test against files written by the scalar build.
- Commit early and often to the fork; the PR to
  rv2036/rvspoc-S2605-rocksdb is the deliverable.
- AI disclosure: maintain provenance as you go (which kernels came from
  rvv-wiki artifacts, which sessions did what) — this workspace's git
  history + the wiki's run records are the disclosure document.
- Durable findings (new measurements, new pitfalls) promote BACK to the
  wiki per rvv-measure's promotion procedure; do not let them die in
  this workspace.

## End-of-session ritual

Before ending any session: update docs/plan.md (done/next/blockers),
flush candidates.jsonl and benchmark.csv, commit. The next session must
be able to resume from files alone.
