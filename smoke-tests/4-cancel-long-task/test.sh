#!/usr/bin/env bash

# Cancelling the source of a long task stops it early: it completes as failed with the message Cancelled and sends no more output.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
type_into child-count 2
# Twenty seconds, so the task is still running when the cancel lands. At the default three seconds, the iOS smoke job
# failed this scenario on CI: the task ran all 30 steps and succeeded, and the cancel had nothing left to cancel.
type_into long-duration 20000
click start-long
wait_for_text output "long task step 3"
click cancel-source
wait_for_text event-log "task-completed hello-long-1 failed Cancelled"
steps_at_cancel="$(count_in output "long task step")"
sleep 2
steps_later="$(count_in output "long task step")"
if [ "$steps_later" != "$steps_at_cancel" ]; then
    fail "the cancelled task kept working: $steps_at_cancel steps at the cancel, $steps_later two seconds later"
fi
if [ "$steps_later" -ge 200 ]; then
    fail "the cancelled task ran to its end ($steps_later steps)"
fi
wait_for_empty jobs
