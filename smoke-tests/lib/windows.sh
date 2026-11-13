#!/usr/bin/env bash

# The Windows platform library of the Ziggy test app's smoke tests. See common.sh for what it implements.
#
# Run it under Git Bash on Windows. The app opens a normal window on the desktop of the session, so no virtual display is
# needed. Each scenario points LOCALAPPDATA at its own directory, which is where the app keeps its data and WebView2 keeps
# its profile, so two scenarios never share either.

# The file the app's process group is recorded in, per scenario.
WINDOWS_PGID_FILE_NAME="app.pgid"

#
# Prints a path in the form a native Windows program understands (D:/a/...), and the path unchanged where there is no
# cygpath (a cross check from Linux).
#
windows_native_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

ziggy_platform_prepare() {
    local run_dir
    run_dir="$(windows_native_path "$1")"
    local build="${ZIGGY_SMOKE_BUILD:-}"
    if [ -z "$build" ]; then
        build="$run_dir/build"
        (cd "$ZIGGY_SMOKE_APP_DIR" && bun run build:windows --prefix "$build") || return 1
    fi
    if [ ! -f "$build/ziggy-test-app/ziggy-test-app.exe" ]; then
        echo "The Windows build $build has no ziggy-test-app/ziggy-test-app.exe." >&2
        return 1
    fi
    mkdir -p "$run_dir/app"
    cp -R "$build/ziggy-test-app/." "$run_dir/app/" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local app="$ZIGGY_SMOKE_RUN_DIR/app/ziggy-test-app.exe"
    local log="$test_dir/app.log"
    mkdir -p "$test_dir/data"
    local pgid
    read -r _ pgid < <(launch_in_process_group "$log" env \
        LOCALAPPDATA="$(windows_native_path "$test_dir/data")" \
        ZIGGY_TEST_APP_CONFIG_DIR="$(windows_native_path "$test_dir/config")" \
        ZIGGY_TEST_APP_STATE_DIR="$(windows_native_path "$test_dir/state")" \
        "$app" ${ZIGGY_REMOTE_CONTROL:+--remote-control "$ZIGGY_REMOTE_CONTROL"} ${ZIGGY_THEME:+--theme "$ZIGGY_THEME"}) || return 1
    echo "$pgid" > "$test_dir/$WINDOWS_PGID_FILE_NAME"
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$WINDOWS_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")" || true
    fi
    if [ "${2:-}" = "keep-device" ]; then
        # The app is about to start again on the same data. WebView2 refuses to create its controller while the first run's browser
        # process still holds the user data folder: the Windows job of the Ziggy test app workflow failed scenario 17-ui-storage
        # on its restart with "ziggy native app: creating the WebView2 controller failed with HRESULT 0x800700AA" (ERROR_BUSY). So the
        # restart waits until no WebView2 process is left.
        local waited=0
        while tasklist //fo csv //nh //fi "IMAGENAME eq msedgewebview2.exe" | grep -q "msedgewebview2.exe"; do
            if [ "$waited" -ge 120 ]; then
                echo "A WebView2 process was still running 60 seconds after the app was stopped." >&2
                return 1
            fi
            sleep 0.5
            waited=$((waited + 1))
        done
    fi
}

ziggy_platform_config_path() {
    printf '%s\n' "$1/config/config.toml"
}

ziggy_platform_state_path() {
    printf '%s\n' "$1/state/state.json"
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/data/dev.ziggy.testapp"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pgid
    pgid="$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")"
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
    process_group_alive "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")"
}

#
# Succeeds when the developer tools are showing. WebView2 opens them as a window of their own, so the frontend's area does not change
# and they are found by their window's title, "DevTools - " and the frontend's address. Only the WebView2 processes' titles are read,
# because reading the window title of every process takes many seconds.
# Usage: ziggy_platform_devtools_visible <test_dir> <the frontend's area before they opened>
#
ziggy_platform_devtools_visible() {
    local windows
    windows="$(tasklist //v //fo csv //nh //fi "IMAGENAME eq msedgewebview2.exe")" || fail "could not list the WebView2 windows"
    printf '%s\n' "$windows" | grep -qF "DevTools - ziggy-app.invalid/"
}

ziggy_platform_leave_app() {
    choose_menu_item close-window
}

ziggy_platform_process_alive() {
    ziggy_platform_is_running "$1"
}

#
# Succeeds when the desktop's appearance can be read and set in the registry, which the workflows-only scenarios need.
#
ziggy_platform_changes_appearance() {
    reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme > /dev/null 2>&1
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
        current="$(reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme 2>/dev/null | grep -o '0x[0-9a-fA-F]*' | tail -1)" || return 1
        printf '%s\n' "$current" > "$test_dir/system-appearance.txt"
    fi
    if [ "$theme" = "dark" ]; then
        reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d 0 /f > /dev/null || return 1
    else
        reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d 1 /f > /dev/null || return 1
    fi
}

#
# Puts the desktop's appearance back. Usage: ziggy_platform_restore_system_theme <test_dir>
#
ziggy_platform_restore_system_theme() {
    local test_dir="$1"
    local value
    value="$(cat "$test_dir/system-appearance.txt")"
    if ! reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d "$((value))" /f > /dev/null; then
        echo "could not set the desktop's appearance back to $value" >&2
        return 1
    fi
}
