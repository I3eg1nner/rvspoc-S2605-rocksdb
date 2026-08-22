#!/bin/sh
# QEMU correctness matrix for RVV kernels (correctness only, NEVER timing).
# Usage (inside the s2605-rvv-ci container, repo mounted at /w):
#   sh rvv-ci/run_matrix.sh rvv-ci/crc32c_diff.cc util/crc32c_riscv64.cc
# Builds the given sources with the vector arch and runs them under
# qemu-riscv64 at VLEN 128/256/512, each with hostile tail/mask-agnostic
# flags (rvv_ta_all_1s, rvv_ma_all_1s) per rvv-wiki hw-qemu-virt.
set -eu
cd "$(dirname "$0")/.."
CXX="${CXX:-riscv64-linux-gnu-g++}"
OUT=/tmp/rvv_matrix_bin
$CXX -O2 -static -march=rv64gcv_zvbc -DHAVE_RVV_CRC32C \
  -DROCKSDB_PLATFORM_POSIX -DOS_LINUX -I. -Iinclude \
  "$@" -o $OUT
echo "build ok: $CXX $*"
rc=0
for V in 128 256 512; do
  printf "== vlen=%s hostile ta/ma == " "$V"
  if ROCKSDB_RVV_CRC32C=1 qemu-riscv64 \
      -cpu "max,vlen=$V,rvv_ta_all_1s=true,rvv_ma_all_1s=true" $OUT; then
    echo "PASS vlen=$V"
  else
    echo "FAIL vlen=$V"
    rc=1
  fi
done
exit $rc
