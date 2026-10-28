#!/usr/bin/env bash

# The iOS platform library of the Ziggy template's smoke tests. See common.sh for what it implements.
#
# When an iPhone or iPad is connected the scenarios run on it, as run-ios.sh runs the app there, and ios-device.sh, sourced
# below, replaces everything here. Otherwise the app runs on an iOS simulator that already exists: ZIGGY_IOS_SIMULATOR names
# one, otherwise a running one or the first available iPhone is used (see apple_pick_simulator). Nothing is created or
# deleted. A simulator process shares the host's network, so the app reaches the remote control server at 127.0.0.1 and the
# script reaches the server there too. The app's process is not a child of this shell, so it is recorded by its
# process id and stopped with simctl.

IOS_SCRIPTS_DIR="$ZIGGY_SMOKE_APP_DIR/scripts"
source "$IOS_SCRIPTS_DIR/lib/apple-common.sh"

if [ -n "$(apple_connected_device)" ]; then
    source "$ZIGGY_SMOKE_DIR/lib/ios-device.sh"
    return 0
fi

# The app's bundle identifier.
IOS_BUNDLE_ID="dev.ziggy.template"

# The files the simulator's identifier and the app's process id are recorded in, per scenario.
IOS_UDID_FILE_NAME="simulator.udid"
IOS_PID_FILE_NAME="app.pid"

ziggy_platform_prepare() {
    local run_dir="$1"
    local build="${ZIGGY_SMOKE_BUILD:-}"
    if [ -z "$build" ]; then
        build="$run_dir/build"
        bash "$IOS_SCRIPTS_DIR/build-ios.sh" --sdk simulator --configuration Release --native-dir "$build/native" --build-dir "$build/xcode" || return 1
    fi
    local built_app="$build/xcode/Build/Products/Release-iphonesimulator/ZiggyTemplate.app"
    if [ ! -d "$built_app" ]; then
        echo "The iOS simulator build $build has no xcode/Build/Products/Release-iphonesimulator/ZiggyTemplate.app." >&2
        return 1
    fi
    mkdir -p "$run_dir/app"
    cp -R "$built_app" "$run_dir/app/" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local app="$ZIGGY_SMOKE_RUN_DIR/app/ZiggyTemplate.app"
    local udid
    udid="$(apple_pick_simulator)" || return 1
    echo "$udid" > "$test_dir/$IOS_UDID_FILE_NAME"
    # Installing replaces the app the last scenario left. Terminating first fails
    # when the app is not running, which is the usual case and not an error. A restart does not install again, which keeps the
    # app's data.
    xcrun simctl terminate "$udid" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
    if [ "${2:-}" != "keep-data" ]; then
        xcrun simctl install "$udid" "$app" || return 1
    fi
    local launched
    launched="$(xcrun simctl launch "$udid" "$IOS_BUNDLE_ID" ${ZIGGY_REMOTE_CONTROL:+--remote-control "$ZIGGY_REMOTE_CONTROL"})" || return 1
    local pid="${launched##*: }"
    echo "$pid" > "$test_dir/$IOS_PID_FILE_NAME"
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$IOS_UDID_FILE_NAME" ]; then
        # Fails when the app has already exited, which is a normal end for a scenario that quit it.
        xcrun simctl terminate "$(cat "$test_dir/$IOS_UDID_FILE_NAME")" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
    fi
}

ziggy_platform_data_dir() {
    local test_dir="$1"
    local container
    container="$(xcrun simctl get_app_container "$(cat "$test_dir/$IOS_UDID_FILE_NAME")" "$IOS_BUNDLE_ID" data)" || return 1
    printf '%s\n' "$container/Library/Application Support/$IOS_BUNDLE_ID"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pid
    pid="$(cat "$test_dir/$IOS_PID_FILE_NAME")"
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

ziggy_platform_is_running() {
    local test_dir="$1"
    kill -0 "$(cat "$test_dir/$IOS_PID_FILE_NAME")" 2>/dev/null
}

#
# Sends the app to the background by opening another app over it.
#
ziggy_platform_leave_app() {
    xcrun simctl launch "$(cat "$1/$IOS_UDID_FILE_NAME")" com.apple.Preferences > /dev/null
}

ziggy_platform_process_alive() {
    kill -0 "$(cat "$1/$IOS_PID_FILE_NAME")" 2>/dev/null
}
