#!/usr/bin/env bash

# Runs Android smoke scenarios 1 to 6 on the emulator the workflow started, while recording every change of the emulator's adb
# state with a timestamp, then saves the adb server's log and the device's logs to $EVIDENCE_DIR.

set -u

ADB="$ANDROID_HOME/platform-tools/adb"
SERIAL=emulator-5554
mkdir -p "$EVIDENCE_DIR"

# Records the emulator's adb state every 0.2 s, one line per change.
poll_state() {
    local last="" state
    while true; do
        state="$("$ADB" devices | grep "^$SERIAL" | cut -f2)"
        state="${state:-absent}"
        if [ "$state" != "$last" ]; then
            echo "$(date -u +%H:%M:%S.%N) $state" >> "$EVIDENCE_DIR/adb-state.log"
            last="$state"
        fi
        sleep 0.2
    done
}

echo "$(date -u +%H:%M:%S.%N) guest uptime: $("$ADB" -s $SERIAL shell cat /proc/uptime)" | tee -a "$EVIDENCE_DIR/uptime.log"
poll_state &
poller=$!

result=0
for scenario in 1-reply 2-short-task 3-long-task-with-children 4-cancel-long-task 5-cancel-one-of-several-sources 6-edges; do
    bash ./smoke-tests/run.sh android "$scenario" || result=1
done

kill "$poller"
echo "$(date -u +%H:%M:%S.%N) guest uptime: $("$ADB" -s $SERIAL shell cat /proc/uptime)" | tee -a "$EVIDENCE_DIR/uptime.log"
echo "=== adb state changes"
cat "$EVIDENCE_DIR/adb-state.log"
cp /tmp/adb.*.log "$EVIDENCE_DIR/" 2>/dev/null
echo "=== adb server log lines naming the emulator"
grep -h -i "$SERIAL\|offline\|transport" /tmp/adb.*.log | tail -60
"$ADB" -s $SERIAL logcat -d -b all -v threadtime > "$EVIDENCE_DIR/logcat-all.txt" 2>&1
"$ADB" -s $SERIAL root
sleep 3
"$ADB" -s $SERIAL wait-for-device
"$ADB" -s $SERIAL shell dmesg > "$EVIDENCE_DIR/dmesg.txt" 2>&1
echo "=== logcat lines naming adbd"
grep -i "adbd" "$EVIDENCE_DIR/logcat-all.txt" | tail -60
echo "=== result $result"
exit "$result"
