#!/bin/sh
# Read-only watcher for the board 3-arm job (NEVER carries kill payloads).
while true; do
  s=$(ssh -o ConnectTimeout=12 rvv-board 'tail -1 /root/rocksdb-s2605-new/job.status' 2>/dev/null)
  if [ -n "$s" ]; then
    case "$s" in
      *FINAL3_DONE*|*FAIL*|*BUSY*|*NOT_SCALAR*|*VERIFY_FAIL*) echo "$s"; exit 0;;
    esac
  fi
  sleep 480
done
