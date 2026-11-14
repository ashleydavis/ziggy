#!/usr/bin/env bash

# The remote control server numbers the apps connected to it as windows and sends each command to the window it names, with
# window 1 when a command names none, and closing window 1 leaves window 2 working. The scenario starts a second app process
# itself, so it runs before any new-window work exists.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

SECOND_DIR="$ZIGGY_TEST_DIR/second"
trap 'ziggy_platform_stop "$SECOND_DIR" || true; stop_app_on_exit' EXIT

start_test_app

ziggy_platform_start "$SECOND_DIR" || fail "the second app did not start"
wait_for_ready 2

answer="$(window_control 2 '{"command":"click","dataId":"start-short"}')" || exit 1
if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
    fail "clicking start-short on window 2 failed: $answer"
fi

waited=0
found=false
shown=""
while [ "$waited" -lt "$WAIT_TIMEOUT_SECONDS" ]; do
    answer="$(window_control 2 '{"command":"get-text","dataId":"output"}')" || exit 1
    shown="$(printf '%s' "$answer" | jq -r '.value')"
    case "$shown" in
        *"hello from a short task"*)
            found=true
            break
            ;;
    esac
    sleep 1
    waited=$((waited + 1))
done
if [ "$found" != "true" ]; then
    fail "window 2's output never showed the short task's text. It showed: $shown"
fi

expect_text_absent output "hello from a short task"

for bad in '{"command":"ready","window":0}' '{"command":"ready","window":"2"}'; do
    answer="$(control "$bad")" || exit 1
    if [ "$(printf '%s' "$answer" | jq -r '.error')" != "InvalidWindow" ]; then
        fail "a line for a window no app can have got no InvalidWindow: $bad was answered $answer"
    fi
done

ziggy_platform_stop "$ZIGGY_TEST_DIR"
wait_for_ready 2
answer="$(window_control 2 '{"command":"get-text","dataId":"output"}')" || exit 1
case "$(printf '%s' "$answer" | jq -r '.value')" in
    *"hello from a short task"*)
        ;;
    *)
        fail "window 2 lost the short task's text when window 1 closed: $answer"
        ;;
esac
