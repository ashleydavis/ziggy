#!/usr/bin/env bash

# Runs the Ziggy test app's smoke test scenarios for one platform. Invoked by the root package.json scripts, never directly.
# See run.md.

set -u

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SMOKE_DIR/../apps/ziggy-test-app" && pwd)"

source "$SMOKE_DIR/lib/test-lib.sh"
source "$SMOKE_DIR/lib/test-timeout.sh"
source "$SMOKE_DIR/lib/process-control.sh"


PLATFORM="${1:-}"
SCENARIO_FILTER="${2:-}"

case "$PLATFORM" in
    linux|windows|macos|android|ios|dev)
        ;;
    *)
        echo "Usage: run.sh <linux|windows|macos|android|ios|dev> [scenario number or name]" >&2
        exit 2
        ;;
esac

if [ ! -f "$SMOKE_DIR/lib/$PLATFORM.sh" ]; then
    echo "There is no platform library for $PLATFORM: $SMOKE_DIR/lib/$PLATFORM.sh" >&2
    exit 2
fi

# Every process this run starts is recorded as it is launched, so it can be checked for leaks and cleaned up at the end.
export ZIGGY_LAUNCHED_GROUPS
ZIGGY_LAUNCHED_GROUPS="$(mktemp "${TMPDIR:-/tmp}/ziggy-test-app-launched-XXXXXX")"

RUN_DIR="$(ziggy_test_temp_dir "ziggy-test-app-run")"
export ZIGGY_SMOKE_RUN_DIR="$RUN_DIR"
export ZIGGY_SMOKE_DIR="$SMOKE_DIR"
export ZIGGY_SMOKE_PLATFORM="$PLATFORM"
export ZIGGY_SMOKE_APP_DIR="$APP_DIR"

cleanup_run() {
    local pgid
    while read -r kind pgid; do
        if [ "$kind" = "pgid" ]; then
            kill_process_group "$pgid" || true
        fi
    done < "$ZIGGY_LAUNCHED_GROUPS"
    rm -f "$ZIGGY_LAUNCHED_GROUPS"
}
trap cleanup_run EXIT

source "$SMOKE_DIR/lib/$PLATFORM.sh"

echo "Building the test app for $PLATFORM..."
if ! ziggy_platform_prepare "$RUN_DIR"; then
    echo "FAILED: could not build the test app for $PLATFORM." >&2
    exit 1
fi
#
# Prints the scenario directories this platform runs, one per line, in numeric order: the ones every platform runs, in a
# native app the ones about what only a native app has (such as the address it serves the UI from), on a desktop platform
# the ones about desktop features such as the menu, and in dev mode the ones about dev mode.
#
list_scenarios() {
    {
        ls -d "$SMOKE_DIR"/[0-9]*
        case "$PLATFORM" in
            linux|windows|macos|android|ios)
                ls -d "$SMOKE_DIR"/native-only/[0-9]*
                ;;
        esac
        case "$PLATFORM" in
            linux|windows|macos)
                ls -d "$SMOKE_DIR"/desktop-only/[0-9]*
                ;;
            dev)
                ls -d "$SMOKE_DIR"/dev-only/[0-9]*
                ;;
        esac
    } | while IFS= read -r directory; do
        printf '%s\t%s\n' "$(basename "$directory")" "$directory"
    done | sort -V | cut -f2
}


passed=0
failed=0
failed_names=""

while IFS= read -r scenario_dir; do
    [ -f "$scenario_dir/test.sh" ] || continue
    scenario_name="$(basename "$scenario_dir")"
    scenario_number="${scenario_name%%-*}"
    if [ -n "$SCENARIO_FILTER" ] && [ "$SCENARIO_FILTER" != "$scenario_name" ] && [ "$SCENARIO_FILTER" != "$scenario_number" ]; then
        continue
    fi
    test_dir="$(ziggy_test_temp_dir "ziggy-test-app-$scenario_name")"
    echo "--- $scenario_name"
    ZIGGY_TEST_DIR="$test_dir" run_test_with_timeout "$ZIGGY_PER_TEST_TIMEOUT" bash "$scenario_dir/test.sh" < /dev/null
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "PASSED: $scenario_name"
        passed=$((passed + 1))
    else
        if test_timed_out "$status"; then
            echo "FAILED: $scenario_name ran out of time. Its files are in $test_dir"
        else
            echo "FAILED: $scenario_name (exit $status). Its files are in $test_dir"
        fi
        # A runner keeps none of the scenario's files, so the end of each log the app, its dev server and its browser wrote is
        # printed here, where the run's own log keeps it.
        for log_file in "$test_dir"/*.log; do
            if [ -f "$log_file" ]; then
                echo "--- the end of $(basename "$log_file"):"
                tail -n 60 "$log_file"
            fi
        done
        failed=$((failed + 1))
        failed_names="$failed_names $scenario_name"
    fi
done < <(list_scenarios)

leaked="$(list_leaked_launches)"
if [ -n "$leaked" ]; then
    echo "FAILED: processes this run started are still running:" >&2
    echo "$leaked" >&2
    failed=$((failed + 1))
fi

echo "Passed $passed, failed $failed."
if [ "$failed" -ne 0 ]; then
    echo "Failed:$failed_names"
    exit 1
fi
if [ "$passed" -eq 0 ]; then
    echo "No scenario ran." >&2
    exit 1
fi
exit 0
