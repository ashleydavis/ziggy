#!/usr/bin/env bash

# The frontend sets and gets a value of the config file and of the state file through dotted key paths, the backend's message handler and
# task read the config file, and both values are still there after the app is started again.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

type_into config-input blue
click config-set
wait_for_text config-result "config saved"
click config-get
wait_for_text config-result "config: blue"

click state-set
wait_for_text config-result "state saved"
click state-get
wait_for_text config-result "state: blue"

click config-from-backend
wait_for_text config-result "backend config: blue"
click config-from-task
wait_for_text config-result "task config: blue"

restart_test_app

click config-get
wait_for_text config-result "config: blue"
click state-get
wait_for_text config-result "state: blue"

state_file="$(ziggy_platform_state_path "$ZIGGY_TEST_DIR")" || fail "the state file's path is not known"
[ "$(jq -r '.test.value' "$state_file" 2> /dev/null)" = "blue" ] || fail "the state file $state_file does not hold test.value blue"
