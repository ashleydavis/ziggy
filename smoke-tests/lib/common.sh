#!/usr/bin/env bash

# What every scenario uses: start the app, talk to it through the remote control server, and check what the frontend shows.
#
# A scenario sources this file. It defines functions only. The platform library chosen by the runner implements:
#
#   ziggy_platform_prepare <run_dir>
#       Puts the built app in the run directory: from the build directory ZIGGY_SMOKE_BUILD names when it is set, or else one the
#       platform's build script builds into the run directory. Returns non-zero when the build or the install fails.
#
#   ziggy_platform_start <test_dir> [keep-data]
#       Starts the app for one scenario with --remote-control "$ZIGGY_REMOTE_CONTROL" (the ziggy.remoteControl extra on Android),
#       or without it when ZIGGY_REMOTE_CONTROL is empty,
#       recording what it started through launch_in_process_group. The app connects to the remote control server that
#       start_test_app started. Returns non-zero when the app did not start. With keep-data it starts the app again on the data the
#       last run left, instead of fresh data, and on a phone on the same device and the same install.
#
#   ziggy_platform_stop <test_dir> [keep-device]
#       Stops the app and everything it started. With keep-device a phone stays claimed, so a restart finds its data.
#
#   ziggy_platform_devtools_visible <test_dir> <the frontend's area before they opened>   (desktop platforms)
#       Succeeds when the developer tools are showing. How a script sees them differs: on Linux and macOS they dock inside the
#       window and shrink the frontend's area, and on Windows they are a window of their own.
#
#   ziggy_platform_leave_app <test_dir>
#       Takes the app out of the user's sight without ending it: on a desktop it closes the window (the File menu's Close Window), on
#       Android it presses Home, and on the iOS simulator it opens another app over it. Returns non-zero when it cannot, which is
#       the case on a connected iPhone or iPad.
#
#   ziggy_platform_process_alive <test_dir>
#       Succeeds when the app's process is running, whether or not its window or activity is in sight.
#
#   ziggy_platform_data_dir <test_dir>
#       Prints the directory the app uses for its private data in this scenario, when the host can read it, or nothing.

set -u

SCENARIO_NAME="$(basename "$(dirname "${BASH_SOURCE[1]}")")"
source "$ZIGGY_SMOKE_DIR/lib/process-control.sh"
source "$ZIGGY_SMOKE_DIR/lib/$ZIGGY_SMOKE_PLATFORM.sh"


# Seconds the frontend has to show something before a wait gives up.
WAIT_TIMEOUT_SECONDS=60

fail() {
    echo "FAILED: $*" >&2
    exit 1
}

#
# Stops the app and the remote control server when the scenario ends, however it ends.
#
stop_app_on_exit() {
    ziggy_platform_stop "$ZIGGY_TEST_DIR" || true
    stop_remote_control_server
}
trap stop_app_on_exit EXIT

#
# Starts the remote control server for this scenario on ports the system chooses, recording it through launch_in_process_group,
# and waits until it listens. Sets ZIGGY_CONTROL_HOST and ZIGGY_CONTROL_PORT to where the script connects, and ZIGGY_REMOTE_CONTROL
# to the address the app is started with. The server's stdin is a pipe whose writing end this scenario keeps open on file descriptor
# 4, so the server ends when the scenario does, however the scenario ends. A pipe works on every platform, where a FIFO does not
# reach a native Windows program. A job launch_in_process_group starts from inside the process substitution is given /dev/null
# as its stdin, so the pipe is passed on file descriptor 5 and the server's shell moves it to stdin.
#
start_remote_control_server() {
    local log="$ZIGGY_TEST_DIR/remote-control-server.log"
    local launched="$ZIGGY_TEST_DIR/remote-control-server.launched"
    rm -f "$launched"
    exec 4> >(launch_in_process_group "$log" bash -c 'exec 0<&5 5<&-; cd "$1" && exec bun run ziggy-remote-control-server --app-port 0 --script-port 0' \
        remote-control-server "$ZIGGY_SMOKE_APP_DIR" 5<&0 > "$launched")
    local waited=0
    local pid pgid ports
    while true; do
        if [ -s "$launched" ]; then
            read -r pid pgid < "$launched"
            echo "$pgid" > "$ZIGGY_TEST_DIR/remote-control-server.pgid"
            ports="$(sed -n 's/^The remote control server is listening: the app on 127\.0\.0\.1:\([0-9]*\), the script on 127\.0\.0\.1:\([0-9]*\)\.$/\1 \2/p' "$log")"
            if [ -n "$ports" ]; then
                break
            fi
            if ! kill -0 "$pid" 2>/dev/null; then
                cat "$log" >&2
                fail "the remote control server ended before it listened"
            fi
        fi
        if [ "$waited" -ge 600 ]; then
            cat "$log" >&2
            fail "the remote control server did not listen within 60 seconds"
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    ZIGGY_CONTROL_HOST=127.0.0.1
    ZIGGY_CONTROL_PORT="${ports#* }"
    ZIGGY_REMOTE_CONTROL="127.0.0.1:${ports%% *}"
    export ZIGGY_CONTROL_HOST ZIGGY_CONTROL_PORT ZIGGY_REMOTE_CONTROL
}

#
# Stops the remote control server, when this scenario started one.
#
stop_remote_control_server() {
    exec 4>&-
    if [ -f "$ZIGGY_TEST_DIR/remote-control-server.pgid" ]; then
        kill_process_group "$(cat "$ZIGGY_TEST_DIR/remote-control-server.pgid")" || true
    fi
}

#
# Starts the remote control server and the app, and opens the control connection.
#
start_test_app() {
    start_remote_control_server
    ziggy_platform_start "$ZIGGY_TEST_DIR" || fail "the app did not start"
    open_control_connection
    wait_for_ready
}

#
# Stops the app and starts it again on the data it kept, then opens the control connection to the new run. A scenario uses it to
# check what survives a restart.
#
restart_test_app() {
    exec 3>&-
    ziggy_platform_stop "$ZIGGY_TEST_DIR" keep-device || fail "the app did not stop cleanly before it was started again"
    ziggy_platform_start "$ZIGGY_TEST_DIR" keep-data || fail "the app did not start again"
    open_control_connection
    wait_for_ready
}

#
# Opens the control connection to the remote control server on file descriptor 3. A signal that reaches this script while bash connects, such as the
# exit of a child it started, makes connect fail with "Interrupted system call", which bash reports and does not retry, so that
# failure is tried again. Any other failure ends the scenario.
#
open_control_connection() {
    local error_file="$ZIGGY_TEST_DIR/control-connect-error.txt"
    local attempt=1
    while ! { exec 3<>"/dev/tcp/$ZIGGY_CONTROL_HOST/$ZIGGY_CONTROL_PORT"; } 2>"$error_file"; do
        if ! grep -q "Interrupted system call" "$error_file" || [ "$attempt" -ge 5 ]; then
            cat "$error_file" >&2
            fail "could not connect to the control connection at $ZIGGY_CONTROL_HOST:$ZIGGY_CONTROL_PORT"
        fi
        attempt=$((attempt + 1))
    done
}

#
# Sends one command line on the control connection and prints the reply line. Usage: control <json>
#
# Called inside $( ), where its fail exits only that subshell, so every caller below ends the scenario with `|| exit 1` when it
# fails. Without that, the Windows smoke job of the Release run on commit 0367000 kept asking a dead connection "could not write to the control
# connection" every second for a minute in each scenario, until a wait gave up.
#
control() {
    printf '%s\n' "$1" >&3 || fail "could not write to the control connection"
    local answer
    if ! read -r -t 90 -u 3 answer; then
        # The macOS job of the Ziggy test app workflow (run 37455466019, scenario 13-menu-edit) failed here with the app gone and
        # nothing to show why, because only the command was reported. The app's own log is what shows whether it crashed.
        if [ -f "$ZIGGY_TEST_DIR/app.log" ]; then
            echo "The app's log:" >&2
            cat "$ZIGGY_TEST_DIR/app.log" >&2
        fi
        # A crash on MacOS is written as a report, which holds the exception and the stack of the thread that crashed.
        for report in "$HOME"/Library/Logs/DiagnosticReports/ZiggyTestApp*; do
            if [ -f "$report" ]; then
                echo "Crash report $report:" >&2
                head -c 20000 "$report" >&2
            fi
        done
        fail "no answer from the control connection to $1"
    fi
    printf '%s\n' "$answer"
}

#
# Waits until the frontend replies to commands, which means it has loaded and the bridge works.
#
wait_for_ready() {
    local waited=0
    local answer
    while [ "$waited" -lt "$WAIT_TIMEOUT_SECONDS" ]; do
        answer="$(control '{"command":"ready"}')" || exit 1
        if [ "$(printf '%s' "$answer" | jq -r '.ok')" = "true" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "the UI never answered a ready command"
}

#
# Clicks the element with the data-id. Usage: click <data-id>
#
click() {
    local answer
    answer="$(control "{\"command\":\"click\",\"dataId\":\"$1\"}")" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "click $1 failed: $answer"
    fi
}

#
# Prints the text of the element with the data-id. Usage: text_of <data-id>
#
text_of() {
    local answer
    answer="$(control "{\"command\":\"get-text\",\"dataId\":\"$1\"}")" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "get-text $1 failed: $answer"
    fi
    printf '%s' "$answer" | jq -r '.value'
}

#
# Sets the value of the input with the data-id. Usage: type_into <data-id> <text>
#
type_into() {
    local answer
    answer="$(control "{\"command\":\"type\",\"dataId\":\"$1\",\"text\":\"$2\"}")" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "type into $1 failed: $answer"
    fi
}

#
# Waits until the text of the element contains the text, and fails with what it did show when it never does.
# Usage: wait_for_text <data-id> <text> [seconds]
#
wait_for_text() {
    local data_id="$1"
    local wanted="$2"
    local seconds="${3:-$WAIT_TIMEOUT_SECONDS}"
    local waited=0
    local shown=""
    while [ "$waited" -lt "$seconds" ]; do
        shown="$(text_of "$data_id")" || exit 1
        case "$shown" in
            *"$wanted"*)
                return 0
                ;;
        esac
        sleep 1
        waited=$((waited + 1))
    done
    fail "$data_id never showed \"$wanted\". It showed: $shown"
}

#
# Fails when the text of the element contains the text. Usage: expect_text_absent <data-id> <text>
#
expect_text_absent() {
    local shown
    shown="$(text_of "$1")" || exit 1
    case "$shown" in
        *"$2"*)
            fail "$1 shows \"$2\" and should not. It showed: $shown"
            ;;
    esac
}

#
# Prints how many times the text appears in the element's text. Usage: count_in <data-id> <text>
#
count_in() {
    local shown
    shown="$(text_of "$1")" || exit 1
    printf '%s' "$shown" | grep -o -F -- "$2" | wc -l | tr -d ' '
}

#
# Waits until the element's text is empty. Usage: wait_for_empty <data-id> [seconds]
#
wait_for_empty() {
    local data_id="$1"
    local seconds="${2:-$WAIT_TIMEOUT_SECONDS}"
    local waited=0
    local shown=""
    while [ "$waited" -lt "$seconds" ]; do
        shown="$(text_of "$data_id")" || exit 1
        if [ -z "$shown" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "$data_id never became empty. It showed: $shown"
}


#
# Sets what the next native file or folder dialog returns, so a scenario can use a picker without a dialog being shown. The
# paths are used for one dialog. Usage: answer_next_dialog <JSON array of paths>
#
answer_next_dialog() {
    local answer
    answer="$(control "{\"command\":\"pick-answer\",\"paths\":$1}")" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "the answer for the next dialog was not accepted: $answer"
    fi
}

#
# Chooses a menu item as a user would, through the native app, so the native app's own actions really happen and any other action reaches the
# frontend. Usage: choose_menu_item <action>
#
choose_menu_item() {
    local answer
    answer="$(control "{\"command\":\"menu\",\"action\":\"$1\"}")" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "choosing the menu item $1 failed: $answer"
    fi
}

#
# Prints the size in pixels of the area the frontend is drawn in, as <width>x<height>. Zooming, docking the developer tools and
# going full screen change it.
#
viewport_size() {
    control '{"command":"viewport"}' | jq -r '.value'
}

#
# Waits until the frontend's area is a size other than the one given, and prints the new size. Fails when it never is.
# Usage: wait_for_viewport_other_than <size>
#
wait_for_viewport_other_than() {
    local waited=0
    local now
    while [ "$waited" -lt 30 ]; do
        now="$(viewport_size)"
        if [ "$now" != "$1" ]; then
            printf '%s\n' "$now"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "the UI's area stayed $1"
}

#
# Waits until the frontend's area is the size given. Fails when it never is. Usage: wait_for_viewport <size>
#
wait_for_viewport() {
    local waited=0
    while [ "$waited" -lt 30 ]; do
        if [ "$(viewport_size)" = "$1" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "the UI's area never went back to $1. It is $(viewport_size)"
}

#
# Types text into an element the way typing does, so the browser can undo it. Usage: insert_text <data-id> <text>
#
insert_text() {
    local answer
    answer="$(control "{\"command\":\"insert\",\"dataId\":\"$1\",\"text\":\"$2\"}")" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "insert into $1 failed: $answer"
    fi
}

#
# Waits until the value of the input or text area is the text given. Fails when it never is. Usage: wait_for_value <data-id> <text>
#
wait_for_value() {
    local waited=0
    local shown=""
    while [ "$waited" -lt 30 ]; do
        shown="$(control "{\"command\":\"get-value\",\"dataId\":\"$1\"}")" || exit 1
        shown="$(printf '%s' "$shown" | jq -r '.value')"
        if [ "$shown" = "$2" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "$1 never held \"$2\". It held: $shown"
}

#
# Prints the number in a file the app keeps in its data directory (a count a background task writes), or 0 when there is no such
# file yet. Usage: data_file_number <file name>
#
data_file_number() {
    local data_dir
    data_dir="$(ziggy_platform_data_dir "$ZIGGY_TEST_DIR")" || fail "could not read the app's data directory"
    if [ -f "$data_dir/$1" ]; then
        tr -d '\n' < "$data_dir/$1"
    else
        echo 0
    fi
}

#
# Waits until the number in a data file is at least the given value, and prints it. Usage: wait_for_data_file_number <file> <value>
#
wait_for_data_file_number() {
    local waited=0
    local number
    while [ "$waited" -lt "$WAIT_TIMEOUT_SECONDS" ]; do
        number="$(data_file_number "$1")"
        if [ "$number" -ge "$2" ]; then
            printf '%s\n' "$number"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "$1 never reached $2. It holds $number"
}
