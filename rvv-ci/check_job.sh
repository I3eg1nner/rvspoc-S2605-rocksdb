#!/bin/sh
# Full `make check` of the RVV delivery tier (RISCV_RVV=1) — the final
# acceptance gate. Reuses ~/rocksdb-s2605-check as the build dir but
# resyncs sources from the delivery tree first (that dir may hold an
# older commit). Overnight job: build ~2-3h + run 8-16h at J=6.
set -u
SRC=/root/rocksdb-s2605-new
DST=/root/rocksdb-s2605-check
ST=$DST/check2.status
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
mkdir -p $DST; : > $ST

step SYNC
# code sync without touching build outputs (*.o kept for ccache-like reuse
# is pointless across flag change - clean them)
(cd $SRC && git ls-files) | while read -r f; do
  mkdir -p "$DST/$(dirname "$f")"
  cp "$SRC/$f" "$DST/$f"
done
cd $DST
find . -name '*.o' -delete; rm -f librocksdb.a make_config.mk
step SYNC_OK

step CHECK_START
mkdir -p /root/rocksdb-test-tmp
env RISCV_RVV=1 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 \
  CC="ccache gcc" CXX="ccache g++" TEST_TMPDIR=/root/rocksdb-test-tmp \
  make -j6 J=6 check > check2-full.log 2>&1
RC=$?
step "CHECK_RC=$RC"
LC_ALL=C make check-progress 2>/dev/null | grep -E "^\{" | tail -1 >> $ST
step CHECK_JOB_DONE
