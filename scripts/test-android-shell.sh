#!/usr/bin/env bash

# Runs the JUnit tests of Ziggy's Android shell, through the test app's Gradle project, which includes the shell's build. See
# test-android-shell.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../apps/ziggy-test-app/scripts/android-common.sh"

ziggy_android_gradle :ziggy-native-android:testDebugUnitTest --rerun-tasks
