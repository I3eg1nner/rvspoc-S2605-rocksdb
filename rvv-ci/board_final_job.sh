#!/bin/sh
# S2605 one-shot board job: build 3 tiers from the same commit, verify
# each, then run the 3-arm interleaved acceptance A/B. Designed to be
# nohup'd and survive ssh-link flaps; progress lands in job.status.
set -u
cd "$(dirname "$0")"
ST=job.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST

MK="env PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC=ccache\ gcc CXX=ccache\ g++ make -j6 db_bench DEBUG_LEVEL=0"
clean_objs() { find . -name '*.o' -delete; rm -f db_bench librocksdb.a; }

if [ "${SKIP_BUILD:-0}" = "1" ] && [ -x db_bench.scalar ] && [ -x db_bench.final ] && [ -x db_bench.rva23 ]; then
  step SKIP_BUILD_REUSING_BINARIES
else
step BUILD_SCALAR_START
clean_objs
eval $MK > build-scalar.log 2>&1 || { step BUILD_SCALAR_FAIL; exit 1; }
V=$(objdump -d db_bench | grep -c vsetvli)
step "SCALAR vsetvli=$V (hwprobe-gated CRC TU only; S arm runs with ROCKSDB_RVV_CRC32C=0)"
[ "$V" -lt 50 ] || { step SCALAR_NOT_SCALAR; exit 1; }
cp db_bench db_bench.scalar
step BUILD_SCALAR_OK

step BUILD_GCV_START
clean_objs
env RISCV_RVV=1 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC="ccache gcc" CXX="ccache g++" \
  make -j6 db_bench DEBUG_LEVEL=0 > build-gcv.log 2>&1 || { step BUILD_GCV_FAIL; exit 1; }
V=$(objdump -d db_bench | grep -c vsetvli); P=$(objdump -d db_bench | grep -c "prefetch\.")
step "GCV vsetvli=$V prefetch=$P"
[ "$V" -gt 500 ] && [ "$P" -gt 0 ] || { step GCV_VERIFY_FAIL; exit 1; }
cp db_bench db_bench.final
step BUILD_GCV_OK

step BUILD_RVA23_START
clean_objs
env RISCV_RVV=1 RISCV_RVV_MARCH=rv64gcv_zba_zbb_zbs_zicbop_zicond PORTABLE=1 \
  DISABLE_WARNING_AS_ERROR=1 CC="ccache gcc" CXX="ccache g++" \
  make -j6 db_bench DEBUG_LEVEL=0 > build-rva23.log 2>&1 || { step BUILD_RVA23_FAIL; exit 1; }
V=$(objdump -d db_bench | grep -c vsetvli); Z=$(objdump -d db_bench | grep -cE "\bctz")
step "RVA23 vsetvli=$V ctz=$Z"
[ "$V" -gt 500 ] && [ "$Z" -gt 0 ] || { step RVA23_VERIFY_FAIL; exit 1; }
cp db_bench db_bench.rva23
step BUILD_RVA23_OK

# quick functional sanity of all 3 (also proves CRC probe on each)
for b in scalar final rva23; do
  rm -rf /tmp/js-$b
  ./db_bench.$b --benchmarks=fillrandom,readrandom --num=50000 --db=/tmp/js-$b >/dev/null 2>&1 \
    || { step SANITY_FAIL_$b; exit 1; }
done
step SANITY_OK
fi

# ---- 3-arm interleaved acceptance A/B ----
# settle gate: wait up to 10 min for true idle instead of hard-failing
N=0
while :; do
  IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}')
  [ "$IDLE" -ge 95 ] && break
  N=$((N+1)); [ "$N" -gt 20 ] && { step "BOARD_BUSY idle=$IDLE"; exit 3; }
  step "settle idle=$IDLE"; sleep 30
done
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done
run() { # $1 bin-suffix $2 tag $3.. args
  b=$1; tag=$2; shift 2
  E=""
  [ "$b" = scalar ] && E="ROCKSDB_RVV_CRC32C=0"
  env $E ./db_bench.$b --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $tag \1/p" >> final3.log
}
: > final3.log
for CFG in A B; do
  if [ "$CFG" = B ]; then EX="--compression_type=none --bloom_bits=10 --cache_size=1073741824"; else EX=""; fi
  DB=/root/f3-$CFG
  step "CFG $CFG fills"
  for i in 1 2; do
    for arm in scalar final rva23; do
      rm -rf $DB
      run $arm "$(echo $arm | cut -c1 | tr sfr SFR)-$CFG-fill" --benchmarks=fillrandom --threads=1 --db=$DB $EX
    done
  done
  rm -rf $DB
  ./db_bench.scalar --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=$DB $EX >/dev/null 2>&1
  step "CFG $CFG reads"
  run final W --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=8 $EX
  for i in 1 2 3 4 5; do
    for arm in scalar final rva23; do
      T=$(echo $arm | cut -c1 | tr sfr SFR)
      run $arm "$T-$CFG-read-t8" --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=8 $EX
      run $arm "$T-$CFG-seek-t8" --benchmarks=seekrandom --use_existing_db=1 --db=$DB --reads=500000 --seek_nexts=10 --threads=8 $EX
    done
  done
  for i in 1 2 3; do
    for arm in scalar final rva23; do
      T=$(echo $arm | cut -c1 | tr sfr SFR)
      run $arm "$T-$CFG-read-t1" --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=1 $EX
      run $arm "$T-$CFG-seek-t1" --benchmarks=seekrandom --use_existing_db=1 --db=$DB --reads=500000 --seek_nexts=10 --threads=1 $EX
    done
  done
done
step FINAL3_DONE
echo FINAL3_DONE >> final3.log
