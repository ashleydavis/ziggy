#!/usr/bin/env bash

# The theme from --theme reaches the page's prefers-color-scheme before its first script, a change of the setting reaches the page
# through the setting and matchMedia, and the setting is kept across a restart.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

export ZIGGY_THEME=dark
start_test_app
wait_for_text theme-background "theme background: dark"
wait_for_text theme "dark dark"

click set-theme-light
wait_for_text theme-background "theme background: light"
wait_for_text theme "light light"

click set-theme-dark
wait_for_text theme-background "theme background: dark"

click set-theme-light
wait_for_text theme-background "theme background: light"
wait_for_text theme "light light"

unset ZIGGY_THEME
restart_test_app
wait_for_text theme-background "theme background: light"
wait_for_text theme "light light"
