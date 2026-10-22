#!/usr/bin/env bash

# The frontend loads, the bridge works, and the backend sends a message response to a message.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
wait_for_text reply "Zig " 30
wait_for_text reply "says: hello from the UI" 30
shown="$(text_of reply)"
case "$shown" in
    *"$(uname -m)"*|*"aarch64"*|*"x86_64"*|*"arm"*)
        ;;
    *)
        fail "the reply does not name a CPU architecture: $shown"
        ;;
esac
