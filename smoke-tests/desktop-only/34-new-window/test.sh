#!/usr/bin/env bash

# New Window starts a window as a process of its own, with the arguments its action gives and a backend of its own; closing a
# window ends only its own process; on Linux and macOS Quit in any window ends every window's process, including windows whose
# opener has closed; on Windows Quit ends only its own window's process. It runs on Linux, Windows and macOS.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app
window_one_log="$(window_log_files "$ZIGGY_TEST_DIR")"
if [ -z "$window_one_log" ]; then
    fail "window 1 wrote no log file"
fi

choose_menu_item new-window
wait_for_ready 2
window_two_pid="$(started_window_pid "$window_one_log" 1)"

answer="$(window_control 2 '{"command":"viewport"}')" || exit 1
window_two_viewport="$(printf '%s' "$answer" | jq -r '.value')"
window_two_width="${window_two_viewport%%x*}"
window_one_viewport="$(viewport_size)"
window_one_width="${window_one_viewport%%x*}"
if [ "$window_two_width" -gt 640 ]; then
    fail "window 2's frontend area is $window_two_viewport, so it did not get the geometry its action gives it"
fi
if [ "$window_one_width" -le 640 ]; then
    fail "window 1's frontend area is $window_one_viewport, so the two windows are not told apart by their size"
fi

answer="$(window_control 2 '{"command":"click","dataId":"run-say-action"}')" || exit 1
if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
    fail "clicking run-say-action on window 2 failed: $answer"
fi
waited=0
shown=""
while [ "$waited" -lt "$WAIT_TIMEOUT_SECONDS" ]; do
    answer="$(window_control 2 '{"command":"get-text","dataId":"action-result"}')" || exit 1
    shown="$(printf '%s' "$answer" | jq -r '.value')"
    case "$shown" in
        *"said by an action"*)
            break
            ;;
    esac
    sleep 1
    waited=$((waited + 1))
done
case "$shown" in
    *"said by an action"*)
        ;;
    *)
        fail "window 2's action-result never showed the action's text. It showed: $shown"
        ;;
esac
case "$(text_of action-result)" in
    *"said by an action"*)
        fail "window 1's action-result shows what window 2's backend wrote, so the windows share a backend"
        ;;
esac

if ziggy_platform_quit_ends_every_window; then
    choose_menu_item new-window
    wait_for_ready 3
    window_three_pid="$(started_window_pid "$window_one_log" 2)"
    choose_menu_item new-window
    wait_for_ready 4
    window_four_pid="$(started_window_pid "$window_one_log" 3)"

    answer="$(window_control 4 '{"command":"menu","action":"close-window"}')" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "closing window 4 failed: $answer"
    fi
    wait_for_process_exit "$window_four_pid" "window 4"

    choose_menu_item close-window
    wait_for_log_end "$window_one_log" "window 1"
    ziggy_platform_os_process_alive "$window_two_pid" || fail "window 2 stopped when window 1 closed"
    ziggy_platform_os_process_alive "$window_three_pid" || fail "window 3 stopped when window 1 closed"
    wait_for_ready 2
    wait_for_ready 3

    answer="$(window_control 3 '{"command":"menu","action":"quit"}')" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "quitting from window 3 failed: $answer"
    fi
    wait_for_process_exit "$window_two_pid" "window 2"
    wait_for_process_exit "$window_three_pid" "window 3"
    if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" "$WAIT_TIMEOUT_SECONDS"; then
        fail "the app's processes were still running after Quit in window 3"
    fi

    window_log_files "$ZIGGY_TEST_DIR" > "$ZIGGY_TEST_DIR/window-logs.txt"
    log_count="$(wc -l < "$ZIGGY_TEST_DIR/window-logs.txt" | tr -d ' ')"
    if [ "$log_count" -ne 4 ]; then
        fail "the run wrote $log_count window log files, not one for each window"
    fi
    while read -r file; do
        if ! grep -q -F -- "--- Log End ---" "$file"; then
            fail "the log of a window does not end: $file"
        fi
    done < "$ZIGGY_TEST_DIR/window-logs.txt"
else
    choose_menu_item close-window
    if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" "$WAIT_TIMEOUT_SECONDS"; then
        fail "window 1's process was still running after its window closed"
    fi
    wait_for_ready 2
    ziggy_platform_os_process_alive "$window_two_pid" || fail "window 2 stopped when window 1 closed"

    answer="$(window_control 2 '{"command":"quit"}')" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "quitting window 2 failed: $answer"
    fi
    wait_for_process_exit "$window_two_pid" "window 2"
fi
