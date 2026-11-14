#!/usr/bin/env bash

# Hello world example: change it into your own smoke test, or delete it.
#
# Presses the shortcut of the Say Hello From an Action action as a user does, through the native app, and checks the line its handler
# writes. The test app is started by this scenario, so the menu scenario's line cannot be the one it finds.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

press_key CmdOrCtrl+Shift+H
wait_for_text log "Hello from an action" 30
