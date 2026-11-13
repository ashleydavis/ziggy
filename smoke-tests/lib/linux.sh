#!/usr/bin/env bash

# The Linux platform library of the Ziggy test app's smoke tests. See common.sh for what it implements.
#
# The app runs on a virtual display of its own, so a run shows no window and two runs never share a display.

LINUX_SHELL_DIR="$ZIGGY_SMOKE_APP_DIR/native/linux"
LINUX_EXAMPLE_DIR="$ZIGGY_SMOKE_APP_DIR"

# The file the app's process group is recorded in, per scenario.
LINUX_PGID_FILE_NAME="app.pgid"

ziggy_platform_prepare() {
    local run_dir="$1"
    local build="${ZIGGY_SMOKE_BUILD:-}"
    if [ -z "$build" ]; then
        build="$run_dir/build"
        (cd "$LINUX_EXAMPLE_DIR" && bun run build:linux --prefix "$build") || return 1
    fi
    if [ ! -f "$build/bin/ziggy-test-app" ]; then
        echo "The Linux build $build has no bin/ziggy-test-app." >&2
        return 1
    fi
    # The frontend is embedded in the executable, so the build installs nothing but the executable. A scenario that passes
    # proves the frontend loads from the executable alone.
    local installed
    installed="$(find "$build/bin" -type f | wc -l)"
    if [ "$installed" -ne 1 ]; then
        echo "The Linux build installs more than the executable:" >&2
        find "$build/bin" -type f >&2
        return 1
    fi
    mkdir -p "$run_dir/app"
    cp "$build/bin/ziggy-test-app" "$run_dir/app/" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local app="$ZIGGY_SMOKE_RUN_DIR/app/ziggy-test-app"
    local log="$test_dir/app.log"
    mkdir -p "$test_dir/data"
    local pgid
    read -r _ pgid < <(launch_in_process_group "$log" env \
        XDG_DATA_HOME="$test_dir/data" \
        ZIGGY_TEST_APP_CONFIG_DIR="$test_dir/config" \
        ZIGGY_TEST_APP_STATE_DIR="$test_dir/state" \
        xvfb-run -a -s "-screen 0 1280x1024x24" "$app" ${ZIGGY_REMOTE_CONTROL:+--remote-control "$ZIGGY_REMOTE_CONTROL"} ${ZIGGY_THEME:+--theme "$ZIGGY_THEME"}) || return 1
    echo "$pgid" > "$test_dir/$LINUX_PGID_FILE_NAME"
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$LINUX_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$LINUX_PGID_FILE_NAME")" || true
    fi
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/data/dev.ziggy.testapp"
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
    pgid="$(cat "$test_dir/$LINUX_PGID_FILE_NAME")"
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
    process_group_alive "$(cat "$test_dir/$LINUX_PGID_FILE_NAME")"
}

#
# Succeeds when the developer tools are showing. They dock inside the window, so the frontend's area is smaller than
# it was.
# Usage: ziggy_platform_devtools_visible <test_dir> <the frontend's area before they opened>
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
# Succeeds when the desktop's appearance can be read and set with gsettings, which the workflows-only scenarios need.
#
ziggy_platform_changes_appearance() {
    command -v gsettings > /dev/null 2>&1 && gsettings get org.gnome.desktop.interface color-scheme > /dev/null 2>&1
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
        current="$(gsettings get org.gnome.desktop.interface color-scheme)" || return 1
        printf '%s\n' "$current" > "$test_dir/system-appearance.txt"
    fi
    if [ "$theme" = "dark" ]; then
        gsettings set org.gnome.desktop.interface color-scheme prefer-dark || return 1
    else
        gsettings set org.gnome.desktop.interface color-scheme prefer-light || return 1
    fi
}

#
# Puts the desktop's appearance back. Usage: ziggy_platform_restore_system_theme <test_dir>
#
ziggy_platform_restore_system_theme() {
    local test_dir="$1"
    local value
    value="$(cat "$test_dir/system-appearance.txt")"
    if ! gsettings set org.gnome.desktop.interface color-scheme "$value"; then
        echo "could not set the desktop's appearance back to $value" >&2
        return 1
    fi
}
