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
# The server holds a command until an app connects, so a reply would mean the app had connected. read gives a status above 128
# when its time runs out, and 1 when the connection ended, which would mean the server had gone.
printf '%s\n' '{"command":"ready"}' >&3 || fail "could not write to the control connection"
status=0
read -r -t "$NO_CONNECTION_SECONDS" -u 3 answer || status=$?
if [ "$status" -eq 0 ]; then
    fail "the app started without --remote-control answered a command, so it connected to the remote control server: $answer"
fi
if [ "$status" -le 128 ]; then
    cat "$ZIGGY_TEST_DIR/remote-control-server.log" >&2
    fail "the control connection ended while the scenario waited, so the remote control server is gone"
fi
if ! ziggy_platform_process_alive "$ZIGGY_TEST_DIR"; then
    fail "the app started without --remote-control was not running $NO_CONNECTION_SECONDS seconds later"
fi
