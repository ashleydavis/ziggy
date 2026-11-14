#!/usr/bin/env bash

# The test app's View menu declares the zoom shortcuts. Pressing them as a user does, through the native app, changes the size of the
# area the frontend is drawn in, and Ctrl+0 puts it back.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

normal="$(viewport_size)"

press_key CmdOrCtrl+Plus
wait_for_viewport_other_than "$normal" > /dev/null
press_key CmdOrCtrl+0
wait_for_viewport "$normal"

press_key CmdOrCtrl+Minus
wait_for_viewport_other_than "$normal" > /dev/null
press_key CmdOrCtrl+0
wait_for_viewport "$normal"
