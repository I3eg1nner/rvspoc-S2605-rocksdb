#!/bin/sh
# Candidate #10 (IterKey small-copy) interleaved verdict:
#   R  = existing db_bench.rva23 (pre-#10)
#   P  = freshly built rva23 tier at current HEAD (includes #10)
# Same DBs (f3-A/f3-B written by the 3-arm job's scalar arm), strict
# alternation, warmup discarded. Run from the board tree root.
set -u
cd "$(dirname "$0")/.."
ST=p10.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST

[ -x db_bench.rva23 ] || { step NO_BASE_BINARY; exit 1; }
for bad in "[j]ava" "[c]c1plus"; do pgrep -f "$bad" >/dev/null && { step BUSY_$bad; exit 3; }; done

step BUILD_P10_START
find . -name '*.o' -delete; rm -f db_bench librocksdb.a
env RISCV_RVV=1 RISCV_RVV_MARCH=rv64gcv_zba_zbb_zbs_zicbop_zicond PORTABLE=1 \
  DISABLE_WARNING_AS_ERROR=1 CC="ccache gcc" CXX="ccache g++" \
  make -j6 db_bench DEBUG_LEVEL=0 > build-p10.log 2>&1 || { step BUILD_P10_FAIL; exit 1; }
cp db_bench db_bench.rva23p10
step BUILD_P10_OK

# settle then require idle
sleep 20
IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}'); [ "$IDLE" -ge 93 ] || { step "BUSY idle=$IDLE"; exit 3; }
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done

run() { # $1 bin $2 tag $3.. args
  ./db_bench.$1 --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $2 \1/p" >> p10.log
}
: > p10.log
for CFG in A B; do
  if [ "$CFG" = B ]; then EX="--compression_type=none --bloom_bits=10 --cache_size=1073741824"; else EX=""; fi
  DB=/root/f3-$CFG
  [ -d $DB ] || { step "NO_DB_$CFG"; exit 1; }
  step "CFG $CFG"
  run rva23 W --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=8 $EX
  for i in 1 2 3 4 5; do
    run rva23    "R-$CFG-read-t8" --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=8 $EX
    run rva23p10 "P-$CFG-read-t8" --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=8 $EX
    run rva23    "R-$CFG-seek-t8" --benchmarks=seekrandom --use_existing_db=1 --db=$DB --reads=500000 --seek_nexts=10 --threads=8 $EX
    run rva23p10 "P-$CFG-seek-t8" --benchmarks=seekrandom --use_existing_db=1 --db=$DB --reads=500000 --seek_nexts=10 --threads=8 $EX
  done
  for i in 1 2 3; do
    run rva23    "R-$CFG-read-t1" --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=1 $EX
    run rva23p10 "P-$CFG-read-t1" --benchmarks=readrandom --use_existing_db=1 --db=$DB --reads=2000000 --threads=1 $EX
  done
  FDB=/root/p10fill-$CFG
  for i in 1 2; do
    rm -rf $FDB; run rva23    "R-$CFG-fill" --benchmarks=fillrandom --threads=1 --db=$FDB $EX
    rm -rf $FDB; run rva23p10 "P-$CFG-fill" --benchmarks=fillrandom --threads=1 --db=$FDB $EX
  done
  rm -rf $FDB
done
step P10_DONE
echo P10_DONE >> p10.log
