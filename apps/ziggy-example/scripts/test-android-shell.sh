#!/usr/bin/env bash

# Runs the JUnit tests of Ziggy's Android shell, through the example's Gradle project, which includes the shell's build. See
# test-android-shell.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

ziggy_android_gradle :ziggy-native-android:testDebugUnitTest --rerun-tasks
