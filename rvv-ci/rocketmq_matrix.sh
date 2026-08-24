#!/bin/sh
# RocketMQ dual-arm evaluation matrix (external-review item 3):
#   arms   : scalar-jar (PORTABLE rocksdbjni) vs rvv-jar (delivery tier)
#   sizes  : 1 KiB, 16 KiB, 128 KiB messages
#   scenes : normal consume; backlog (consumer started late + throttled)
# Per cell: fresh store, 600 s load, strict accounting via brokerStatus
# cumulative counters (msgPutTotalTodayNow/msgGetTotalTodayNow), full
# producer/consumer logs preserved under /root/rmq-matrix/<cell>/.
# Usage: rocketmq_matrix.sh <scalar_jar> <rvv_jar> [cell_secs=600]
set -u
SJAR=$1; RJAR=$2; DUR=${3:-600}
RMQ=/root/rocketmq-all-5.5.0-bin-release
OUT=/root/rmq-matrix
ST=$OUT/matrix.status
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-riscv64
export NAMESRV_ADDR=127.0.0.1:9876
mkdir -p $OUT; : > $ST
step() { echo "$(date +%H:%M:%S) $1" >> $ST; }

cleanup() {
  pkill -f "[b]enchmark.Producer" 2>/dev/null; pkill -f "[b]enchmark.Consumer" 2>/dev/null
  sh $RMQ/bin/mqshutdown broker >/dev/null 2>&1; sh $RMQ/bin/mqshutdown namesrv >/dev/null 2>&1
  sleep 8; pkill -9 -f "[B]rokerStartup" 2>/dev/null; pkill -9 -f "[N]amesrvStartup" 2>/dev/null
}
trap cleanup EXIT INT TERM

put_total() { sh $RMQ/bin/mqadmin brokerStatus -n 127.0.0.1:9876 -b 127.0.0.1:10911 2>/dev/null | awk '/msgPutTotalTodayNow/{print $3}'; }
get_total() { sh $RMQ/bin/mqadmin brokerStatus -n 127.0.0.1:9876 -b 127.0.0.1:10911 2>/dev/null | awk '/msgGetTotalTodayNow/{print $3}'; }

run_cell() { # $1 arm-name $2 jar $3 size $4 scene(normal|backlog)
  CELL="$1-s$3-$4"; D=$OUT/$CELL; mkdir -p $D
  step "CELL_START $CELL"
  cleanup; rm -rf /root/store /root/rmq-matrix-store; sleep 3
  rm -f $RMQ/lib/rocksdbjni-*.jar $RMQ/lib/rocketmq-rocksdb-*.jar
  cp "$2" $RMQ/lib/
  cd $RMQ
  nohup sh bin/mqnamesrv > $D/namesrv.log 2>&1 < /dev/null &
  sleep 20; grep -q "boot success" $D/namesrv.log || { step "NAMESRV_FAIL $CELL"; return 1; }
  nohup sh bin/mqbroker -n 127.0.0.1:9876 > $D/broker.log 2>&1 < /dev/null &
  sleep 40; grep -q "boot success" $D/broker.log || { step "BROKER_FAIL $CELL"; return 1; }
  P0=$(put_total); G0=$(get_total)
  cd $RMQ/benchmark
  nohup sh producer.sh -n 127.0.0.1:9876 -s "$3" -w 8 > $D/producer.log 2>&1 < /dev/null &
  if [ "$4" = "normal" ]; then
    nohup sh consumer.sh -n 127.0.0.1:9876 > $D/consumer.log 2>&1 < /dev/null &
  else
    # backlog: consumer joins at half time -> forced catch-up on deep queue
    ( sleep $((DUR / 2)); cd $RMQ/benchmark && nohup sh consumer.sh -n 127.0.0.1:9876 > $D/consumer.log 2>&1 < /dev/null & ) &
  fi
  sleep "$DUR"
  pkill -f "[b]enchmark.Producer"
  # let the consumer drain the backlog (bounded)
  [ "$4" = "backlog" ] && sleep 120
  pkill -f "[b]enchmark.Consumer"; sleep 5
  P1=$(put_total); G1=$(get_total)
  BR=$(awk '/VmRSS/{print $2}' /proc/$(pgrep -f "[j]ava.*BrokerStartup" | head -1)/status 2>/dev/null)
  echo "cell=$CELL put=$((P1-P0)) get=$((G1-G0)) broker_rss_kb=$BR" >> $OUT/accounting.txt
  grep -c "Send Failed: 0" $D/producer.log >> $D/ok_windows.txt 2>/dev/null || true
  grep -oE "Send Failed: [0-9]+" $D/producer.log | sort -u > $D/send_failed_values.txt
  grep -oE "Consume Fail: [0-9]+" $D/consumer.log 2>/dev/null | sort -u > $D/consume_fail_values.txt
  step "CELL_DONE $CELL"
}

for size in 1024 16384 131072; do
  run_cell scalar "$SJAR" $size normal
  run_cell rvv    "$RJAR" $size normal
done
run_cell scalar "$SJAR" 1024 backlog
run_cell rvv    "$RJAR" 1024 backlog
cleanup
step MATRIX_DONE
