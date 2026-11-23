#!/usr/bin/env bash

# The proof run: Android smoke scenario 5 eight times in a row on the emulator the workflow started, with the adb server traced,
# against the build the workflow made (with or without small-get-text.patch). Fails when the emulator's adb connection dropped at
# least once. Saves the adb server's log to $EVIDENCE_DIR.

set -u

ADB="$ANDROID_HOME/platform-tools/adb"
SERIAL=emulator-5554
mkdir -p "$EVIDENCE_DIR"

"$ADB" kill-server
ADB_TRACE=all "$ADB" start-server
"$ADB" -s $SERIAL wait-for-device

for attempt in 1 2 3 4 5 6 7 8; do
    echo "$(date -u +%H:%M:%S.%N) scenario 5, attempt $attempt"
    bash ./smoke-tests/run.sh android 5-cancel-one-of-several-sources
done

cp /tmp/adb.*.log "$EVIDENCE_DIR/"
log="$(ls /tmp/adb.*.log)"
# Lines at debug level come only from the traced server started above.
drops="$(grep -c "transport.cpp:356 emulator-5554: read failed" "$log")"
largest="$(grep -oE "readx: fd=[0-9]+ wanted=[0-9]+$" "$log" | sed 's/.*wanted=//' | sort -n | tail -1)"
over_60000="$(grep -cE "readx: fd=[0-9]+ wanted=([6-9][0-9]{4}|[0-9]{6,})$" "$log")"
echo "=== packets from the emulator: largest $largest bytes, $over_60000 of 60000 bytes or more"
echo "=== payload in flight at each drop"
grep -B3 "transport.cpp:356 emulator-5554: read failed" "$log" | grep -oE "wanted=[0-9]+$"
echo "=== drops of the emulator's adb connection: $drops"
[ "$drops" -eq 0 ]
