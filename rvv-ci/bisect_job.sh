#!/bin/sh
# Per-kernel re-adjudication (external-review item): build 5 variants of
# the F tier via kill switches, interleave each against the full-F
# binary on the same DBs with per-round order alternation. Data decides
# delivery defaults. Run AFTER check3 completes.
set -u
cd "$(dirname "$0")"
ST=bisect2.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST

build() { # $1 name $2 extra-flags
  step "BUILD_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a
  env RISCV_RVV=1 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
    CC="ccache gcc" CXX="ccache g++" EXTRA_CXXFLAGS="$2" EXTRA_CFLAGS="$2" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-$1.log 2>&1 || { step "BUILD_${1}_FAIL"; exit 1; }
  cp db_bench db_bench.$1
}

build fullF ""
build noxxh "-DROCKSDB_DISABLE_RVV_XXHASH"
build nobloom "-DROCKSDB_DISABLE_RVV_BLOOM"
build nomemcmp "-DROCKSDB_DISABLE_RVV_MEMCMP"
build nopref "-DROCKSDB_DISABLE_BINSEEK_PREFETCH"
step BUILDS_OK

N=0
while :; do
  IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}'); [ "$IDLE" -ge 95 ] && break
  N=$((N+1)); [ "$N" -gt 20 ] && { step BUSY; exit 3; }
  sleep 30
done
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done

run() { b=$1; tag=$2; shift 2
  ./db_bench.$b --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $tag \1/p" >> bisect2.log
}
: > bisect2.log
B="--compression_type=none --bloom_bits=10 --cache_size=1073741824"
# DBs: one per config, filled once by fullF
rm -rf /root/bx-A /root/bx-B
./db_bench.fullF --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/bx-A >/dev/null 2>&1
./db_bench.fullF --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/bx-B $B >/dev/null 2>&1
run fullF W --benchmarks=readrandom --use_existing_db=1 --db=/root/bx-B --reads=2000000 --threads=8 $B
# For each variant: 6 interleaved pairs on the most sensitive points,
# alternating order each round to cancel drift/order bias.
for v in noxxh nobloom nomemcmp nopref; do
  step "BISECT_$v"
  i=0
  while [ $i -lt 6 ]; do
    if [ $((i % 2)) -eq 0 ]; then A1=fullF; A2=$v; else A1=$v; A2=fullF; fi
    run $A1 "$A1-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/bx-B --reads=2000000 --threads=8 $B
    run $A2 "$A2-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/bx-B --reads=2000000 --threads=8 $B
    run $A1 "$A1-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/bx-A --reads=500000 --seek_nexts=10 --threads=8
    run $A2 "$A2-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/bx-A --reads=500000 --seek_nexts=10 --threads=8
    i=$((i+1))
  done
done
# memcmp additionally on the write path (skiplist compares): alternating fills
step BISECT_memcmp_fill
i=0
while [ $i -lt 4 ]; do
  if [ $((i % 2)) -eq 0 ]; then A1=fullF; A2=nomemcmp; else A1=nomemcmp; A2=fullF; fi
  rm -rf /root/bx-F; run $A1 "$A1-fill" --benchmarks=fillrandom --threads=1 --db=/root/bx-F $B
  rm -rf /root/bx-F; run $A2 "$A2-fill" --benchmarks=fillrandom --threads=1 --db=/root/bx-F $B
  i=$((i+1))
done
step BISECT2_DONE
