#!/bin/sh
# Review-response control run (2026-08-29):
#   S0 = TRUE stock-equivalent scalar -O2: PORTABLE rv64gc with EVERY
#        workspace riscv path compile-disabled (shortkey/sidecar/
#        binseek-prefetch/pause/zbb-varint) + CRC env-gated off at run
#        time. The previous S arm carried __riscv-guarded paths that
#        are NOT gated on RISCV_RVV=1 - it was faster than stock, so
#        published deltas were conservative; S0 fixes the baseline
#        definition.
#   SP = same source/flags as S0 but -O3 + PGO trained on the same
#        fill/read/seek recipe as the delivery build -> separates
#        generic PGO/O3 gains from RISC-V/RVV-specific gains.
#   G  = existing delivery binary db_bench.GP (RVA23-subset march +
#        O3 + PGO + adjudicated kernels), UNTOUCHED.
# Deltas to publish: G vs S0 (headline), SP vs S0 (generic share),
# G vs SP (riscv-specific share).
set -u
cd "$(dirname "$0")"
ST=sp.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST
DIS="-DROCKSDB_DISABLE_SHORTKEY_CMP -DROCKSDB_DISABLE_INDEX_SIDECAR -DROCKSDB_DISABLE_BINSEEK_PREFETCH -DROCKSDB_DISABLE_RISCV_PAUSE -DROCKSDB_DISABLE_ZBB_VARINT -DROCKSDB_DISABLE_RVV_MEMCMP -DROCKSDB_DISABLE_RVV_XXHASH -DROCKSDB_DISABLE_RVV_BLOOM"
step "TREE $(git rev-parse HEAD 2>/dev/null || echo unknown) GCC $(gcc -dumpfullversion)"

step BUILD_S0
find . -name '*.o' -delete; rm -f db_bench librocksdb.a
env PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC="ccache gcc" CXX="ccache g++" \
  EXTRA_CXXFLAGS="$DIS" EXTRA_CFLAGS="$DIS" \
  make -j6 db_bench DEBUG_LEVEL=0 > build-sp-s0.log 2>&1 || { step S0_FAIL; exit 1; }
cp db_bench db_bench.S0
[ "$(objdump -d db_bench.S0 | grep -c vsetvli)" = "0" ] || { step S0_VECTOR_TRIPWIRE; exit 1; }

step BUILD_SP_GEN
find . -name '*.o' -delete; rm -f db_bench librocksdb.a; rm -rf /root/pgo-SP; mkdir -p /root/pgo-SP
env PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC="gcc" CXX="g++" \
  OPT="-O3 -DNDEBUG -fprofile-generate=/root/pgo-SP" \
  EXTRA_CXXFLAGS="$DIS" EXTRA_CFLAGS="$DIS" EXTRA_LDFLAGS="-fprofile-generate=/root/pgo-SP" \
  make -j6 db_bench DEBUG_LEVEL=0 > build-sp-gen.log 2>&1 || { step SP_GEN_FAIL; exit 1; }
rm -rf /root/pgo-db
export ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0
./db_bench --benchmarks=fillrandom --num=4000000 --seed=20260822 --threads=1 --db=/root/pgo-db --compression_type=none --bloom_bits=10 >/dev/null 2>&1
./db_bench --benchmarks=readrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=1500000 --threads=8 --db=/root/pgo-db --compression_type=none --bloom_bits=10 --cache_size=1073741824 >/dev/null 2>&1
./db_bench --benchmarks=seekrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=400000 --seek_nexts=10 --threads=8 --db=/root/pgo-db >/dev/null 2>&1
step BUILD_SP_USE
find . -name '*.o' -delete; rm -f db_bench librocksdb.a
env PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC="gcc" CXX="g++" \
  OPT="-O3 -DNDEBUG -fprofile-use=/root/pgo-SP -fprofile-correction -Wno-missing-profile" \
  EXTRA_CXXFLAGS="$DIS" EXTRA_CFLAGS="$DIS" EXTRA_LDFLAGS="-fprofile-use=/root/pgo-SP" \
  make -j6 db_bench DEBUG_LEVEL=0 > build-sp-use.log 2>&1 || { step SP_USE_FAIL; exit 1; }
cp db_bench db_bench.SP
[ "$(objdump -d db_bench.SP | grep -c vsetvli)" = "0" ] || { step SP_VECTOR_TRIPWIRE; exit 1; }
sha256sum db_bench.S0 db_bench.SP db_bench.GP >> $ST
step BUILDS_OK

N=0
while :; do
  IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}'); [ "$IDLE" -ge 95 ] && break
  N=$((N+1)); [ "$N" -gt 20 ] && { step BUSY; exit 3; }
  sleep 30
done
pgrep -f "[B]rokerStartup|[b]enchmark.Producer" >/dev/null && { step DIRTY_BOARD; exit 3; }
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done

run() { b=$1; tag=$2; shift 2
  E=""
  case $b in S0|SP) E="ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0";; esac
  env $E ./db_bench.$b --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $tag \1/p" >> sp.log
}
: > sp.log
B="--compression_type=none --bloom_bits=10 --cache_size=1073741824"
rm -rf /root/sp-A /root/sp-B
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.S0 --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/sp-A >/dev/null 2>&1
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.S0 --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/sp-B $B >/dev/null 2>&1
run GP W --benchmarks=readrandom --use_existing_db=1 --db=/root/sp-B --reads=2000000 --threads=8 $B
run S0 W --benchmarks=readrandom --use_existing_db=1 --db=/root/sp-B --reads=2000000 --threads=8 $B
run SP W --benchmarks=readrandom --use_existing_db=1 --db=/root/sp-B --reads=2000000 --threads=8 $B
i=0
while [ $i -lt 6 ]; do
  case $((i % 3)) in
    0) O="S0 SP GP";; 1) O="SP GP S0";; 2) O="GP S0 SP";;
  esac
  for a in $O; do
    run $a "$a-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/sp-B --reads=2000000 --threads=8 $B
    run $a "$a-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/sp-A --reads=500000 --seek_nexts=10 --threads=8
  done
  i=$((i+1))
done
i=0
while [ $i -lt 4 ]; do
  case $((i % 3)) in
    0) O="S0 SP GP";; 1) O="SP GP S0";; 2) O="GP S0 SP";;
  esac
  for a in $O; do
    rm -rf /root/sp-F; run $a "$a-fill" --benchmarks=fillrandom --threads=1 --db=/root/sp-F $B
  done
  i=$((i+1))
done
i=0
while [ $i -lt 3 ]; do
  for a in S0 SP GP; do
    run $a "$a-Bread-t1" --benchmarks=readrandom --use_existing_db=1 --db=/root/sp-B --reads=2000000 --threads=1 $B
    run $a "$a-Aseek-t1" --benchmarks=seekrandom --use_existing_db=1 --db=/root/sp-A --reads=500000 --seek_nexts=10 --threads=1
  done
  i=$((i+1))
done
step SP_DONE
