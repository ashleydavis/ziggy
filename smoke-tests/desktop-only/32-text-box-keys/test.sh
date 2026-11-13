#!/usr/bin/env bash

# A typing shortcut, one with no Ctrl, Alt or Cmd, runs while no text box has the focus. A focused text box keeps the key: Escape and
# the arrow keys run no action there and Enter types a newline. listActions reports a typing shortcut.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

# With no text box focused, each typing shortcut runs its action.
press_key Escape
wait_for_text key-log "escape-action"
press_key Enter
wait_for_text key-log "enter-action"
press_key Down
wait_for_text key-log "down-action"

# The text area has the focus now: Escape and Down run no action, and Enter types a newline.
insert_text notes "hello"
wait_for_value notes "hello"
press_key Escape
press_key Down
press_key Enter
insert_text notes "x"
wait_for_value notes "$(printf 'hello\nx')"

# The action button's message reaches the core after any the text area's keys could have posted, so a wrong run shows here first.
click run-say-action
wait_for_text action-result "said by an action"

# Each action ran once, from the presses outside the text area.
for action in escape-action enter-action down-action; do
    count="$(count_in key-log "$action")"
    if [ "$count" != "1" ]; then
        fail "$action ran $count times. The keys pressed in the text area must run no action."
    fi
done

click list-actions
wait_for_text action-result "down-action Down Action Down"
