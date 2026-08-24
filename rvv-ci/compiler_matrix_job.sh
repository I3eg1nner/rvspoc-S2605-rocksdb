#!/bin/sh
# Compiler/whole-program-optimization matrix (external review P1) plus
# the shortkey-cmp paired verdict. Arms (all RISCV_RVV=1 tier, RVA23
# march) built from the same commit:
#   base    : gcc -O2                    (current delivery flags)
#   o3lto   : gcc -O3 -flto=6 -fno-semantic-interposition
#   pgo     : gcc -O3 -flto=6 + PGO (train: fill+read+seek, all three)
#   noshort : base + -DROCKSDB_DISABLE_SHORTKEY_CMP (paired shortkey verdict)
# clang arm is exercised in CI containers, not on-board (no board clang).
# Protocol: interleaved pairs vs `base` on B-read t8, A-seek t8 and
# fill t1, order alternation, warmups discarded (bisect rules apply:
# percent deltas, N=6, INCONCLUSIVE->not adopted).
set -u
cd "$(dirname "$0")"
ST=cmx.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST
MARCH=rv64gcv_zba_zbb_zbs_zicbop_zicond

build() { # $1 name $2 opt-flags $3 extra-defines
  step "BUILD_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a
  env RISCV_RVV=1 RISCV_RVV_MARCH=$MARCH PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
    CC="gcc" CXX="g++" OPT="$2" EXTRA_CXXFLAGS="$3" EXTRA_CFLAGS="$3" EXTRA_LDFLAGS="$2" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-cmx-$1.log 2>&1 || { step "BUILD_${1}_FAIL"; return 1; }
  cp db_bench db_bench.$1
}

build base "-O2 -DNDEBUG" "" || exit 1
build noshort "-O2 -DNDEBUG" "-DROCKSDB_DISABLE_SHORTKEY_CMP" || exit 1
build o3lto "-O3 -DNDEBUG -flto=6 -fno-semantic-interposition -ffat-lto-objects" "" || step O3LTO_SKIPPED

# PGO: generate -> train on all three workloads -> use
step PGO_GEN
find . -name '*.o' -delete; rm -f db_bench librocksdb.a; rm -rf /root/pgo-data; mkdir -p /root/pgo-data
if env RISCV_RVV=1 RISCV_RVV_MARCH=$MARCH PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
    CC="gcc" CXX="g++" OPT="-O3 -DNDEBUG -fprofile-generate=/root/pgo-data" \
    EXTRA_LDFLAGS="-fprofile-generate=/root/pgo-data" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-cmx-pgogen.log 2>&1; then
  step PGO_TRAIN
  rm -rf /root/pgo-db
  ./db_bench --benchmarks=fillrandom --num=4000000 --seed=20260822 --threads=1 --db=/root/pgo-db --compression_type=none --bloom_bits=10 >/dev/null 2>&1
  ./db_bench --benchmarks=readrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=1500000 --threads=8 --db=/root/pgo-db --compression_type=none --bloom_bits=10 --cache_size=1073741824 >/dev/null 2>&1
  ./db_bench --benchmarks=seekrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=400000 --seek_nexts=10 --threads=8 --db=/root/pgo-db >/dev/null 2>&1
  step PGO_USE
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a
  env RISCV_RVV=1 RISCV_RVV_MARCH=$MARCH PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
    CC="gcc" CXX="g++" OPT="-O3 -DNDEBUG -fprofile-use=/root/pgo-data -fprofile-correction -Wno-missing-profile" \
    EXTRA_LDFLAGS="-fprofile-use=/root/pgo-data" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-cmx-pgouse.log 2>&1 && cp db_bench db_bench.pgo || step PGO_USE_FAIL
else
  step PGO_GEN_FAIL
fi
step BUILDS_DONE

N=0
while :; do
  IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}'); [ "$IDLE" -ge 95 ] && break
  N=$((N+1)); [ "$N" -gt 20 ] && { step BUSY; exit 3; }
  sleep 30
done
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done

run() { b=$1; tag=$2; shift 2
  ./db_bench.$b --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $tag \1/p" >> cmx.log
}
: > cmx.log
B="--compression_type=none --bloom_bits=10 --cache_size=1073741824"
rm -rf /root/cx-A /root/cx-B
./db_bench.base --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/cx-A >/dev/null 2>&1
./db_bench.base --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/cx-B $B >/dev/null 2>&1

pairs() { # $1 variant
  v=$1
  [ -x db_bench.$v ] || { step "SKIP_$v"; return 0; }
  step "PAIRS_$v"
  run $v W --benchmarks=readrandom --use_existing_db=1 --db=/root/cx-B --reads=2000000 --threads=8 $B
  run base W --benchmarks=readrandom --use_existing_db=1 --db=/root/cx-B --reads=2000000 --threads=8 $B
  i=0
  while [ $i -lt 6 ]; do
    if [ $((i % 2)) -eq 0 ]; then A1=base; A2=$v; else A1=$v; A2=base; fi
    run $A1 "$A1-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/cx-B --reads=2000000 --threads=8 $B
    run $A2 "$A2-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/cx-B --reads=2000000 --threads=8 $B
    run $A1 "$A1-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/cx-A --reads=500000 --seek_nexts=10 --threads=8
    run $A2 "$A2-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/cx-A --reads=500000 --seek_nexts=10 --threads=8
    i=$((i+1))
  done
  rm -rf /root/cx-F; run $v W --benchmarks=fillrandom --threads=1 --db=/root/cx-F $B
  rm -rf /root/cx-F; run base W --benchmarks=fillrandom --threads=1 --db=/root/cx-F $B
  i=0
  while [ $i -lt 6 ]; do
    if [ $((i % 2)) -eq 0 ]; then A1=base; A2=$v; else A1=$v; A2=base; fi
    rm -rf /root/cx-F; run $A1 "$A1-fill" --benchmarks=fillrandom --threads=1 --db=/root/cx-F $B
    rm -rf /root/cx-F; run $A2 "$A2-fill" --benchmarks=fillrandom --threads=1 --db=/root/cx-F $B
    i=$((i+1))
  done
}

pairs noshort
pairs o3lto
pairs pgo
step CMX_DONE
