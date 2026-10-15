#!/usr/bin/env bash

# A file dropped on the page in dev mode reaches the UI with a path from window.ziggy.getPathForFile, the path of the copy the dev
# host saved under the data directory, holding the dropped file's contents. The browser gives a page no dropped file's path, so the
# dev script sends the file to the dev host, which saves it and records the copy with the backend as the drop.
#
# No tool can drag a file into the headless browser, so the drop-file command makes the UI receive a drop event carrying a File, which
# is what the browser hands the page when a file is dropped on it.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

answer="$(control '{"command":"drop-file","dataId":"drop-zone","fileName":"two words.txt","fileSize":5}')"
if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
    fail "the drop-file command failed: $answer"
fi
dropped_dir="$(dev_real_directory "$(ziggy_platform_data_dir "$ZIGGY_TEST_DIR")")/dropped/"
wait_for_text drop-result "dropped: "

dropped_path="$(text_of drop-result)"
dropped_path="$(dev_shell_path "${dropped_path#*dropped: }")"
case "$dropped_path" in
    "$dropped_dir"*)
        ;;
    *)
        fail "the dropped file's copy is not under $dropped_dir: $dropped_path"
        ;;
esac
case "$dropped_path" in
    */"two words.txt")
        ;;
    *)
        fail "the dropped file's copy is not named after it: $dropped_path"
        ;;
esac
if [ ! -f "$dropped_path" ]; then
    fail "the UI was given $dropped_path, and nothing is there"
fi
if [ "$(wc -c < "$dropped_path" | tr -d ' ')" != "5" ]; then
    fail "the copy at $dropped_path does not hold the dropped file's contents: it has $(wc -c < "$dropped_path" | tr -d ' ') bytes"
fi
copies="$(find "$dropped_dir" -type f | wc -l | tr -d ' ')"
if [ "$copies" != "1" ]; then
    fail "one file was dropped and the dev host saved $copies copies under $dropped_dir"
fi
