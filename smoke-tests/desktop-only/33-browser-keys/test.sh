#!/usr/bin/env bash

# Ctrl+= and Ctrl+Plus each zoom in once, Ctrl+Minus zooms out and Ctrl+0 resets the zoom. A key the app does not define, F5, does
# nothing to the page. listActions reports the zoom actions.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

normal="$(viewport_size)"

# One step in and one step out each time: a press that also zoomed the page would not come back to the normal size.
for key in CmdOrCtrl+Plus CmdOrCtrl+Equal; do
    press_key "$key"
    wait_for_viewport_other_than "$normal" > /dev/null
    choose_menu_item zoom-out
    wait_for_viewport "$normal"
done

press_key CmdOrCtrl+Minus
wait_for_viewport_other_than "$normal" > /dev/null
press_key CmdOrCtrl+0
wait_for_viewport "$normal"

# F5 reloads the page in WebView2 while its browser keys are on, which would clear the task's line.
choose_menu_item start-short
wait_for_text output "hello from a short task"
press_key F5
press_key CmdOrCtrl+Equal
wait_for_viewport_other_than "$normal" > /dev/null
case "$(text_of output)" in
    *"hello from a short task"*)
        ;;
    *)
        fail "pressing F5 reloaded the page: the task's line is gone"
        ;;
esac

click list-actions
wait_for_text action-result "zoom-in"
wait_for_text action-result "zoom-out"
wait_for_text action-result "zoom-reset"
