#!/bin/sh
# FINAL assembly: correctness subset for the sidecar, then the headline
# 3-arm interleaved acceptance run:
#   S  = scalar -O2 (contest stock baseline, PORTABLE rv64gc)
#   G  = final delivery: RVA23 march + PGO + adjudicated defaults + sidecar
#   N  = G minus sidecar (same PGO recipe) -> paired sidecar verdict
# Pre-registered rules from bisect apply to the sidecar verdict.
set -u
cd "$(dirname "$0")"
ST=fin.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST
MARCH=rv64gcv_zba_zbb_zbs_zicbop_zicond
CHK=/root/rocksdb-s2605-check

step SUBSET_SYNC
(cd "$(pwd)" && git ls-files) | while read -r f; do
  mkdir -p "$CHK/$(dirname "$f")"; cp "$f" "$CHK/$f"
done
step SUBSET_BUILD
cd $CHK
env RISCV_RVV=1 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC="ccache gcc" CXX="ccache g++" \
  TEST_TMPDIR=/root/rocksdb-test-tmp \
  make -j6 db_basic_test db_bloom_filter_test db_iterator_test > subset.log 2>&1 || { step SUBSET_BUILD_FAIL; exit 1; }
for t in db_basic_test db_bloom_filter_test db_iterator_test; do
  TEST_TMPDIR=/root/rocksdb-test-tmp ./$t > t-$t.log 2>&1 || { step "SUBSET_FAIL_$t"; exit 1; }
done
step SUBSET_OK
cd - >/dev/null

pgo_build() { # $1 name $2 extra-defines
  step "PGO_GEN_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a; rm -rf /root/pgo-$1; mkdir -p /root/pgo-$1
  env RISCV_RVV=1 RISCV_RVV_MARCH=$MARCH PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
    CC="gcc" CXX="g++" OPT="-O3 -DNDEBUG -fprofile-generate=/root/pgo-$1" \
    EXTRA_CXXFLAGS="$2" EXTRA_CFLAGS="$2" EXTRA_LDFLAGS="-fprofile-generate=/root/pgo-$1" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-fin-$1-gen.log 2>&1 || { step "GEN_FAIL_$1"; exit 1; }
  rm -rf /root/pgo-db
  ./db_bench --benchmarks=fillrandom --num=4000000 --seed=20260822 --threads=1 --db=/root/pgo-db --compression_type=none --bloom_bits=10 >/dev/null 2>&1
  ./db_bench --benchmarks=readrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=1500000 --threads=8 --db=/root/pgo-db --compression_type=none --bloom_bits=10 --cache_size=1073741824 >/dev/null 2>&1
  ./db_bench --benchmarks=seekrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=400000 --seek_nexts=10 --threads=8 --db=/root/pgo-db >/dev/null 2>&1
  step "PGO_USE_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a
  env RISCV_RVV=1 RISCV_RVV_MARCH=$MARCH PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
    CC="gcc" CXX="g++" OPT="-O3 -DNDEBUG -fprofile-use=/root/pgo-$1 -fprofile-correction -Wno-missing-profile" \
    EXTRA_CXXFLAGS="$2" EXTRA_CFLAGS="$2" EXTRA_LDFLAGS="-fprofile-use=/root/pgo-$1" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-fin-$1-use.log 2>&1 || { step "USE_FAIL_$1"; exit 1; }
  cp db_bench db_bench.$1
}

step BUILD_SCALAR
find . -name '*.o' -delete; rm -f db_bench librocksdb.a
env PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC="ccache gcc" CXX="ccache g++" \
  make -j6 db_bench DEBUG_LEVEL=0 > build-fin-scalar.log 2>&1 || { step SCALAR_FAIL; exit 1; }
cp db_bench db_bench.S
pgo_build G ""
pgo_build N "-DROCKSDB_DISABLE_INDEX_SIDECAR"
step BUILDS_OK

N=0
while :; do
  IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}'); [ "$IDLE" -ge 95 ] && break
  N=$((N+1)); [ "$N" -gt 20 ] && { step BUSY; exit 3; }
  sleep 30
done
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done

run() { b=$1; tag=$2; shift 2
  E=""; [ "$b" = S ] && E="ROCKSDB_RVV_CRC32C=0"
  env $E ./db_bench.$b --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $tag \1/p" >> fin.log
}
: > fin.log
B="--compression_type=none --bloom_bits=10 --cache_size=1073741824"
rm -rf /root/fn-A /root/fn-B
./db_bench.S --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/fn-A >/dev/null 2>&1
./db_bench.S --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/fn-B $B >/dev/null 2>&1
run G W --benchmarks=readrandom --use_existing_db=1 --db=/root/fn-B --reads=2000000 --threads=8 $B
run S W --benchmarks=readrandom --use_existing_db=1 --db=/root/fn-B --reads=2000000 --threads=8 $B
run N W --benchmarks=readrandom --use_existing_db=1 --db=/root/fn-B --reads=2000000 --threads=8 $B
i=0
while [ $i -lt 6 ]; do
  case $((i % 3)) in
    0) O="S G N";; 1) O="G N S";; 2) O="N S G";;
  esac
  for a in $O; do
    run $a "$a-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/fn-B --reads=2000000 --threads=8 $B
    run $a "$a-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/fn-A --reads=500000 --seek_nexts=10 --threads=8
  done
  i=$((i+1))
done
i=0
while [ $i -lt 4 ]; do
  case $((i % 3)) in
    0) O="S G N";; 1) O="G N S";; 2) O="N S G";;
  esac
  for a in $O; do
    rm -rf /root/fn-F; run $a "$a-fill" --benchmarks=fillrandom --threads=1 --db=/root/fn-F $B
  done
  i=$((i+1))
done
i=0
while [ $i -lt 3 ]; do
  for a in S G; do
    run $a "$a-Bread-t1" --benchmarks=readrandom --use_existing_db=1 --db=/root/fn-B --reads=2000000 --threads=1 $B
    run $a "$a-Aseek-t1" --benchmarks=seekrandom --use_existing_db=1 --db=/root/fn-A --reads=500000 --seek_nexts=10 --threads=1
  done
  i=$((i+1))
done
step FIN_DONE
