#!/usr/bin/env bash

# The menu items that are the frontend's own do what the buttons they stand for do: the task items start and cancel tasks, and
# About shows its text. The item that runs a Zig function runs it in the core. The event the function sends reaches the frontend.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

choose_menu_item about
wait_for_text edge-result "Ziggy test app: a small app built on Ziggy."

choose_menu_item start-short
wait_for_text output "hello from a short task"
wait_for_text event-log "task-completed hello-short-1 succeeded"

choose_menu_item start-long
wait_for_text output "long task step 2"
choose_menu_item cancel-long
wait_for_text event-log "task-completed hello-long-2 failed Cancelled"

choose_menu_item start-many
wait_for_text event-log "task-event hello-long-3 "
wait_for_text event-log "task-event hello-long-4 "
wait_for_text event-log "task-event hello-long-5 "
wait_for_text event-log "task-completed hello-long-5 succeeded" 60

choose_menu_item zig-event
wait_for_text event-log "menu-zig-event"
