#!/bin/sh
# Attribution follow-up to scalar_pgo_control_job.sh (GP < SP on all
# points). Arms, ALL O3+PGO trained on the same recipe:
#   S0 = stock-equivalent scalar -O2 (reused binary, anchor)
#   SP = S0 source + O3+PGO (reused binary)
#   V1 = SP + GLOBAL RVA23-subset vector march, all workspace kernels
#        compile-disabled, no CRC TUs -> isolates march/autovec effect
#   V3 = SP + CRC dispatch ladder ONLY (per-TU Zvbc march + Zbc .insn,
#        runtime-gated; global march stays rv64gc) -> fallback delivery
#   GP = current delivery binary (reused)
# Verdict inputs: V1 vs SP (march drag?), V3 vs SP (CRC gain?), GP vs V1
# (kernels beyond march?).
set -u
cd "$(dirname "$0")"
ST=var.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
: > $ST
MARCH=rv64gcv_zba_zbb_zbs_zicbop_zicond
DIS="-DROCKSDB_DISABLE_SHORTKEY_CMP -DROCKSDB_DISABLE_INDEX_SIDECAR -DROCKSDB_DISABLE_BINSEEK_PREFETCH -DROCKSDB_DISABLE_RISCV_PAUSE -DROCKSDB_DISABLE_ZBB_VARINT -DROCKSDB_DISABLE_RVV_MEMCMP -DROCKSDB_DISABLE_RVV_XXHASH -DROCKSDB_DISABLE_RVV_BLOOM"
step "TREE $(git rev-parse HEAD 2>/dev/null || echo unknown)"

pgo_variant() { # $1 name $2 rvv-flag(0/1) $3 nocrc-flag(0/1) $4 defines
  RV=""; [ "$2" = "1" ] && RV="RISCV_RVV=1 RISCV_RVV_MARCH=$MARCH"
  NC=""; [ "$3" = "1" ] && NC="RISCV_NO_RVV_CRC32C=1"
  step "GEN_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a; rm -rf /root/pgo-$1; mkdir -p /root/pgo-$1
  env $RV $NC PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC=gcc CXX=g++ \
    OPT="-O3 -DNDEBUG -fprofile-generate=/root/pgo-$1" \
    EXTRA_CXXFLAGS="$4" EXTRA_CFLAGS="$4" EXTRA_LDFLAGS="-fprofile-generate=/root/pgo-$1" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-var-$1-gen.log 2>&1 || { step "GEN_FAIL_$1"; exit 1; }
  rm -rf /root/pgo-db
  env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench --benchmarks=fillrandom --num=4000000 --seed=20260822 --threads=1 --db=/root/pgo-db --compression_type=none --bloom_bits=10 >/dev/null 2>&1
  env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench --benchmarks=readrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=1500000 --threads=8 --db=/root/pgo-db --compression_type=none --bloom_bits=10 --cache_size=1073741824 >/dev/null 2>&1
  env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench --benchmarks=seekrandom --use_existing_db=1 --num=4000000 --seed=20260822 --reads=400000 --seek_nexts=10 --threads=8 --db=/root/pgo-db >/dev/null 2>&1
  step "USE_$1"
  find . -name '*.o' -delete; rm -f db_bench librocksdb.a
  env $RV $NC PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CC=gcc CXX=g++ \
    OPT="-O3 -DNDEBUG -fprofile-use=/root/pgo-$1 -fprofile-correction -Wno-missing-profile" \
    EXTRA_CXXFLAGS="$4" EXTRA_CFLAGS="$4" EXTRA_LDFLAGS="-fprofile-use=/root/pgo-$1" \
    make -j6 db_bench DEBUG_LEVEL=0 > build-var-$1-use.log 2>&1 || { step "USE_FAIL_$1"; exit 1; }
  cp db_bench db_bench.$1
  step "VSETVLI_$1=$(objdump -d db_bench.$1 | grep -c vsetvli)"
}

pgo_variant V1 1 1 "$DIS"
pgo_variant V3 0 0 "$DIS"
sha256sum db_bench.S0 db_bench.SP db_bench.V1 db_bench.V3 db_bench.GP >> $ST
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
  case $b in S0|SP|V1) E="ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0";; esac
  env $E ./db_bench.$b --num=20000000 --seed=20260822 "$@" 2>/dev/null \
    | sed -n "s/^\([a-z]*random.*\)$/RESULT $tag \1/p" >> var.log
}
: > var.log
B="--compression_type=none --bloom_bits=10 --cache_size=1073741824"
rm -rf /root/vr-A /root/vr-B
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.S0 --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/vr-A >/dev/null 2>&1
env ROCKSDB_RVV_CRC32C=0 ROCKSDB_ZBC_CRC32C=0 ./db_bench.S0 --benchmarks=fillrandom --num=20000000 --seed=20260822 --threads=1 --db=/root/vr-B $B >/dev/null 2>&1
step DBS_READY
for a in S0 SP V1 V3 GP; do
  run $a W --benchmarks=readrandom --use_existing_db=1 --db=/root/vr-B --reads=2000000 --threads=8 $B
done
ARMS="S0 SP V1 V3 GP"
i=0
while [ $i -lt 5 ]; do
  O=$(echo $ARMS | awk -v k=$i '{n=split($0,a," "); s=""; for(j=0;j<n;j++){s=s" "a[((j+k)%n)+1]} print s}')
  for a in $O; do
    run $a "$a-Bread" --benchmarks=readrandom --use_existing_db=1 --db=/root/vr-B --reads=2000000 --threads=8 $B
    run $a "$a-Aseek" --benchmarks=seekrandom --use_existing_db=1 --db=/root/vr-A --reads=500000 --seek_nexts=10 --threads=8
  done
  i=$((i+1))
done
step RS_DONE
i=0
while [ $i -lt 4 ]; do
  O=$(echo $ARMS | awk -v k=$i '{n=split($0,a," "); s=""; for(j=0;j<n;j++){s=s" "a[((j+k)%n)+1]} print s}')
  for a in $O; do
    rm -rf /root/vr-F; run $a "$a-fill" --benchmarks=fillrandom --threads=1 --db=/root/vr-F $B
  done
  i=$((i+1))
done
step FILL_DONE
i=0
while [ $i -lt 3 ]; do
  for a in $ARMS; do
    run $a "$a-Bread-t1" --benchmarks=readrandom --use_existing_db=1 --db=/root/vr-B --reads=2000000 --threads=1 $B
    run $a "$a-Aseek-t1" --benchmarks=seekrandom --use_existing_db=1 --db=/root/vr-A --reads=500000 --seek_nexts=10 --threads=1
  done
  i=$((i+1))
done
systemctl start sddm bianbu-ddr-bwd fwupd 2>/dev/null
step VAR_DONE
