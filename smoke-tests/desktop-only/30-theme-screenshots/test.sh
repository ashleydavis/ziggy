#!/usr/bin/env bash

# Light and dark screenshots of the app differ.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

export ZIGGY_THEME=light
start_test_app
control "{\"command\":\"screenshot\",\"outputPath\":\"$ZIGGY_TEST_DIR/light.png\"}" > /dev/null || exit 1
[ -s "$ZIGGY_TEST_DIR/light.png" ] || fail "the light screenshot is empty"

unset ZIGGY_THEME
export ZIGGY_THEME=dark
restart_test_app
control "{\"command\":\"screenshot\",\"outputPath\":\"$ZIGGY_TEST_DIR/dark.png\"}" > /dev/null || exit 1
[ -s "$ZIGGY_TEST_DIR/dark.png" ] || fail "the dark screenshot is empty"

if cmp -s "$ZIGGY_TEST_DIR/light.png" "$ZIGGY_TEST_DIR/dark.png"; then
    fail "the light and dark screenshots are the same"
fi
