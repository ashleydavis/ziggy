#!/usr/bin/env bash

# Hello world example: change it into your own smoke test, or delete it.
#
# Starts the real app, built with the test hooks, and checks what it shows: the backend's message response to the hello-world message, and the
# output of the hello-world task once its button is pressed.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
wait_for_text greeting "The backend says: Hello world, from Zig on" 30
click start-task
wait_for_text task-output "Hello world from a task" 30
wait_for_text task-output "The task ended: succeeded" 30
