#!/bin/bash
# b2_bench.sh — rvv-board2 screening benchmark: BSP / BV5 / BV5NS, Latin-rotated rounds.
# Deployed to ~/s2605-check on rvv-board2; run under nohup after builds complete.
set -u
cd "$HOME/s2605-check" || exit 1

STATUS="$HOME/s2605-check/b2screen.status"
RLOG="$HOME/s2605-check/b2screen.log"
FULL="$HOME/s2605-check/b2bench_full.log"
DBA="$HOME/b2dbA"
DBB="$HOME/b2dbB"
SEED=20260822

log() { echo "$(date '+%F %T') $*" >> "$STATUS"; }

quiesce() {
  local i idle
  for i in $(seq 1 40); do
    idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
    [ "$idle" -ge 95 ] 2>/dev/null && return 0
    log "quiesce: idle=$idle < 95, waiting 30s"
    sleep 30
  done
  log "quiesce: TIMEOUT after 20min, proceeding with idle=$idle"
}

# run_one <TAG> <ARM> <LABEL> <db_bench args...>
# TAG = RESULT or WARMUP. BSP gets the CRC-disable env; BV5/BV5NS run bare.
run_one() {
  local TAG="$1" ARM="$2" LABEL="$3"; shift 3
  local ENVP=""
  [ "$ARM" = "BSP" ] && ENVP="ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0"
  {
    echo "##### $(date '+%F %T') $TAG $ARM-$LABEL env=[$ENVP] args: $*"
  } >> "$FULL"
  local OUT RC
  OUT=$(env $ENVP "./db_bench.$ARM" "$@" 2>&1); RC=$?
  echo "$OUT" >> "$FULL"
  local LINE
  LINE=$(echo "$OUT" | grep -E '^(readrandom|seekrandom|fillrandom)[[:space:]]*:' | head -1)
  if [ $RC -ne 0 ] || [ -z "$LINE" ]; then
    log "RUN FAIL $TAG $ARM-$LABEL rc=$RC (see $FULL)"
    echo "$TAG $ARM-$LABEL RUNFAIL rc=$RC" >> "$RLOG"
    return 1
  fi
  echo "$TAG $ARM-$LABEL $LINE" >> "$RLOG"
  sleep 5
  return 0
}

bread8() { run_one "$1" "$2" Bread8 --benchmarks=readrandom --use_existing_db=1 \
  --num=10000000 --key_size=16 --value_size=100 --seed=$SEED --reads=1500000 \
  --threads=8 --db="$DBB" --compression_type=none --bloom_bits=10 --cache_size=1073741824; }

# DEVIATION (board2): binary links no compressors (no snappy dev headers, no
# root), so "default params" opens fail on the snappy sanity check. All
# A-library invocations force --compression_type=none; everything else stays
# default. Common-mode across all three arms.
aseek8() { run_one "$1" "$2" Aseek8 --benchmarks=seekrandom --use_existing_db=1 \
  --num=10000000 --key_size=16 --value_size=100 --seed=$SEED --reads=400000 \
  --seek_nexts=10 --threads=8 --db="$DBA" --compression_type=none; }

bread1() { run_one "$1" "$2" Bread1 --benchmarks=readrandom --use_existing_db=1 \
  --num=10000000 --key_size=16 --value_size=100 --seed=$SEED --reads=1500000 \
  --threads=1 --db="$DBB" --compression_type=none --bloom_bits=10 --cache_size=1073741824; }

aseek1() { run_one "$1" "$2" Aseek1 --benchmarks=seekrandom --use_existing_db=1 \
  --num=10000000 --key_size=16 --value_size=100 --seed=$SEED --reads=400000 \
  --seek_nexts=10 --threads=1 --db="$DBA" --compression_type=none; }

fill1() { # $1=TAG $2=ARM $3=round
  local DIR="$HOME/b2fill-$2-r$3"
  rm -rf "$DIR"
  run_one "$1" "$2" fill1 --benchmarks=fillrandom --num=10000000 --key_size=16 \
    --value_size=100 --seed=$SEED --threads=1 --db="$DIR" \
    --compression_type=none --bloom_bits=10 --cache_size=1073741824
  local RC=$?
  rm -rf "$DIR"
  return $RC
}

rot() { # $1 = round number (1-based) -> echoes rotated arm order
  local A=(BSP BV5 BV5NS)
  local s=$(( ($1 - 1) % 3 ))
  echo "${A[$s]} ${A[$(( (s+1)%3 ))]} ${A[$(( (s+2)%3 ))]}"
}

log "=== bench session start ==="
log "ENV governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
for arm in BSP BV5 BV5NS; do
  [ -x "./db_bench.$arm" ] || { log "MISSING db_bench.$arm, abort"; exit 1; }
  log "SHA256 db_bench.$arm $(sha256sum db_bench.$arm | awk '{print $1}') vsetvli=$(objdump -d db_bench.$arm | grep -c vsetvli)"
done

# ---- Phase 0: write DBs with BSP (CRC-disable env inside run) ----
quiesce
log "PHASE0 write DB A (default params except compression=none, see DEVIATION) with BSP"
rm -rf "$DBA"
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.BSP --benchmarks=fillrandom \
  --num=10000000 --key_size=16 --value_size=100 --seed=$SEED --threads=1 \
  --db="$DBA" --compression_type=none >> "$FULL" 2>&1 || { log "PHASE0 DBA write FAIL"; exit 1; }
log "PHASE0 write DB B (none/bloom10/cache1G) with BSP"
rm -rf "$DBB"
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.BSP --benchmarks=fillrandom \
  --num=10000000 --key_size=16 --value_size=100 --seed=$SEED --threads=1 \
  --db="$DBB" --compression_type=none --bloom_bits=10 --cache_size=1073741824 \
  >> "$FULL" 2>&1 || { log "PHASE0 DBB write FAIL"; exit 1; }
log "PHASE0 done: $(du -sh $DBA | cut -f1) A, $(du -sh $DBB | cut -f1) B"

# ---- Phase 1: t8 read/seek, warmup then 5 Latin-rotated rounds ----
quiesce
log "PHASE1 warmup (discarded)"
echo "ROUND warmup t8 order=BSP BV5 BV5NS" >> "$RLOG"
for arm in BSP BV5 BV5NS; do bread8 WARMUP "$arm"; aseek8 WARMUP "$arm"; done

for r in 1 2 3 4 5; do
  quiesce
  ORDER=$(rot $r)
  log "PHASE1 round $r order: $ORDER"
  echo "ROUND t8 r$r order=$ORDER" >> "$RLOG"
  for arm in $ORDER; do bread8 RESULT "$arm"; aseek8 RESULT "$arm"; done
done

# ---- Phase 2: fill1, 4 Latin-rotated rounds, fresh dir each run ----
for r in 1 2 3 4; do
  quiesce
  ORDER=$(rot $r)
  log "PHASE2 fill round $r order: $ORDER"
  echo "ROUND fill1 r$r order=$ORDER" >> "$RLOG"
  for arm in $ORDER; do fill1 RESULT "$arm" "$r"; done
done

# ---- Phase 3: t1 read/seek, warmup then 3 Latin-rotated rounds ----
quiesce
log "PHASE3 warmup (discarded)"
echo "ROUND warmup t1 order=BSP" >> "$RLOG"
bread1 WARMUP BSP; aseek1 WARMUP BSP

for r in 1 2 3; do
  quiesce
  ORDER=$(rot $r)
  log "PHASE3 round $r order: $ORDER"
  echo "ROUND t1 r$r order=$ORDER" >> "$RLOG"
  for arm in $ORDER; do bread1 RESULT "$arm"; aseek1 RESULT "$arm"; done
done

log "ALL BENCH DONE"
