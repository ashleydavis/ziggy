#!/usr/bin/env bash

# The log files: the lines the page, the ping handler and two tasks log reach the log files the test app writes in its
# data directory, headed with the title from its app.zon and tagged with where they came from, and both files are closed with their
# footers when the app quits.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
# The page pings the backend when it starts, which logs a line from the page and one from the ping handler.
wait_for_text reply "says: hello from the UI"
click start-short
wait_for_text event-log "task-completed hello-short-1 succeeded"
click start-fail
wait_for_text event-log "task-completed hello-fail-2 failed HelloFailure"
answer="$(control '{"command":"quit"}')"
case "$answer" in
    *'"ok":true'*)
        ;;
    *)
        fail "the quit command was not accepted: $answer"
        ;;
esac
if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 30; then
    fail "the app was still running 30 seconds after the quit command"
fi

data_dir="$(ziggy_platform_data_dir "$ZIGGY_TEST_DIR")"
if [ -z "$data_dir" ]; then
    # A connected iPhone or iPad, whose data directory the host cannot read.
    exit 0
fi
log_files=("$data_dir"/logs/ziggy-test-app-*.log)
log_file=""
error_file=""
for candidate in "${log_files[@]}"; do
    case "$candidate" in
        *-errors.log)
            error_file="$candidate"
            ;;
        *)
            log_file="$candidate"
            ;;
    esac
done
if [ "${#log_files[@]}" -ne 2 ] || [ ! -f "$log_file" ] || [ ! -f "$error_file" ]; then
    fail "the logs directory does not hold one log file and one error log file: ${log_files[*]}"
fi
grep -q "^Ziggy test app$" "$log_file" || fail "the log file is not headed with the title of the test app's app.zon: $(cat "$log_file")"
grep -q "\] \[INFO\] \[Worker [0-9]*\] the short task is running$" "$log_file" || fail "the log file has no worker's info line: $(cat "$log_file")"
grep -q "\] \[ERROR\] \[Worker [0-9]*\] the failing task is failing$" "$log_file" || fail "the log file has no worker's error line: $(cat "$log_file")"
grep -q "\] \[INFO\] \[Frontend\] the page sent a ping$" "$log_file" || fail "the log file has no line from the frontend: $(cat "$log_file")"
grep -q "\] \[INFO\] ping received$" "$log_file" || fail "the log file has no line from the ping handler: $(cat "$log_file")"
grep -q "^--- Log End ---$" "$log_file" || fail "the log file has no footer: $(cat "$log_file")"
grep -q "\] \[ERROR\] \[Worker [0-9]*\] the failing task is failing$" "$error_file" || fail "the error log file has no worker's error line: $(cat "$error_file")"
grep -q "^--- Error Log End ---$" "$error_file" || fail "the error log file has no footer: $(cat "$error_file")"
if grep -q "the short task is running" "$error_file"; then
    fail "the error log file has the info line: $(cat "$error_file")"
fi
