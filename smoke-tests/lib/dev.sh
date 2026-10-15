#!/usr/bin/env bash

# The dev mode platform library of the Ziggy test app's smoke tests. See common.sh for what it implements.
#
# In dev mode the app is two programs: the test app's own dev server (Vite, run as the test app's dev:ui script runs it) and the dev
# host in front of it, which runs the test app's backend, answers /__ziggy and forwards everything else to Vite. The UI runs in a
# headless Chrome or Chromium opened at the dev host's /__ziggy/start, which sends it on to the UI with the query the backend makes,
# as a native app loads it. Both are started directly here, the dev host built with or without the test hooks, so no supervisor
# runs: the supervisor is covered by the dev-only scenarios. The browser is $ZIGGY_DEV_BROWSER when that is set, or the first of
# google-chrome, chromium and chromium-browser on the PATH, or Chrome where its installer puts it on macOS and Windows.
#
# Vite watches the UI's files by polling (CHOKIDAR_USEPOLLING) instead of with the operating system's file watches, which are a
# limited number per user shared with every other program the user runs, so a run cannot fail for want of one.

DEV_EXAMPLE_DIR="$ZIGGY_SMOKE_APP_DIR"

# The files the dev host's, Vite's and the browser's process groups are recorded in, per scenario.
DEV_HOST_PGID_FILE_NAME="dev-host.pgid"
DEV_VITE_PGID_FILE_NAME="vite.pgid"
DEV_BROWSER_PGID_FILE_NAME="browser.pgid"

#
# Prints the browser to run, or fails naming what it looked for.
#
dev_browser() {
    if [ -n "${ZIGGY_DEV_BROWSER:-}" ]; then
        printf '%s\n' "$ZIGGY_DEV_BROWSER"
        return 0
    fi
    local candidate
    for candidate in google-chrome chromium chromium-browser; do
        if command -v "$candidate" > /dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    # On macOS and Windows Chrome is not on the PATH, so it is looked for where its installer puts it.
    for candidate in \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "C:/Program Files/Google/Chrome/Application/chrome.exe" \
        "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo "No browser to run the UI in: none of google-chrome, chromium or chromium-browser is on the PATH, Chrome is not installed where its installer puts it on macOS or Windows, and ZIGGY_DEV_BROWSER is not set." >&2
    return 1
}

#
# Prints the name the dev host's executable has on this operating system.
#
dev_host_executable() {
    local kind="$1"
    local suffix=""
    if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
        suffix=".exe"
    fi
    printf '%s\n' "$ZIGGY_SMOKE_RUN_DIR/$kind/bin/ziggy-test-app-dev-host$suffix"
}

#
# Opens the page in a headless browser with a profile of its own under the scenario's directory, so its storage is the scenario's.
# Usage: dev_open_browser <test_dir> <the dev host's port>
#
dev_open_browser() {
    local test_dir="$1"
    local port="$2"
    local browser pid pgid
    browser="$(dev_browser)" || return 1
    mkdir -p "$test_dir/browser"
    read -r pid pgid < <(launch_in_process_group "$test_dir/browser.log" "$browser" \
        --headless=new \
        --disable-gpu \
        --no-first-run \
        --no-default-browser-check \
        --window-size=1280,1024 \
        --user-data-dir="$test_dir/browser" \
        "http://127.0.0.1:$port/__ziggy/start") || return 1
    echo "$pgid" > "$test_dir/$DEV_BROWSER_PGID_FILE_NAME"
}

#
# Stops the browser, when one is open.
#
dev_close_browser() {
    local test_dir="$1"
    if [ -f "$test_dir/$DEV_BROWSER_PGID_FILE_NAME" ]; then
        local browser_pgid
        browser_pgid="$(cat "$test_dir/$DEV_BROWSER_PGID_FILE_NAME")"
        # On Windows the browser is a Windows program, and the processes it starts are not in the group Git Bash made for it, so
        # signalling the group left them running with the profile locked, and the browser started again on the same profile could
        # not open it. The whole tree is ended by the browser's Windows process id. The browser was started as the group's leader,
        # so the group's id is its own id.
        if [ -r "/proc/$browser_pgid/winpid" ]; then
            taskkill //F //T //PID "$(cat "/proc/$browser_pgid/winpid")" > /dev/null || true
        fi
        kill_process_group "$browser_pgid" || true
        rm -f "$test_dir/$DEV_BROWSER_PGID_FILE_NAME"
    fi
}

#
# Starts the test app's Vite dev server and prints the port it serves on, read from what it prints. It takes 5173 or the next one
# free, which it finds by trying to listen, so two runs at once never share one. Usage: dev_start_vite <test_dir>
#
dev_start_vite() {
    local test_dir="$1"
    local log="$test_dir/vite.log"
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$log" env CHOKIDAR_USEPOLLING=1 NO_COLOR=1 \
        bash -c 'cd "$1" && exec bun run dev:ui --host 127.0.0.1' bash "$DEV_EXAMPLE_DIR") || return 1
    echo "$pgid" > "$test_dir/$DEV_VITE_PGID_FILE_NAME"
    local waited=0
    local served
    while true; do
        served="$(grep -oE 'Local: +http://127\.0\.0\.1:[0-9]+' "$log" | grep -oE '[0-9]+$' | head -n 1)"
        if [ -n "$served" ]; then
            printf '%s\n' "$served"
            return 0
        fi
        if ! process_group_alive "$pgid"; then
            echo "Vite exited before it served. Its log:" >&2
            cat "$log" >&2
            return 1
        fi
        if [ "$waited" -ge 1200 ]; then
            echo "Vite never said where it serves. Its log:" >&2
            cat "$log" >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

ziggy_platform_prepare() {
    local run_dir="$1"
    dev_browser > /dev/null || return 1
    (cd "$DEV_EXAMPLE_DIR" && zig build ziggy-test-app-dev-host -Dtest-hooks=true -p "$run_dir/test") || return 1
    (cd "$DEV_EXAMPLE_DIR" && zig build ziggy-test-app-dev-host -p "$run_dir/release") || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local kind="$2"
    local keep_data="${3:-}"
    local host
    host="$(dev_host_executable "$kind")"
    local host_port_file="$test_dir/dev-host-port.txt"
    local port_file="$test_dir/control-port.txt"
    # The browser keeps a page's storage by its origin, which includes the dev host's port, so a restart on the data the last run
    # left serves on the port the last run had.
    local host_port=0
    if [ "$keep_data" = "keep-data" ] && [ -s "$host_port_file" ]; then
        host_port="$(tr -d '\n' < "$host_port_file")"
    fi
    rm -f "$host_port_file" "$port_file"
    mkdir -p "$test_dir/data"
    local vite_port
    vite_port="$(dev_start_vite "$test_dir")" || return 1
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$test_dir/app.log" env \
        ZIGGY_TEST_MODE=1 \
        ZIGGY_TEST_PORT_FILE="$port_file" \
        "$host" --data-dir "$test_dir/data" --port "$host_port" --port-file "$host_port_file" --ui-port "$vite_port") || return 1
    echo "$pgid" > "$test_dir/$DEV_HOST_PGID_FILE_NAME"
    local waited=0
    while [ ! -s "$host_port_file" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "The dev host exited before it listened. Its log:" >&2
            cat "$test_dir/app.log" >&2
            return 1
        fi
        if [ "$waited" -ge 600 ]; then
            echo "The dev host never wrote its port." >&2
            cat "$test_dir/app.log" >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    dev_open_browser "$test_dir" "$(tr -d '\n' < "$host_port_file")" || return 1
    if [ "$kind" = "release" ]; then
        return 0
    fi
    waited=0
    while [ ! -s "$port_file" ]; do
        if [ "$waited" -ge 600 ]; then
            echo "The dev host never wrote its control port." >&2
            cat "$test_dir/app.log" >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    ZIGGY_CONTROL_HOST=127.0.0.1
    ZIGGY_CONTROL_PORT="$(tr -d '\n' < "$port_file")"
    export ZIGGY_CONTROL_HOST ZIGGY_CONTROL_PORT
}

ziggy_platform_stop() {
    local test_dir="$1"
    dev_close_browser "$test_dir"
    local file
    for file in "$DEV_HOST_PGID_FILE_NAME" "$DEV_VITE_PGID_FILE_NAME"; do
        if [ -f "$test_dir/$file" ]; then
            kill_process_group "$(cat "$test_dir/$file")" || true
        fi
    done
}

#
# Prints a path the dev host reported in the form this shell writes paths in. The dev host reports a real path, with every
# symbolic link resolved (macOS keeps the temporary folder under /var, a link to /private/var), and on Windows in Windows' own
# form, which Git Bash's cygpath turns into its own. Usage: dev_shell_path <path>
#
dev_shell_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -u "$1"
    else
        printf '%s\n' "$1"
    fi
}

#
# Prints a directory as the dev host reports it, in the form this shell writes paths in: with every symbolic link resolved.
# Usage: dev_real_directory <directory>
#
dev_real_directory() {
    (cd "$1" && pwd -P)
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/data"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pgid
    pgid="$(cat "$test_dir/$DEV_HOST_PGID_FILE_NAME")"
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
    process_group_alive "$(cat "$test_dir/$DEV_HOST_PGID_FILE_NAME")"
}

ziggy_platform_artifact_files() {
    local kind="$1"
    dev_host_executable "$kind"
}

ziggy_platform_has_control_port() {
    [ -s "$1/control-port.txt" ]
}

# Closing the page is how a developer leaves the app in dev mode. The dev host, which runs the app's backend, runs on.
ziggy_platform_leave_app() {
    dev_close_browser "$1"
}

ziggy_platform_process_alive() {
    ziggy_platform_is_running "$1"
}
