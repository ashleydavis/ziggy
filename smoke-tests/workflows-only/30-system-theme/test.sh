#!/usr/bin/env bash

# With the setting system, a change of the device's appearance reaches the page while the app stays in front: the core applies it and
# tells the page through config-changed, and the page reads the new value with getSystemTheme.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app
wait_for_text theme "system"

ziggy_platform_set_system_theme "$ZIGGY_TEST_DIR" dark
wait_for_text theme-background "theme background: dark"
wait_for_text theme "system dark"

ziggy_platform_set_system_theme "$ZIGGY_TEST_DIR" light
wait_for_text theme-background "theme background: light"
wait_for_text theme "system light"
