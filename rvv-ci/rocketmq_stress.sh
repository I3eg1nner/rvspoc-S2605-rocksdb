#!/bin/sh
# RocketMQ 5.5.0 60-min stress on riscv64 with our rocksdbjni (S2605 gate).
# Run ON THE BOARD from /root. Success = 60 min, zero OOM / corruption /
# loss signals; all resource samples and TPS lines land in /root/rmq-stress/.
# Lesson encoded: timeout(1) does NOT kill java children -> cleanup pkills
# the benchmark classes by name, and a trap cleans up on any exit.
set -u
DUR="${1:-3600}"                       # seconds (default 60 min)
RMQ=/root/rocketmq-all-5.5.0-bin-release
OUT=/root/rmq-stress
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-riscv64
export NAMESRV_ADDR=127.0.0.1:9876
mkdir -p $OUT

cleanup() {
  pkill -f "[b]enchmark.Producer" 2>/dev/null
  pkill -f "[b]enchmark.Consumer" 2>/dev/null
}
trap cleanup EXIT INT TERM

# quiet-board gate
for bad in "[d]b_bench" "[c]c1plus" "[m]ake -j"; do
  pgrep -f "$bad" >/dev/null && { echo "BOARD_BUSY $bad"; exit 3; }
done

echo "== start services =="
cd $RMQ
nohup sh bin/mqnamesrv > $OUT/namesrv.log 2>&1 < /dev/null &
sleep 20
grep -q "boot success" $OUT/namesrv.log || { echo NAMESRV_FAIL; exit 1; }
nohup sh bin/mqbroker -n 127.0.0.1:9876 > $OUT/broker.log 2>&1 < /dev/null &
sleep 40
grep -q "boot success" $OUT/broker.log || { echo BROKER_FAIL; exit 1; }
BROKER_PID=$(pgrep -f "[B]rokerStartup")
echo "broker pid $BROKER_PID"

echo "== start load =="
cd $RMQ/benchmark
nohup sh producer.sh -n 127.0.0.1:9876 -s 1024 -w 8 > $OUT/producer.log 2>&1 < /dev/null &
nohup sh consumer.sh -n 127.0.0.1:9876 > $OUT/consumer.log 2>&1 < /dev/null &
sleep 10
pgrep -f "[b]enchmark.Producer" >/dev/null || { echo PRODUCER_FAIL; exit 1; }
pgrep -f "[b]enchmark.Consumer" >/dev/null || { echo CONSUMER_FAIL; exit 1; }

echo "== sampling for $DUR s =="
END=$(( $(date +%s) + DUR ))
: > $OUT/samples.csv
echo "epoch,broker_rss_kb,free_mb,swap_used_mb,disk_avail_gb,load1" >> $OUT/samples.csv
while [ "$(date +%s)" -lt "$END" ]; do
  RSS=$(awk '/VmRSS/{print $2}' /proc/$BROKER_PID/status 2>/dev/null || echo DEAD)
  [ "$RSS" = "DEAD" ] && { echo "BROKER_DIED at $(date +%s)" | tee -a $OUT/samples.csv; exit 1; }
  FREE=$(free -m | awk 'NR==2{print $7}')
  SW=$(free -m | awk 'NR==3{print $3}')
  DA=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  L1=$(cut -d" " -f1 /proc/loadavg)
  echo "$(date +%s),$RSS,$FREE,$SW,$DA,$L1" >> $OUT/samples.csv
  sleep 60
done

echo "== stop load, account =="
cleanup
sleep 5
echo "--- producer tail ---"; tail -3 $OUT/producer.log
echo "--- consumer tail ---"; tail -3 $OUT/consumer.log
echo "--- failure counters (must all be 0) ---"
grep -o "Send Failed: [0-9]*" $OUT/producer.log | sort -u | tail -3
grep -o "Response Failed: [0-9]*" $OUT/producer.log | sort -u | tail -3
grep -oE "Consume Fail: [0-9]*" $OUT/consumer.log | sort -u | tail -3
echo "--- broker health ---"
sh $RMQ/bin/mqadmin brokerStatus -n 127.0.0.1:9876 -b 127.0.0.1:10911 2>/dev/null | grep -E "putTps|getTransferredTps|commitLogDirCapacity" | head -5
grep -ciE "exception|error" $OUT/broker.log || true
echo "== shutdown =="
sh $RMQ/bin/mqshutdown broker >/dev/null 2>&1
sh $RMQ/bin/mqshutdown namesrv >/dev/null 2>&1
sleep 5
pgrep -f "[B]rokerStartup" >/dev/null && echo BROKER_STILL_UP || echo CLEAN_SHUTDOWN
echo STRESS_DONE
