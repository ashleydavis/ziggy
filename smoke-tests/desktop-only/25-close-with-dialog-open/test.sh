#!/usr/bin/env bash

# Quitting the app while a native file dialog is open ends the app: the native app closes the dialog before it stops the backend, so the
# pick ends as cancelled and stopping the backend never waits on the dialog.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

# No paths are set for the dialog, so a real one is shown. The frontend replies to the click before it requests the dialog, because while
# the dialog is open the backend's main thread waits on it and replies to nothing the control connection sends through the frontend.
click pick-files
# Nothing in the app reports that the dialog is on screen, so the scenario gives the native app three seconds to show it. Were it not
# shown yet, quitting must still end the app.
sleep 3
# The quit command goes to the native app straight from the control connection, without the backend's main thread.
reply="$(control '{"command":"quit"}')"
case "$reply" in
    *'"ok":true'*)
        ;;
    *)
        fail "the quit command was not accepted: $reply"
        ;;
esac
if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 30; then
    fail "the app was still running 30 seconds after it was told to quit with a file dialog open"
fi
