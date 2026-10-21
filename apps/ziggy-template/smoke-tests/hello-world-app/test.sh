#!/usr/bin/env bash

# Hello world example: change it into your own smoke test, or delete it.
#
# Starts the real app, built with the test hooks, presses each button and checks what its log shows: the backend's message response to the
# hello-world message, and the output of the hello-world task and how it ended.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
click send-message
wait_for_text log "The backend says: Hello world, from Zig on" 30
click start-task
wait_for_text log "Hello world from a task" 30
wait_for_text log "The task ended: succeeded" 30
