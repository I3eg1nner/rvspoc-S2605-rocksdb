#!/bin/sh
# RocketMQ dual-arm evaluation matrix, v2 (review-hardened):
#   full product: {scalar,rvv} x {1K,16K,128K} x {normal,backlog}
#   x {AB,BA} order rotation  => 24 runs.
#   Per run: fresh store, DUR seconds of load, then producer stops and
#   the consumer DRAINS until get_delta >= put_delta (bounded, remaining
#   queue recorded). Strict accounting via brokerStatus cumulative
#   counters. ANY failure (service boot, empty counters, nonzero
#   Send/Response/Consume failures, drain timeout) aborts the matrix.
#   Identity chain: jar sha256 + broker JVM cmdline recorded per run.
# Usage: rocketmq_matrix.sh <scalar_jar> <rvv_jar> [cell_secs=300]
set -u
SJAR=$1; RJAR=$2; DUR=${3:-300}
RMQ=/root/rocketmq-all-5.5.0-bin-release
OUT=/root/rmq-matrix
ST=$OUT/matrix.status
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-riscv64
export NAMESRV_ADDR=127.0.0.1:9876
mkdir -p $OUT; : > $ST; : > $OUT/accounting.txt
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }
die() { step "ABORT $1"; cleanup; exit 1; }

cleanup() {
  pkill -f "[b]enchmark.Producer" 2>/dev/null; pkill -f "[b]enchmark.Consumer" 2>/dev/null
  sh $RMQ/bin/mqshutdown broker >/dev/null 2>&1; sh $RMQ/bin/mqshutdown namesrv >/dev/null 2>&1
  sleep 8; pkill -9 -f "[B]rokerStartup" 2>/dev/null; pkill -9 -f "[N]amesrvStartup" 2>/dev/null
}
trap cleanup EXIT INT TERM

sha256sum "$SJAR" "$RJAR" >> $OUT/jar-identity.txt

bstat() { sh $RMQ/bin/mqadmin brokerStatus -n 127.0.0.1:9876 -b 127.0.0.1:10911 2>/dev/null; }
put_total() { bstat | awk '/msgPutTotalTodayNow/{print $3}'; }
get_total() { bstat | awk '/msgGetTotalTodayNow/{print $3}'; }

run_cell() { # $1 arm $2 jar $3 size $4 scene $5 order-tag
  CELL="$1-s$3-$4-$5"; D=$OUT/$CELL; mkdir -p $D
  step "CELL_START $CELL"
  cleanup; rm -rf /root/store; sleep 3
  rm -f $RMQ/lib/rocksdbjni-*.jar $RMQ/lib/rocketmq-rocksdb-*.jar
  cp "$2" $RMQ/lib/ || die "jar_copy $CELL"
  cd $RMQ
  nohup sh bin/mqnamesrv > $D/namesrv.log 2>&1 < /dev/null &
  sleep 20; grep -q "boot success" $D/namesrv.log || die "namesrv_boot $CELL"
  nohup sh bin/mqbroker -n 127.0.0.1:9876 > $D/broker.log 2>&1 < /dev/null &
  sleep 40; grep -q "boot success" $D/broker.log || die "broker_boot $CELL"
  cat /proc/$(pgrep -f "[j]ava.*BrokerStartup" | head -1)/cmdline | tr '\0' ' ' > $D/broker-cmdline.txt
  P0=$(put_total); G0=$(get_total)
  [ -n "$P0" ] && [ -n "$G0" ] || die "empty_counters_pre $CELL"
  cd $RMQ/benchmark
  nohup sh producer.sh -n 127.0.0.1:9876 -s "$3" -w 8 > $D/producer.log 2>&1 < /dev/null &
  if [ "$4" = "normal" ]; then
    nohup sh consumer.sh -n 127.0.0.1:9876 > $D/consumer.log 2>&1 < /dev/null &
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
  PP=$(put_total); [ -n "$PP" ] || die "empty_counters_put $CELL"
  S=0
  while [ $S -lt 12 ]; do
    sleep 10; PN=$(put_total); [ -n "$PN" ] || die "empty_counters_put2 $CELL"
    [ "$PN" = "$PP" ] && break
    PP=$PN; S=$((S+1))
  done
  [ $S -lt 12 ] || die "put_counter_never_stabilized $CELL"
  # drain: consumer catches up to the locked target (bounded)
  DRAIN=0; GG=$(get_total)
  while [ "${GG:-0}" -lt "$PP" ] && [ $DRAIN -lt 900 ]; do
    sleep 15; DRAIN=$((DRAIN+15)); GG=$(get_total)
  done
  pkill -f "[b]enchmark.Consumer"; sleep 5
  P1=$(put_total); G1=$(get_total)
  PUT=$((P1-P0)); GET=$((G1-G0)); REM=$((P1-G1))
  echo "cell=$CELL put=$PUT get=$GET remaining=$REM drain_s=$DRAIN" >> $OUT/accounting.txt
  # failure gates: require the counter fields to EXIST, then all-zero
  fgate() { # $1 file $2 pattern $3 label
    C=$(grep -coE "$2: [0-9]+" "$1" 2>/dev/null) || C=0
    [ "${C:-0}" -ge 1 ] || die "${3}_fields_missing $CELL"
    grep -oE "$2: [0-9]+" "$1" | awk -v L=3 '{if($NF+0>0) exit 1}' || die "${3}_nonzero $CELL"
  }
  fgate $D/producer.log "Send Failed" send_failed
  fgate $D/producer.log "Response Failed" response_failed
  fgate $D/consumer.log "Consume Fail" consume_failed
  [ "$REM" -le 0 ] || die "drain_timeout_remaining=$REM $CELL"
  step "CELL_DONE $CELL put=$PUT get=$GET rem=$REM"
}

for size in 1024 16384 131072; do
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
