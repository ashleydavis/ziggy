#!/usr/bin/env bash

# A config file with a bad line is reported by its line, the app runs on its defaults and the file is left alone; an unreadable state file
# is logged and the app starts with an empty state; a write keeps the file's comments and its other key; and a menu item's Zig function
# reads the config file.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

config_path="$(ziggy_platform_config_path "$ZIGGY_TEST_DIR")" || fail "the config file's path is not known"
state_path="$(ziggy_platform_state_path "$ZIGGY_TEST_DIR")" || fail "the state file's path is not known"
mkdir -p "$(dirname "$config_path")"
printf '# kept\n[test]\nvalue = "green"\noops = = 1\n' > "$config_path"
cp "$config_path" "$ZIGGY_TEST_DIR/config-before.toml"

start_test_app

click config-problem
wait_for_text config-result "problem: line 4"
click config-get
wait_for_text config-result "config: none"
click config-set
wait_for_text config-result "config not saved"
cmp "$config_path" "$ZIGGY_TEST_DIR/config-before.toml" || fail "the config file changed"
grep -q "has an error on line 4" "$ZIGGY_TEST_DIR/app.log" || fail "the app's log does not name the bad config line"

# Start again on a good config file and an unreadable state file.
exec 3>&-
ziggy_platform_stop "$ZIGGY_TEST_DIR" keep-device || fail "the app did not stop cleanly before it was started again"
printf '# kept\n[test]\nvalue = "green"\nother = 1\n' > "$config_path"
mkdir -p "$(dirname "$state_path")"
printf 'not json' > "$state_path"
ziggy_platform_start "$ZIGGY_TEST_DIR" keep-data || fail "the app did not start again"
open_control_connection
wait_for_ready
grep -q "could not be read" "$ZIGGY_TEST_DIR/app.log" || fail "the app's log does not name the unreadable state file"

click config-get
wait_for_text config-result "config: green"
type_into config-input blue
click config-set
wait_for_text config-result "config saved"
grep -q '^# kept$' "$config_path" || fail "the config file lost its comment"
grep -q '^\[test\]$' "$config_path" || fail "the config file lost its table"
grep -q '^value = "blue"$' "$config_path" || fail "the config file does not hold the new value"
grep -q '^other = 1$' "$config_path" || fail "the config file lost its other key"

choose_menu_item read-config
wait_for_text config-result "menu config: blue"
