#!/bin/sh
# RocketMQ dual-arm evaluation matrix, v6 (review-hardened):
#   full product: {scalar,rvv} x {1K,16K,128K} x {normal,backlog}
#   x {AB,BA} order rotation  => 24 runs.
#   Per run: fresh store, a WARM-second discarded warm-up producer
#   (broker cold-start fast-fail [SYSTEM_BUSY on first-touch mmap]
#   produced a benign Send Failed burst in the first ~145s of the first
#   16K cell — flow control, not loss; the measured window must still
#   be failure-free), then DUR seconds of measured load, then producer
#   stops and the consumer DRAINS to zero backlog (bounded). Strict
#   accounting via store offsets locked AFTER warm-up. ANY failure
#   (service boot, empty counters, nonzero Send/Response/Consume
#   failures in the MEASURED window, drain timeout) aborts the matrix.
#   Identity chain: jar sha256 + broker JVM cmdline recorded per run.
# Usage: [SIZES="1024 16384 131072"] rocketmq_matrix.sh <scalar_jar> <rvv_jar> [cell_secs=300]
#   SIZES env allows resuming a partially-completed matrix without
#   truncating matrix.status / accounting.txt (append-only).
set -u
SJAR=$1; RJAR=$2; DUR=${3:-300}
WARM=${WARM:-45}
SIZES=${SIZES:-"1024 16384 131072"}
RMQ=/root/rocketmq-all-5.5.0-bin-release
OUT=/root/rmq-matrix
ST=$OUT/matrix.status
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-riscv64
export NAMESRV_ADDR=127.0.0.1:9876
mkdir -p $OUT; touch $ST $OUT/accounting.txt
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
die() { step "ABORT $1"; cleanup; exit 1; }

cleanup() {
  pkill -f "[b]enchmark.Producer" 2>/dev/null; pkill -f "[b]enchmark.Consumer" 2>/dev/null
  sh $RMQ/bin/mqshutdown broker >/dev/null 2>&1; sh $RMQ/bin/mqshutdown namesrv >/dev/null 2>&1
  sleep 8; pkill -9 -f "[B]rokerStartup" 2>/dev/null; pkill -9 -f "[N]amesrvStartup" 2>/dev/null
}
trap cleanup EXIT INT TERM

sha256sum "$SJAR" "$RJAR" >> $OUT/jar-identity.txt

# Accounting via store offsets (exact): brokerStatus msgPut/GetTotal*
# counters were empirically DEAD in this deployment (stayed 0 after 50k
# verified sends). topicStatus maxOffset sum = exact messages put;
# consumerProgress Diff Total = exact backlog.
put_total() {
  sh $RMQ/bin/mqadmin topicStatus -n 127.0.0.1:9876 -t BenchmarkTest 2>/dev/null \
    | awk '$2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {s+=$4} END{if(NR>0) print s+0}'
}
backlog_total() {
  # tolerate both output shapes: detail view (-g) footer "Diff Total: N"
  # and list view row "benchmark_consumer ... N"; -1 = query failed
  # (treated as "not yet drained" by the caller, only timeout aborts)
  sh $RMQ/bin/mqadmin consumerProgress -n 127.0.0.1:9876 -g benchmark_consumer 2>/dev/null \
    | awk '/[Dd]iff.?[Tt]otal/{v=$NF} /^benchmark_consumer[ \t]/{v=$NF} END{if(v ~ /^[0-9]+$/) print v; else print -1}'
}

run_cell() { # $1 arm $2 jar $3 size $4 scene $5 order-tag
  CELL="$1-s$3-$4-$5"; D=$OUT/$CELL; mkdir -p $D
  step "CELL_START $CELL"
  cleanup
  # rocksdbjni extracts a ~404MB .so to /tmp per broker start (random
  # suffix); killed JVMs never deleteOnExit, and 9 leaked copies filled
  # the 3.9G tmpfs (= RAM!) mid-matrix. Reap them every cell.
  rm -f /tmp/librocksdbjni*.so 2>/dev/null
  # /root/store may be a symlink onto the NVMe data disk: clean the
  # TARGET contents and re-point the link (rm -rf on the link would
  # silently move the store back onto the system disk next boot).
  rm -rf /root/store /data/rmq-store
  mkdir -p /data/rmq-store && ln -sfn /data/rmq-store /root/store
  sleep 3
  rm -f $RMQ/lib/rocksdbjni-*.jar $RMQ/lib/rocketmq-rocksdb-*.jar
  cp "$2" $RMQ/lib/ || die "jar_copy $CELL"
  cd $RMQ
  nohup sh bin/mqnamesrv > $D/namesrv.log 2>&1 < /dev/null &
  sleep 20; grep -q "boot success" $D/namesrv.log || die "namesrv_boot $CELL"
  nohup sh bin/mqbroker -n 127.0.0.1:9876 > $D/broker.log 2>&1 < /dev/null &
  sleep 40; grep -q "boot success" $D/broker.log || die "broker_boot $CELL"
  cat /proc/$(pgrep -f "[j]ava.*BrokerStartup" | head -1)/cmdline | tr '\0' ' ' > $D/broker-cmdline.txt
  # Pre-create the topic: on a fresh store the auto-create race produces
  # a burst of Send Failed at producer start, permanently polluting the
  # cumulative failure counters this matrix gates on.
  sh $RMQ/bin/mqadmin updateTopic -n 127.0.0.1:9876 -b 127.0.0.1:10911 \
    -t BenchmarkTest -w 8 -r 8 > $D/topic-create.log 2>&1 || die "topic_create $CELL"
  sleep 3
  cd $RMQ/benchmark
  # normal scene: consumer up BEFORE warm-up so warm-up messages are
  # consumed during warm-up and don't skew the measured consume side.
  if [ "$4" = "normal" ]; then
    nohup sh consumer.sh -n 127.0.0.1:9876 > $D/consumer.log 2>&1 < /dev/null &
    sleep 10
    pgrep -f "[b]enchmark.Consumer" >/dev/null || die "consumer_start $CELL"
  fi
  # WARM-second discarded warm-up: same message size, own log, its Send
  # Failed counters are EXPECTED (cold-start fast-fail) and not gated.
  nohup sh producer.sh -n 127.0.0.1:9876 -s "$3" -w 8 > $D/producer-warmup.log 2>&1 < /dev/null &
  sleep $WARM
  pgrep -f "[b]enchmark.Producer" >/dev/null || die "warmup_producer_start $CELL"
  pkill -f "[b]enchmark.Producer"
  sleep 5; pgrep -f "[b]enchmark.Producer" >/dev/null && { pkill -9 -f "[b]enchmark.Producer"; sleep 3; }
  # lock the accounting baseline AFTER warm-up (stable across 2 polls)
  P0=$(put_total); [ -n "$P0" ] || die "empty_offsets_pre $CELL"
  W=0
  while [ $W -lt 6 ]; do
    sleep 5; PW=$(put_total); [ -n "$PW" ] || die "empty_offsets_pre2 $CELL"
    [ "$PW" = "$P0" ] && break
    P0=$PW; W=$((W+1))
  done
  [ $W -lt 6 ] || die "warmup_offset_never_stabilized $CELL"
  nohup sh producer.sh -n 127.0.0.1:9876 -s "$3" -w 8 > $D/producer.log 2>&1 < /dev/null &
  if [ "$4" = "normal" ]; then
    :
  else
    ( sleep $((DUR / 2)); cd $RMQ/benchmark && nohup sh consumer.sh -n 127.0.0.1:9876 > $D/consumer.log 2>&1 < /dev/null & ) &
  fi
  sleep 15
  pgrep -f "[b]enchmark.Producer" >/dev/null || die "producer_start $CELL"
  if [ "$4" = "normal" ]; then
    pgrep -f "[b]enchmark.Consumer" >/dev/null || die "consumer_start $CELL"
    sleep $((DUR - 15))
  else
    sleep $((DUR / 2))
    sleep 15
    pgrep -f "[b]enchmark.Consumer" >/dev/null || die "consumer_start_backlog $CELL"
    sleep $((DUR - DUR / 2 - 30))
  fi
  pkill -f "[b]enchmark.Producer"
  # confirm producer exit, then lock PUT_TARGET once the counter is
  # stable across two consecutive polls (no in-flight messages left)
  sleep 5; pgrep -f "[b]enchmark.Producer" >/dev/null && { sleep 5; pkill -9 -f "[b]enchmark.Producer"; sleep 3; }
  PP=$(put_total); [ -n "$PP" ] || die "empty_offsets_put $CELL"
  S=0
  while [ $S -lt 12 ]; do
    sleep 10; PN=$(put_total); [ -n "$PN" ] || die "empty_offsets_put2 $CELL"
    [ "$PN" = "$PP" ] && break
    PP=$PN; S=$((S+1))
  done
  [ $S -lt 12 ] || die "put_offset_never_stabilized $CELL"
  PUT=$((PP-P0))
  [ "$PUT" -gt 0 ] || die "vacuous_accounting_put_zero $CELL"
  # drain: consumer backlog (Diff Total) must reach 0, bounded
  DRAIN=0; REM=$(backlog_total)
  while [ "${REM:--1}" -ne 0 ] && [ $DRAIN -lt 900 ]; do
    sleep 15; DRAIN=$((DRAIN+15)); REM=$(backlog_total)
  done
  pkill -f "[b]enchmark.Consumer"; sleep 5
  echo "cell=$CELL put=$PUT backlog_final=$REM drain_s=$DRAIN" >> $OUT/accounting.txt
  # failure gates: require the counter fields to EXIST, then all-zero
  fgate() { # $1 file $2 pattern $3 label
    C=$(grep -coE "$2: [0-9]+" "$1" 2>/dev/null) || C=0
    [ "${C:-0}" -ge 1 ] || die "${3}_fields_missing $CELL"
    grep -oE "$2: [0-9]+" "$1" | awk -v L=3 '{if($NF+0>0) exit 1}' || die "${3}_nonzero $CELL"
  }
  fgate $D/producer.log "Send Failed" send_failed
  fgate $D/producer.log "Response Failed" response_failed
  fgate $D/consumer.log "Consume Fail" consume_failed
  [ "${REM:--1}" -eq 0 ] || die "drain_timeout_backlog=$REM $CELL"
  step "CELL_DONE $CELL put=$PUT backlog_final=$REM drain_s=$DRAIN"
}

for size in $SIZES; do
  for scene in normal backlog; do
    # AB then BA — order rotation within each (size, scene) group
    run_cell scalar "$SJAR" $size $scene ab
    run_cell rvv    "$RJAR" $size $scene ab
    run_cell rvv    "$RJAR" $size $scene ba
    run_cell scalar "$SJAR" $size $scene ba
  done
done
cleanup
step MATRIX_DONE
