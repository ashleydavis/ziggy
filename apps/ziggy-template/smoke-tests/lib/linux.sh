#!/usr/bin/env bash

# The Linux platform library of the Ziggy template's smoke tests. See common.sh for what it implements.
#
# The app runs on a virtual display of its own, so a run shows no window and two runs never share a display.
# WebKitGTK starts its web process in a bubblewrap sandbox, which some Linux setups do not allow an unprivileged
# program to create (Ubuntu's default restriction on user namespaces is one). The sandbox is switched off for these test
# processes only, through the environment WebKitGTK documents for it.

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
    if [ ! -f "$build/bin/ziggy-template" ]; then
        echo "The Linux build $build has no bin/ziggy-template." >&2
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
    cp "$build/bin/ziggy-template" "$run_dir/app/" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local app="$ZIGGY_SMOKE_RUN_DIR/app/ziggy-template"
    local log="$test_dir/app.log"
    mkdir -p "$test_dir/data"
    local pgid
    read -r _ pgid < <(launch_in_process_group "$log" env \
        WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
        XDG_DATA_HOME="$test_dir/data" \
        xvfb-run -a -s "-screen 0 1280x1024x24" "$app" ${ZIGGY_REMOTE_CONTROL:+--remote-control "$ZIGGY_REMOTE_CONTROL"}) || return 1
    echo "$pgid" > "$test_dir/$LINUX_PGID_FILE_NAME"
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$LINUX_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$LINUX_PGID_FILE_NAME")" || true
    fi
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/data/dev.ziggy.template"
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
