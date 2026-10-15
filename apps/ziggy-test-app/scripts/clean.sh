#!/usr/bin/env bash

# Removes the test app's build output on every platform this machine can build for. See clean.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for platform in linux windows; do
    bash "$SCRIPT_DIR/clean-$platform.sh"
done

# Android is cleaned only where the Android SDK is installed: without it nothing of Android's can have been built, and the
# Android clean stops for want of it. The places looked in are the ones lib/android-env.sh looks in.
android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$android_sdk" ]; then
    for candidate in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
        if [ -d "$candidate" ]; then
            android_sdk="$candidate"
            break
        fi
    done
fi
if [ -n "$android_sdk" ] && [ -d "$android_sdk" ]; then
    bash "$SCRIPT_DIR/clean-android.sh"
else
    echo "Skipped Android: no Android SDK is installed, so nothing of Android's was built."
fi

if [ "$(uname -s)" = "Darwin" ]; then
    for platform in macos ios; do
        bash "$SCRIPT_DIR/clean-$platform.sh"
    done
fi
