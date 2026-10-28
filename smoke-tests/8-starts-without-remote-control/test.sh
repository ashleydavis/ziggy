#!/usr/bin/env bash

# The app started without --remote-control runs and never connects to the remote control server. The remote control code
# is in every build and does nothing unless the app is started with the option.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Seconds the app has to connect if it were going to. An app started with the option connects before its window shows, far sooner.
NO_CONNECTION_SECONDS=20

start_remote_control_server
ZIGGY_REMOTE_CONTROL=""
ziggy_platform_start "$ZIGGY_TEST_DIR" || fail "the app did not start"
open_control_connection
# The server holds a command until an app connects, so a reply would mean the app had connected. A read that fails before its
# time is up means the connection ended, which would mean the server had gone. That is told by the time the read took, not by its
# status: bash 3.2, the bash macOS has, gives the same status for a timeout as for a connection that ended.
printf '%s\n' '{"command":"ready"}' >&3 || fail "could not write to the control connection"
status=0
read_started=$SECONDS
read -r -t "$NO_CONNECTION_SECONDS" -u 3 answer || status=$?
if [ "$status" -eq 0 ]; then
    fail "the app started without --remote-control answered a command, so it connected to the remote control server: $answer"
fi
if [ $((SECONDS - read_started)) -lt "$NO_CONNECTION_SECONDS" ]; then
    cat "$ZIGGY_TEST_DIR/remote-control-server.log" >&2
    fail "the control connection ended while the scenario waited, so the remote control server is gone"
fi
if ! ziggy_platform_process_alive "$ZIGGY_TEST_DIR"; then
    fail "the app started without --remote-control was not running $NO_CONNECTION_SECONDS seconds later"
fi
