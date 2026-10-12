#!/usr/bin/env bash

# Shared library for the shell smoke-test runners: the per-run resources a suite must not share
# with anything else on the machine.
#
# Every test, not every suite, owns a uniquely named directory for its fixtures, logs and scratch
# space, and gets one without opting in, so two runs on one machine never write into the same place.
#
# Source this from a runner or a test harness:
#   source "<repo>/scripts/lib/test-lib.sh"
#
# It defines functions only. Nothing here deletes anything: directories are left behind on purpose
# so the evidence from a failure survives.

# The directory every per-test directory is created inside.
ZIGGY_TEST_TEMP_ROOT="${TMPDIR:-/tmp}/ziggy-tests"

# On Windows the root is held in the native form, because one directory must have one name.
#
# Git Bash rewrites an argument that looks like a POSIX path before a native binary sees it, and it
# does that only for arguments. A path bash writes into a file is not an argument and is not
# rewritten, so a native program and the script would see two different strings for one directory.
# Holding the native form means there is nothing left to rewrite and both sides read the same string.
# Unchanged on Linux and macOS.
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    mkdir -p "$ZIGGY_TEST_TEMP_ROOT"
    ZIGGY_TEST_TEMP_ROOT="$(cd "$ZIGGY_TEST_TEMP_ROOT" && pwd -W)"
fi

#
# Creates a directory belonging to one test and prints its absolute path.
#
# Uniqueness comes from mktemp, not from a timestamp or a counter: two tests starting in the same
# millisecond is exactly the case a timestamp misses. The label goes in the name so a directory left
# behind can be traced back to the test that made it, with anything that is not a letter, digit,
# dot, dash or underscore replaced so a label can never steer the path elsewhere.
# Usage: ziggy_test_temp_dir <label>
#
ziggy_test_temp_dir() {
    local label="$1"
    local safe_label
    safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '-')"
    mkdir -p "$ZIGGY_TEST_TEMP_ROOT"
    mktemp -d "$ZIGGY_TEST_TEMP_ROOT/${safe_label}-XXXXXX"
}
