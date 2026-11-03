#!/usr/bin/env bash
#
# Hello world example: change it into your own smoke test, or delete it.
#
# Starts the built app through the remote control server, chooses each item of the Hello menu as a user would and checks what each writes to
# the log: Say Hello From Zig runs a Zig function that sends the frontend an event, Say Hello From the UI reaches the frontend
# as a menu event, and Say Hello From an Action runs the frontend's handler of the template's action.
# A desktop-only test, because a phone has no menu.
#

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

choose_menu_item hello-from-zig
wait_for_text log "Hello from Zig, run from the menu" 30

choose_menu_item hello-from-ui
wait_for_text log "Hello from the UI, run from the menu" 30

choose_menu_item hello-from-action
wait_for_text log "Hello from an action" 30
