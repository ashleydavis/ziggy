#!/usr/bin/env bash

# The MacOS platform library of the Ziggy test app's smoke tests. See common.sh for what it implements.
#
# The app is the built ZiggyTestApp.app's executable, started directly so its process group is known. Each scenario gets a
# home directory of its own (HOME and CFFIXED_USER_HOME), so the app's Application Support directory is isolated. The app
# opens a real window, so the run needs a logged-in graphical session.

# The file the app's process group is recorded in, per scenario.
MACOS_PGID_FILE_NAME="app.pgid"

ziggy_platform_prepare() {
    local run_dir="$1"
    local build="${ZIGGY_SMOKE_BUILD:-}"
    if [ -z "$build" ]; then
        build="$run_dir/build"
        (cd "$ZIGGY_SMOKE_APP_DIR" && bun run build:macos --configuration Release --native-dir "$build/native" --build-dir "$build/xcode") || return 1
    fi
    local built_app="$build/xcode/Build/Products/Release/ZiggyTestApp.app"
    if [ ! -d "$built_app" ]; then
        echo "The macOS build $build has no xcode/Build/Products/Release/ZiggyTestApp.app." >&2
        return 1
    fi
    mkdir -p "$run_dir/app"
    ditto "$built_app" "$run_dir/app/ZiggyTestApp.app" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local app="$ZIGGY_SMOKE_RUN_DIR/app/ZiggyTestApp.app/Contents/MacOS/ZiggyTestApp"
    local log="$test_dir/app.log"
    mkdir -p "$test_dir/home"
    local pgid
    read -r _ pgid < <(launch_in_process_group "$log" env \
        HOME="$test_dir/home" \
        CFFIXED_USER_HOME="$test_dir/home" \
        ZIGGY_TEST_APP_CONFIG_DIR="$test_dir/config" \
        ZIGGY_TEST_APP_STATE_DIR="$test_dir/state" \
        "$app" ${ZIGGY_REMOTE_CONTROL:+--remote-control "$ZIGGY_REMOTE_CONTROL"} ${ZIGGY_THEME:+--theme "$ZIGGY_THEME"}) || return 1
    echo "$pgid" > "$test_dir/$MACOS_PGID_FILE_NAME"
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$MACOS_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$MACOS_PGID_FILE_NAME")" || true
    fi
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/home/Library/Application Support/dev.ziggy.testapp"
}

ziggy_platform_config_path() {
    printf '%s\n' "$1/config/config.toml"
}

ziggy_platform_state_path() {
    printf '%s\n' "$1/state/state.json"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pgid
    pgid="$(cat "$test_dir/$MACOS_PGID_FILE_NAME")"
    local waited=0
    while process_group_alive "$pgid"; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

ziggy_platform_is_running() {
    local test_dir="$1"
    process_group_alive "$(cat "$test_dir/$MACOS_PGID_FILE_NAME")"
}

#
# Succeeds when the developer tools are showing. The web inspector docks inside the window, so the frontend's area is smaller
# than it was. Usage: ziggy_platform_devtools_visible <test_dir> <the frontend's area before they opened>
#
ziggy_platform_devtools_visible() {
    [ "$(viewport_size)" != "$2" ]
}

ziggy_platform_leave_app() {
    choose_menu_item close-window
}

ziggy_platform_process_alive() {
    ziggy_platform_is_running "$1"
}

#
# Prints the stack of every thread of the app, for a scenario to show where an app that did not end is waiting. The MacOS smoke
# job's 25-close-with-dialog-open failed twice with the app still running after it was told to quit, and an empty log. `sample`
# ships with macOS and reads the stacks of a running process.
#
ziggy_platform_print_stacks() {
    sample "$(cat "$1/$MACOS_PGID_FILE_NAME")" 2 -file "$1/app-stacks.txt" > /dev/null 2>&1
    head -n 400 "$1/app-stacks.txt"
}

#
# Succeeds when the desktop's appearance can be set with System Events, which the appearance-only scenarios need.
#
ziggy_platform_changes_appearance() {
    command -v osascript > /dev/null 2>&1
}

#
# Sets the desktop's appearance and keeps the one to put back in the scenario's directory.
# Usage: ziggy_platform_set_system_theme <test_dir> <light|dark>
#
ziggy_platform_set_system_theme() {
    local test_dir="$1"
    local theme="$2"
    if [ ! -f "$test_dir/system-appearance.txt" ]; then
        local current
        current="$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)"
        printf '%s\n' "${current:-light}" > "$test_dir/system-appearance.txt"
    fi
    if [ "$theme" = "dark" ]; then
        osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' > /dev/null || return 1
    else
        osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' > /dev/null || return 1
    fi
}

#
# Puts the desktop's appearance back. Usage: ziggy_platform_restore_system_theme <test_dir>
#
ziggy_platform_restore_system_theme() {
    local test_dir="$1"
    local value
    value="$(cat "$test_dir/system-appearance.txt")"
    if [ "$value" = "Dark" ]; then
        if ! osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' > /dev/null; then
            echo "could not set the desktop's appearance back to dark" >&2
            return 1
        fi
    else
        if ! osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' > /dev/null; then
            echo "could not set the desktop's appearance back to light" >&2
            return 1
        fi
    fi
}
