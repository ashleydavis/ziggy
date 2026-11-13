#!/usr/bin/env bash

# Checks that a link to an outside page reaches the system on every platform: a plain link, a target="_blank" link followed 6 s
# after a click and a window.open 6 s after a click, so no user gesture is behind the last two.
#
# Linux: a run with every URL handler hidden first checks that a failed open reaches the app's log. Then a URL handler of the
# scenario's own records each address the system is asked to open, and the frontend still holds its marker.
# Android: the device log shows the activity start for each address.
# Windows, macOS and iOS: nothing reports the open, so the scenario checks the app is still running 11 s after each click, which
# comes up to 6 s after it. On Windows the app's log also shows the new window request, and on Windows and macOS the frontend
# still holds its marker.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

if [ "$ZIGGY_SMOKE_PLATFORM" = "linux" ]; then
    ziggy_platform_hide_url_handlers "$ZIGGY_TEST_DIR"
    start_test_app
    click link-plain
    ziggy_platform_wait_app_log "$ZIGGY_TEST_DIR" "ziggy native app: could not open https://plain.example.com/ziggy-external-link in the system browser"
    ziggy_platform_watch_opened_urls "$ZIGGY_TEST_DIR"
    restart_test_app
else
    start_test_app
fi

type_into external-link-marker "still here"

index=0
for element_id in link-plain new-window-later open-window-later; do
    index=$((index + 1))
    case "$ZIGGY_SMOKE_PLATFORM" in
        android|ios)
            if [ "$index" -gt 1 ]; then
                restart_test_app
            fi
            ;;
    esac
    click "$element_id"
    case "$element_id" in
        link-plain)
            host="plain.example.com"
            ;;
        new-window-later)
            host="new-window.example.com"
            ;;
        open-window-later)
            host="window-open.example.com"
            ;;
    esac
    case "$ZIGGY_SMOKE_PLATFORM" in
        linux|android)
            wait_for_opened_url "$host"
            ;;
        *)
            if ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 11; then
                fail "the app ended after $element_id was clicked"
            fi
            ;;
    esac
    if [ "$ZIGGY_SMOKE_PLATFORM" = "windows" ] && [ "$element_id" != "link-plain" ]; then
        ziggy_platform_wait_app_log "$ZIGGY_TEST_DIR" "ziggy native app: a new window was requested"
    fi
    case "$ZIGGY_SMOKE_PLATFORM" in
        linux|windows|macos)
            wait_for_value external-link-marker "still here"
            ;;
    esac
done

echo "The app asked the system to open each address on $ZIGGY_SMOKE_PLATFORM"
