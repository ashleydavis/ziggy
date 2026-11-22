#!/usr/bin/env bash

# Runs Android smoke scenario 5 eight times in a row on the emulator the workflow started, while recording every change of the emulator's adb
# state with a timestamp, then saves the adb server's log and the device's logs to $EVIDENCE_DIR.

set -u

ADB="$ANDROID_HOME/platform-tools/adb"
SERIAL=emulator-5554
mkdir -p "$EVIDENCE_DIR"

# Records the emulator's adb state and the host's TCP connections on the emulator's adb port 5555 every 0.2 s, one entry per
# change.
poll_state() {
    local last="" state last_sockets="" sockets
    while true; do
        state="$("$ADB" devices | grep "^$SERIAL" | cut -f2)"
        state="${state:-absent}"
        if [ "$state" != "$last" ]; then
            echo "$(date -u +%H:%M:%S.%N) $state" >> "$EVIDENCE_DIR/adb-state.log"
            last="$state"
        fi
        sockets="$(sudo ss -tanp '( sport = :5555 or dport = :5555 )' | sed 's/  */ /g')"
        if [ "$sockets" != "$last_sockets" ]; then
            { echo "--- $(date -u +%H:%M:%S.%N)"; echo "$sockets"; } >> "$EVIDENCE_DIR/adb-sockets.log"
            last_sockets="$sockets"
        fi
        sleep 0.2
    done
}

# The adb server again, with its full trace in its log.
"$ADB" kill-server
ADB_TRACE=all "$ADB" start-server
"$ADB" -s $SERIAL wait-for-device

echo "$(date -u +%H:%M:%S.%N) guest uptime: $("$ADB" -s $SERIAL shell cat /proc/uptime)" | tee -a "$EVIDENCE_DIR/uptime.log"
poll_state &
poller=$!

result=0
if [ -n "${IDLE_SECONDS:-}" ]; then
    # No app and no scenario: only the poller talks to the emulator.
    echo "$(date -u +%H:%M:%S.%N) idle for $IDLE_SECONDS s"
    sleep "$IDLE_SECONDS"
    if grep -q -v " device$" "$EVIDENCE_DIR/adb-state.log"; then
        result=1
    fi
else
    for attempt in 1 2 3 4 5 6 7 8; do
        echo "$(date -u +%H:%M:%S.%N) scenario 5, attempt $attempt"
        bash ./smoke-tests/run.sh android 5-cancel-one-of-several-sources || result=1
    done
fi

kill "$poller"
echo "$(date -u +%H:%M:%S.%N) guest uptime: $("$ADB" -s $SERIAL shell cat /proc/uptime)" | tee -a "$EVIDENCE_DIR/uptime.log"
echo "=== adb state changes"
cat "$EVIDENCE_DIR/adb-state.log"
cp /tmp/adb.*.log "$EVIDENCE_DIR/" 2>/dev/null
cp -r /tmp/ziggy-tests "$EVIDENCE_DIR/" 2>/dev/null
echo "=== adb server log lines naming the emulator"
grep -h -i "terminated\|offline\|read failed\|errno\|kicked\|closing\|error" /tmp/adb.*.log | tail -60
echo "=== socket changes on port 5555"
cat "$EVIDENCE_DIR/adb-sockets.log"
"$ADB" -s $SERIAL logcat -d -b all -v threadtime > "$EVIDENCE_DIR/logcat-all.txt" 2>&1
"$ADB" -s $SERIAL root
sleep 3
"$ADB" -s $SERIAL wait-for-device
"$ADB" -s $SERIAL shell dmesg > "$EVIDENCE_DIR/dmesg.txt" 2>&1
echo "=== logcat lines naming adbd"
grep -i "adbd" "$EVIDENCE_DIR/logcat-all.txt" | tail -60
echo "=== result $result"
exit "$result"
