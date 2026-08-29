#!/bin/sh
# Final-assembly decision run. Arms (all O3+PGO except S-anchor omitted;
# SP reused as anchor):
#   SP = scalar O3+PGO (reused)
#   V2 = FRESH full-delivery rebuild (RVA23-subset march + all
#        adjudicated kernels) - controls for GP's stale-session profile
#   V5 = NO-V scalar-subset march (rv64gc_zba_zbb_zbs_zicbop_zicond) +
#        every kernel that doesn't need __riscv_vector: zbb-varint,
#        index sidecar, binseek prefetch, pause, CRC runtime ladder
#        (Zvbc TU per-TU march + Zbc .insn). No autovec drag by
#        construction.
#   GP = old delivery binary (continuity anchor)
set -u
cd "$(dirname "$0")"
ST=vf.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST
MARCH_V=rv64gcv_zba_zbb_zbs_zicbop_zicond
MARCH_S=rv64gc_zba_zbb_zbs_zicbop_zicond
step "TREE $(git rev-parse HEAD 2>/dev/null || echo unknown)"

pgo_variant() { # $1 name $2 march $3 defines
  step "GEN_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a make_config.mk; rm -rf /root/pgo-$1; mkdir -p /root/pgo-$1
  env RISCV_RVV=1 RISCV_RVV_MARCH=$2 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC=gcc CXX=g++ \
    OPT="-O3 -DNDEBUG -fprofile-generate=/root/pgo-$1" \
    EXTRA_CXXFLAGS="$3" EXTRA_CFLAGS="$3" EXTRA_LDFLAGS="-fprofile-generate=/root/pgo-$1" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-vf-$1-gen.log 2>&1 || { step "GEN_FAIL_$1"; exit 1; }
  rm -rf /root/pgo-db
  ./db_bench --benchmarks=fillrandom --num=4000000 --seed=20260822 --threads=1 --db=/root/pgo-db --compression_type=none --bloom_bits=10 >/dev/null 2>&1
  ./db_bench --benchmarks=readrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=1500000 --threads=8 --db=/root/pgo-db --compression_type=none --bloom_bits=10 --cache_size=1073741824 >/dev/null 2>&1
  ./db_bench --benchmarks=seekrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=400000 --seek_nexts=10 --threads=8 --db=/root/pgo-db >/dev/null 2>&1
  step "USE_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a
  env RISCV_RVV=1 RISCV_RVV_MARCH=$2 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC=gcc CXX=g++ \
    OPT="-O3 -DNDEBUG -fprofile-use=/root/pgo-$1 -fprofile-correction -Wno-missing-profile" \
    EXTRA_CXXFLAGS="$3" EXTRA_CFLAGS="$3" EXTRA_LDFLAGS="-fprofile-use=/root/pgo-$1" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-vf-$1-use.log 2>&1 || { step "USE_FAIL_$1"; exit 1; }
  cp db_bench db_bench.$1
  step "VSETVLI_$1=$(objdump -d db_bench.$1 | grep -c vsetvli)"
}

pgo_variant V2 $MARCH_V ""
pgo_variant V5 $MARCH_S ""
sha256sum db_bench.SP db_bench.V2 db_bench.V5 db_bench.GP >> $ST
step BUILDS_OK

systemctl stop sddm bianbu-ddr-bwd fwupd 2>/dev/null; sleep 3; pkill -u sddm 2>/dev/null
N=0
while :; do
  IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}'); [ "$IDLE" -ge 97 ] && break
  N=$((N+1)); [ "$N" -gt 20 ] && { step BUSY; exit 3; }
  sleep 30
done
pgrep -f "[B]rokerStartup|[b]enchmark.Producer" >/dev/null && { step DIRTY_BOARD; exit 3; }
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done

run() { b=$1; tag=$2; shift 2
  E=""
  [ "$b" = "SP" ] && E="ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0"
  env $E ./db_bench.$b --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $tag \1/p" >> vf.log
}
: > vf.log
B="--compression_type=none --bloom_bits=10 --cache_size=1073741824"
rm -rf /root/vf-A /root/vf-B
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.SP --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/vf-A >/dev/null 2>&1
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.SP --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/vf-B $B >/dev/null 2>&1
step DBS_READY
ARMS="SP V2 V5 GP"
for a in $ARMS; do
  run $a W --benchmarks=readrandom --use_existing_db=1 --db=/root/vf-B --reads=2000000 --threads=8 $B
done
i=0
while [ $i -lt 5 ]; do
  O=$(echo $ARMS | awk -v k=$i '{n=split($0,a," "); s=""; for(j=0;j<n;j++){s=s" "a[((j+k)%n)+1]} print s}')
  for a in $O; do
    run $a "$a-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/vf-B --reads=2000000 --threads=8 $B
    run $a "$a-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/vf-A --reads=500000 --seek_nexts=10 --threads=8
  done
  i=$((i+1))
done
step RS_DONE
i=0
while [ $i -lt 4 ]; do
  O=$(echo $ARMS | awk -v k=$i '{n=split($0,a," "); s=""; for(j=0;j<n;j++){s=s" "a[((j+k)%n)+1]} print s}')
  for a in $O; do
    rm -rf /root/vf-F; run $a "$a-fill" --benchmarks=fillrandom --threads=1 --db=/root/vf-F $B
  done
  i=$((i+1))
done
step FILL_DONE
i=0
while [ $i -lt 3 ]; do
  for a in $ARMS; do
    run $a "$a-Bread-t1" --benchmarks=readrandom --use_existing_db=1 --db=/root/vf-B --reads=2000000 --threads=1 $B
    run $a "$a-Aseek-t1" --benchmarks=seekrandom --use_existing_db=1 --db=/root/vf-A --reads=500000 --seek_nexts=10 --threads=1
  done
  i=$((i+1))
done
systemctl start sddm bianbu-ddr-bwd fwupd 2>/dev/null
step VF_DONE
