#!/usr/bin/env bash

# The Android platform library of the Ziggy template's smoke tests. See common.sh for what it implements.
#
# The app runs on an emulator or device, driven from the host with adb. It is the APK the build script makes, holding the library
# for both architectures, started with the ziggy.remoteControl extra.
#
# The device is the one named in ZIGGY_ANDROID_DEVICES (adb serials, space separated) when that is set, else an attached plugged-in
# device when there is one, else any attached emulator, whichever project started it. It is claimed under Ziggy's per-device lock
# for the whole scenario, so two Ziggy runs never install over each other. The lock is released by ziggy_platform_stop.

ANDROID_EXAMPLE_DIR="$ZIGGY_SMOKE_APP_DIR"
ANDROID_SCRIPTS_DIR="$ANDROID_EXAMPLE_DIR/scripts"
ANDROID_APP_ID="dev.ziggy.template"

# Seconds a scenario waits for a free device before giving up.
ANDROID_DEVICE_CLAIM_TIMEOUT="${ZIGGY_DEVICE_CLAIM_TIMEOUT:-1800}"

# JAVA_HOME, ANDROID_HOME and the device helpers the template's Android scripts share.
source "$ANDROID_SCRIPTS_DIR/android-common.sh"

# The claimed device's serial and the file descriptor holding its lock, set by ziggy_android_claim_device.
ANDROID_SERIAL_CLAIMED=""
ANDROID_LOCK_FD=""

#
# Runs adb against the claimed device, with the lock's descriptor closed for the command, so nothing adb starts can keep the
# device locked after the scenario has let it go.
#
ziggy_adb() {
    "$ANDROID_HOME/platform-tools/adb" -s "$ANDROID_SERIAL_CLAIMED" "$@" {ANDROID_LOCK_FD}>&-
}

#
# Prints the devices the run may use, one per line: the named ones, else every attached plugged-in device, else every attached
# emulator.
#
ziggy_android_candidate_devices() {
    local serial
    if [ -n "${ZIGGY_ANDROID_DEVICES:-}" ]; then
        for serial in $ZIGGY_ANDROID_DEVICES; do
            echo "$serial"
        done
        return 0
    fi
    # A plugged-in device is preferred: when one is attached, only plugged-in devices are used, and otherwise every emulator.
    local attached hardware
    attached="$(ziggy_android_attached_devices)"
    hardware="$(printf '%s\n' "$attached" | grep -v '^emulator-' || true)"
    if [ -n "$hardware" ]; then
        printf '%s\n' "$hardware"
        return 0
    fi
    printf '%s\n' "$attached" | grep -v '^$' || true
}

#
# Claims a device under its lock, waiting for one to be free, and sets ANDROID_SERIAL_CLAIMED and ANDROID_LOCK_FD.
# Returns non-zero when there is no candidate or none came free in time.
#
ziggy_android_claim_device() {
    local waited=0
    local candidates serial fd
    while true; do
        candidates="$(ziggy_android_candidate_devices)"
        if [ -z "$candidates" ]; then
            echo "No emulator or device is attached, and none is named in ZIGGY_ANDROID_DEVICES." >&2
            return 1
        fi
        for serial in $candidates; do
            exec {fd}<>"$(ziggy_android_device_lock_path "$serial")"
            if flock -n "$fd"; then
                ANDROID_SERIAL_CLAIMED="$serial"
                ANDROID_LOCK_FD="$fd"
                return 0
            fi
            exec {fd}>&-
        done
        if [ "$waited" -ge "$ANDROID_DEVICE_CLAIM_TIMEOUT" ]; then
            echo "No device came free within ${ANDROID_DEVICE_CLAIM_TIMEOUT}s." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

#
# Hands the claimed device back.
#
ziggy_android_release_device() {
    if [ -n "$ANDROID_LOCK_FD" ]; then
        exec {ANDROID_LOCK_FD}>&-
        ANDROID_LOCK_FD=""
    fi
    ANDROID_SERIAL_CLAIMED=""
}

ziggy_platform_prepare() {
    local run_dir="$1"
    local build="${ZIGGY_SMOKE_BUILD:-}"
    if [ -z "$build" ]; then
        # The build script builds through the one Gradle project and the one synced library directory of this checkout, so
        # another run building at the same time would replace the library between this run's sync and its Gradle build. One run
        # builds at a time per checkout, under a lock on that shared directory. The lock's descriptor is closed for every
        # command, so nothing a build starts (the Gradle daemon) can keep the lock held after this function returns. The APK
        # holds the library for both architectures, so the scenarios run on an emulator and on a connected phone alike.
        ziggy_android_require_commands zig bun jq || return 1
        build="$run_dir/build"
        local build_lock_fd
        mkdir -p "$ZIGGY_ANDROID_PROJECT_DIR/app/build"
        exec {build_lock_fd}<>"$ZIGGY_ANDROID_PROJECT_DIR/app/build/ziggy-smoke-build.lock"
        flock "$build_lock_fd" || return 1
        local result=0
        (cd "$ANDROID_EXAMPLE_DIR" && bun run build:android --arch "x86_64 arm64" --output-dir "$build") {build_lock_fd}>&- || result=1
        exec {build_lock_fd}>&-
        if [ "$result" -ne 0 ]; then
            return 1
        fi
    fi
    if [ ! -f "$build/ziggy-template.apk" ]; then
        echo "The Android build $build has no ziggy-template.apk." >&2
        return 1
    fi
    mkdir -p "$run_dir/app"
    cp "$build/ziggy-template.apk" "$run_dir/app/" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    mkdir -p "$test_dir"
    if [ "${2:-}" = "keep-data" ]; then
        # A restart: the same device, the same install and the data the last run left.
        ziggy_adb shell am force-stop "$ANDROID_APP_ID"
    else
        ziggy_android_claim_device || return 1
        echo "$ANDROID_SERIAL_CLAIMED" > "$test_dir/device.txt"

        local apk="$ZIGGY_SMOKE_RUN_DIR/app/ziggy-template.apk"

        # A fresh install with fresh data, so nothing of an earlier scenario is left in the app's files directory.
        ziggy_adb install -r -t "$apk" > "$test_dir/install.log" 2>&1 || {
            cat "$test_dir/install.log" >&2
            return 1
        }
        ziggy_adb shell am force-stop "$ANDROID_APP_ID"
        ziggy_adb shell pm clear "$ANDROID_APP_ID" > /dev/null || return 1
    fi

    # The app connects to the remote control server at 127.0.0.1 on the device, and adb reverse carries that port to the same
    # port on the host, where the server listens. The device is claimed for the scenario, so no other run uses the port there.
    if [ -n "$ZIGGY_REMOTE_CONTROL" ]; then
        local app_port="${ZIGGY_REMOTE_CONTROL##*:}"
        ziggy_adb reverse "tcp:$app_port" "tcp:$app_port" > /dev/null || return 1
        echo "$app_port" > "$test_dir/reverse-port.txt"
    fi

    ziggy_adb logcat -c
    ziggy_adb shell am start -W -n "$ANDROID_APP_ID/.MainActivity" \
        ${ZIGGY_REMOTE_CONTROL:+--es ziggy.remoteControl "$ZIGGY_REMOTE_CONTROL"} > "$test_dir/am-start.log" 2>&1 || {
        cat "$test_dir/am-start.log" >&2
        return 1
    }
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -z "$ANDROID_SERIAL_CLAIMED" ]; then
        return 0
    fi
    if [ -s "$test_dir/reverse-port.txt" ]; then
        ziggy_adb reverse --remove "tcp:$(cat "$test_dir/reverse-port.txt")" || true
        : > "$test_dir/reverse-port.txt"
    fi
    ziggy_adb shell am force-stop "$ANDROID_APP_ID" || true
    if [ "${2:-}" = "keep-device" ]; then
        return 0
    fi
    ziggy_android_release_device
}

ziggy_platform_data_dir() {
    local test_dir="$1"
    local data_dir="$test_dir/data"
    mkdir -p "$data_dir"
    # The app's private files directory is read through run-as, which can only stream it, so it is copied out as a tar.
    ziggy_adb exec-out run-as "$ANDROID_APP_ID" tar -cf - -C files . | tar -xf - -C "$data_dir" || return 1
    printf '%s\n' "$data_dir"
}

#
# Whether the app is running, which on Android means its activity exists. Quitting finishes the activity, whose onDestroy
# destroys the backend and so stops every thread and task the backend started. Android then keeps the emptied process cached for
# a later launch, so a process that is still listed is not a sign the app is still running.
#
ziggy_platform_is_running() {
    ziggy_adb shell dumpsys activity activities | grep -q "$ANDROID_APP_ID/.MainActivity"
}

ziggy_platform_wait_exit() {
    local seconds="$2"
    local waited=0
    while ziggy_platform_is_running; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

#
# Sends the app to the background, as the Home button does.
#
ziggy_platform_leave_app() {
    ziggy_adb shell input keyevent KEYCODE_HOME
}

#
# Whether the app's process is running, which is what a foreground service keeps going when the app is not in the foreground.
#
ziggy_platform_process_alive() {
    [ -n "$(ziggy_adb shell pidof "$ANDROID_APP_ID" | tr -d '\r')" ]
}

#
# Whether the app's foreground service is running.
#
ziggy_platform_keep_alive_service_running() {
    ziggy_adb shell dumpsys activity services "$ANDROID_APP_ID" | grep -q "ZiggyKeepAliveService"
}
