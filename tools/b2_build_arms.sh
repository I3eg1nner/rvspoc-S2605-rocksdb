#!/bin/bash
# b2_build_arms.sh — rvv-board2 screening: build BSP / BV5 / BV5NS, all O3+PGO.
# Deployed to ~/s2605-check on rvv-board2; run under nohup.
set -u
cd "$HOME/s2605-check" || exit 1

STATUS="$HOME/s2605-check/b2screen.status"
BLOG="$HOME/s2605-check/b2build.log"

log() { echo "$(date '+%F %T') $*" >> "$STATUS"; }

log "=== build session start ==="
log "ENV uname: $(uname -srm)"
log "ENV gcc: $(gcc --version | head -1)"
log "ENV governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) (no root, common-mode across arms)"

MACROS_ALL="-DROCKSDB_DISABLE_SHORTKEY_CMP -DROCKSDB_DISABLE_INDEX_SIDECAR -DROCKSDB_DISABLE_BINSEEK_PREFETCH -DROCKSDB_DISABLE_RISCV_PAUSE -DROCKSDB_DISABLE_ZBB_VARINT -DROCKSDB_DISABLE_RVV_MEMCMP -DROCKSDB_DISABLE_RVV_XXHASH -DROCKSDB_DISABLE_RVV_BLOOM"
MACROS_V5="-DROCKSDB_DISABLE_SHORTKEY_CMP"
MACROS_V5NS="-DROCKSDB_DISABLE_SHORTKEY_CMP -DROCKSDB_DISABLE_INDEX_SIDECAR -DROCKSDB_DISABLE_BINSEEK_PREFETCH"

clean_objs() {
  find . -name '*.o' -delete
  rm -f db_bench librocksdb.a make_config.mk
}

train() { # $1 = arm name (for logging only); training recipe identical for all arms
  local NAME="$1"
  rm -rf "$HOME/pgo-db"
  log "TRAIN $NAME fillrandom start"
  env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench --benchmarks=fillrandom \
    --num=4000000 --seed=20260822 --threads=1 --db="$HOME/pgo-db" \
    --compression_type=none --bloom_bits=10 >> "$BLOG" 2>&1 || return 1
  log "TRAIN $NAME readrandom start"
  env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench --benchmarks=readrandom \
    --use_existing_db=1 --num=4000000 --seed=20260822 --reads=1500000 --threads=8 \
    --db="$HOME/pgo-db" --compression_type=none --bloom_bits=10 \
    --cache_size=1073741824 >> "$BLOG" 2>&1 || return 1
  # DEVIATION (board2): no snappy dev headers on this board, binary links no
  # compressors, so default-compression opens fail. Force none (common-mode).
  log "TRAIN $NAME seekrandom start"
  env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench --benchmarks=seekrandom \
    --use_existing_db=1 --num=4000000 --seed=20260822 --reads=400000 --seek_nexts=10 \
    --threads=8 --db="$HOME/pgo-db" --compression_type=none >> "$BLOG" 2>&1 || return 1
  return 0
}

build_arm() { # $1=name $2=macros, remaining args = arm-specific make vars
  local NAME="$1"; local MACROS="$2"; shift 2

  if [ "${STAGE2_ONLY:-0}" != "1" ]; then
    log "BUILD $NAME stage1 (profile-generate) start; make vars: $*"
    echo "===== $NAME stage1 =====" >> "$BLOG"
    clean_objs
    rm -rf "$HOME/pgo-$NAME"
    make -j8 db_bench DEBUG_LEVEL=0 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
      CC=gcc CXX=g++ USE_CCACHE=0 "$@" \
      EXTRA_CXXFLAGS="$MACROS" EXTRA_CFLAGS="$MACROS" \
      OPT="-O3 -DNDEBUG -fprofile-generate=$HOME/pgo-$NAME" \
      EXTRA_LDFLAGS="-fprofile-generate=$HOME/pgo-$NAME" >> "$BLOG" 2>&1 \
      || { log "BUILD $NAME stage1 FAIL"; return 1; }

    train "$NAME" || { log "TRAIN $NAME FAIL"; return 1; }
  else
    log "BUILD $NAME resume: STAGE2_ONLY (stage1 binary + profile dir assumed present)"
  fi
  log "TRAIN $NAME done; gcda files: $(find "$HOME/pgo-$NAME" -name '*.gcda' | wc -l)"

  log "BUILD $NAME stage2 (profile-use) start"
  echo "===== $NAME stage2 =====" >> "$BLOG"
  clean_objs
  make -j8 db_bench DEBUG_LEVEL=0 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
    CC=gcc CXX=g++ USE_CCACHE=0 "$@" \
    EXTRA_CXXFLAGS="$MACROS" EXTRA_CFLAGS="$MACROS" \
    OPT="-O3 -DNDEBUG -fprofile-use=$HOME/pgo-$NAME -fprofile-correction -Wno-missing-profile" \
    EXTRA_LDFLAGS="-fprofile-use=$HOME/pgo-$NAME" >> "$BLOG" 2>&1 \
    || { log "BUILD $NAME stage2 FAIL"; return 1; }

  cp db_bench "db_bench.$NAME" || { log "BUILD $NAME cp FAIL"; return 1; }
  local VC SHA
  VC=$(objdump -d "db_bench.$NAME" | grep -c vsetvli)
  SHA=$(sha256sum "db_bench.$NAME" | awk '{print $1}')
  log "BUILD $NAME done vsetvli=$VC sha256=$SHA"
  return 0
}

ARMS_TO_BUILD="${1:-BSP BV5 BV5NS}"
for a in $ARMS_TO_BUILD; do
  case "$a" in
    BSP)   build_arm BSP   "$MACROS_ALL"  RISCV_NO_RVV_CRC32C=1                                        || { log "ABORT at BSP";   exit 1; } ;;
    BV5)   build_arm BV5   "$MACROS_V5"   RISCV_RVV=1 RISCV_RVV_MARCH=rv64gc_zba_zbb_zbs_zicbop_zicond || { log "ABORT at BV5";   exit 1; } ;;
    BV5NS) build_arm BV5NS "$MACROS_V5NS" RISCV_RVV=1 RISCV_RVV_MARCH=rv64gc_zba_zbb_zbs_zicbop_zicond || { log "ABORT at BV5NS"; exit 1; } ;;
    *) log "unknown arm $a"; exit 1 ;;
  esac
done

log "BUILDS DONE: $ARMS_TO_BUILD"
