#!/usr/bin/env bash

# ? is a shortcut an action can have. listActions reports it, it runs the action while no text box has the focus, and a focused text
# area keeps it, so the question mark is typed.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

click list-actions
wait_for_text action-result "show-help Show Help ?"

# With no text box focused, ? runs the action.
press_key "?"
wait_for_text key-log "show-help"

# In the text area, ? types a question mark and runs no action.
insert_text notes "a"
wait_for_value notes "a"
press_key "?"
wait_for_value notes "a?"

# The action button's message reaches the core after the key press's, so a wrong run shows here first.
click run-say-action
wait_for_text action-result "said by an action"

if [ "$(count_in key-log "show-help")" != "1" ]; then
    fail "show-help ran $(count_in key-log "show-help") times. The ? pressed in the text area must run no action."
fi
