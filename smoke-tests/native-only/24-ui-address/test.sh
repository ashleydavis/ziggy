#!/usr/bin/env bash

# The frontend is served from ziggy-app://app/ on Linux, macOS and iOS and from https://ziggy-app.invalid/ on Windows
# and Android. On each the page must be a secure context in which localStorage, IndexedDB, and fetch and XMLHttpRequest
# of the frontend's own files work, which a change to how a native app serves the frontend could break while the frontend
# still loads.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

click address-check
wait_for_text address-status "checked"

echo "The UI shows $(text_of address-href), $(text_of address-origin), $(text_of address-secure), $(text_of address-local-storage), $(text_of address-indexeddb), $(text_of address-fetch) and $(text_of address-xhr)"

case "$ZIGGY_SMOKE_PLATFORM" in
    windows|android)
        expected_prefix="https://ziggy-app.invalid/"
        ;;
    *)
        expected_prefix="ziggy-app://app/"
        ;;
esac

case "$(text_of address-href)" in
    "href: $expected_prefix"*)
        ;;
    *)
        fail "The UI is not served from $expected_prefix. It shows $(text_of address-href)"
        ;;
esac

wait_for_text address-secure "secure context: true" 1
wait_for_text address-local-storage "localStorage: kept" 1
wait_for_text address-indexeddb "indexedDB: kept" 1
wait_for_text address-fetch "fetch: 200 has the UI" 1
wait_for_text address-xhr "xhr: 200 has the UI" 1
