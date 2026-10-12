#!/usr/bin/env bash

# Builds the example, installs it on an emulator or device and starts it. See run-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

adb_command="$ANDROID_HOME/platform-tools/adb"

serial="${ZIGGY_ANDROID_TARGET:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            serial="$2"
            shift 2
            ;;
        *)
            echo "Usage: run-android.sh [--target <adb serial>]" >&2
            exit 2
            ;;
    esac
done

# Without a named target, the first attached emulator or device that no Ziggy smoke test is using is taken. It is taken under the
# device lock the smoke tests take, so a run never installs over an app a test is using, and the lock is held until this script ends.
if [ -z "$serial" ]; then
    for candidate in $(ziggy_android_attached_devices); do
        exec {lock_fd}<>"$(ziggy_android_device_lock_path "$candidate")"
        if flock -n "$lock_fd"; then
            serial="$candidate"
            break
        fi
        exec {lock_fd}>&-
    done
fi
if [ -z "$serial" ]; then
    echo "ERROR: there is no attached emulator or device that a Ziggy smoke test is not using. Pass --target <serial> to name one." >&2
    exit 1
fi

abi="$("$adb_command" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in
    x86_64)
        arch="x86_64"
        ;;
    arm64-v8a)
        arch="arm64"
        ;;
    *)
        echo "ERROR: $serial has the ABI $abi, which the example does not build for." >&2
        exit 1
        ;;
esac

bash "$ZIGGY_ANDROID_SCRIPTS_DIR/sync-android.sh" --arch "$arch" --optimize Debug
ziggy_android_gradle assembleDebug "-PziggyVersionName=$(ziggy_android_version)"
"$adb_command" -s "$serial" install -r "$ZIGGY_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
"$adb_command" -s "$serial" shell am start -n "$ZIGGY_ANDROID_APP_ID/.MainActivity"
