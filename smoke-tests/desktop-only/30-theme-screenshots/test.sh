#!/usr/bin/env bash

# Light and dark screenshots of the app differ.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

# Waits until the app's splash overlay has gone, so the screenshot shows the app's UI rather than the splash art.
wait_for_splash() {
    local waited=0
    while true; do
        local answer
        answer=$(control '{"command":"exists","dataId":"ziggy-splash"}') || exit 1
        if ! printf '%s' "$answer" | grep -q '"ok":true'; then
            return 0
        fi
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -ge 50 ]; then
            fail "the splash screen never went away"
        fi
    done
}

export ZIGGY_THEME=light
start_test_app
wait_for_splash
control "{\"command\":\"screenshot\",\"outputPath\":\"$ZIGGY_TEST_DIR/light.png\"}" > /dev/null || exit 1
[ -s "$ZIGGY_TEST_DIR/light.png" ] || fail "the light screenshot is empty"

unset ZIGGY_THEME
export ZIGGY_THEME=dark
restart_test_app
wait_for_splash
control "{\"command\":\"screenshot\",\"outputPath\":\"$ZIGGY_TEST_DIR/dark.png\"}" > /dev/null || exit 1
[ -s "$ZIGGY_TEST_DIR/dark.png" ] || fail "the dark screenshot is empty"

if cmp -s "$ZIGGY_TEST_DIR/light.png" "$ZIGGY_TEST_DIR/dark.png"; then
    fail "the light and dark screenshots are the same"
fi
