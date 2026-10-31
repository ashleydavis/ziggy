#!/usr/bin/env bash

# Runs the unit tests of the test app's backend, and of Ziggy's core library when --ziggy-dir names a checkout of Ziggy, on a phone platform,
# where the program has to run on the emulator or simulator and not on this machine. See test-zig-mobile.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/../apps/ziggy-test-app" && pwd)"

PLATFORM="${1:-}"
case "$PLATFORM" in
    android | ios)
        ;;
    *)
        echo "Usage: test-zig-mobile.sh <android|ios> [--ziggy-dir <dir>]" >&2
        exit 2
        ;;
esac
shift

# The checkout of Ziggy whose core library's, utils' and log's tests run too, when one is named. The test app names the repository it lives
# in, so the tests of Ziggy's core library, utils and log run on a phone beside its own; an app built on Ziggy runs its own backend's tests
# only.
ZIGGY_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ziggy-dir)
            ZIGGY_DIR="$(cd "$2" && pwd)"
            shift 2
            ;;
        *)
            echo "Unknown argument $1. Usage: test-zig-mobile.sh <android|ios> [--ziggy-dir <dir>]" >&2
            exit 2
            ;;
    esac
done

# The test app's backend embeds the built frontend, so the frontend is built before anything here.
(cd "$EXAMPLE_DIR" && bun run bundle:ui)

packages="$EXAMPLE_DIR/backend"
if [ -n "$ZIGGY_DIR" ]; then
    packages="$ZIGGY_DIR/packages/ziggy/core $ZIGGY_DIR/packages/ziggy/utils $ZIGGY_DIR/packages/ziggy/log $packages"
fi

# The directory whose build.zig has the step that builds the unit test program of a package directory: Ziggy's core library's, utils' and
# log's is the build.zig at the root of the Ziggy checkout, the test app backend's is the test app's own build.zig.
build_dir_of() {
    case "$1" in
        "$EXAMPLE_DIR/backend")
            echo "$EXAMPLE_DIR"
            ;;
        *)
            echo "$ZIGGY_DIR"
            ;;
    esac
}

# The step that builds the unit test program of a package directory.
step_name_of() {
    case "$1" in
        "$EXAMPLE_DIR/backend")
            echo "ziggy-test-app-backend"
            ;;
        *)
            # Ziggy's core, utils and log, whose steps are test-binary-ziggy-core, test-binary-ziggy-utils and test-binary-ziggy-log.
            echo "ziggy-$(basename "$1")"
            ;;
    esac
}

if [ "$PLATFORM" = "android" ]; then
    export ZIGGY_SMOKE_APP_DIR="$EXAMPLE_DIR"
    source "$SCRIPT_DIR/../smoke-tests/lib/android.sh"
    ziggy_android_require_commands zig adb
    work_dir="$(mktemp -d "$EXAMPLE_DIR/zig-mobile-test.XXXXXX")"
    trap 'ziggy_android_release_device; find "$work_dir" -type f -delete; find "$work_dir" -depth -type d -empty -delete' EXIT
    ziggy_android_claim_device
    # The program is built for the claimed device's architecture.
    case "$(ziggy_adb shell getprop ro.product.cpu.abi | tr -d '\r')" in
        x86_64)
            arch="x86_64"
            triple="x86_64-linux-android"
            ;;
        arm64-v8a)
            arch="arm64"
            triple="aarch64-linux-android"
            ;;
        *)
            echo "ERROR: the device's ABI is neither x86_64 nor arm64-v8a." >&2
            exit 1
            ;;
    esac
    # The libc is API level 28's, not the app's minimum: Zig's standard library calls getrandom, which was added in level 28, and
    # the link failed with "undefined symbol: getrandom" against the minimum level's libc. The device is newer than that. Its own
    # level cannot be used, because the NDK has no libraries for a level newer than it (the NDK here stops before the emulator's
    # level 36, and the link failed with FileNotFound on its crtbegin_dynamic.o).
    ziggy_android_write_libc_file "$arch" "$work_dir/libc.txt" 28
    device_dir="/data/local/tmp/ziggy-zig-test-$$"
    ziggy_adb shell mkdir -p "$device_dir"
    for package_dir in $packages; do
        name="$(basename "$(dirname "$package_dir")")-$(basename "$package_dir")"
        step_name="$(step_name_of "$package_dir")"
        echo "Building the unit tests of $package_dir for $triple"
        (cd "$(build_dir_of "$package_dir")" && zig build "test-binary-$step_name" -Dtarget="$triple" --libc "$work_dir/libc.txt" -p "$work_dir/$name")
        test_binary="$(find "$work_dir/$name/test-bin" -type f | head -n 1)"
        ziggy_adb push "$test_binary" "$device_dir/$name" > /dev/null
        echo "Running them on $ANDROID_SERIAL_CLAIMED"
        # The device's shell reports the program's exit code on its last line, because older adb versions do not pass it through.
        result="$(ziggy_adb shell "cd $device_dir && chmod +x ./$name && ./$name; echo ziggy-exit-code=\$?" | tr -d '\r')"
        printf '%s\n' "$result"
        if ! printf '%s\n' "$result" | grep -qx 'ziggy-exit-code=0'; then
            ziggy_adb shell "rm -f $device_dir/*; rmdir $device_dir/.zig-cache/tmp $device_dir/.zig-cache; rmdir $device_dir" || true
            echo "FAILED: the unit tests of $package_dir failed on the device." >&2
            exit 1
        fi
    done
    ziggy_adb shell "rm -f $device_dir/*; rmdir $device_dir/.zig-cache/tmp $device_dir/.zig-cache; rmdir $device_dir"
else
    source "$EXAMPLE_DIR/scripts/lib/apple-common.sh"
    apple_require_tool zig xcrun
    work_dir="$(mktemp -d "$EXAMPLE_DIR/zig-mobile-test.XXXXXX")"
    trap 'find "$work_dir" -type f -delete; find "$work_dir" -depth -type d -empty -delete' EXIT
    # Zig finds the macOS SDK by itself but not the iOS simulator's, and linking a program needs it: the unit test job of the Ziggy
    # example workflow failed with "unable to find libSystem system library" (run 37455466019, job ziggy-test-app-zig-unit-tests
    # (ios, macos-latest), log line 710). The SDK's path is given as the sysroot.
    sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)" || apple_fail "could not find the iOS simulator SDK."
    udid="$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -n 1)"
    if [ -z "$udid" ]; then
        echo "ERROR: no iOS simulator is booted." >&2
        exit 1
    fi
    for package_dir in $packages; do
        name="$(basename "$(dirname "$package_dir")")-$(basename "$package_dir")"
        step_name="$(step_name_of "$package_dir")"
        echo "Building the unit tests of $package_dir for the iOS simulator"
        # The program is built for size, because the debug build of Zig's standard library calls _dyld_get_image_header_containing_address
        # and _dyld_image_path_containing_address for stack traces, which the iOS simulator SDK's libSystem does not export, and the
        # link failed with "undefined symbol: __dyld_get_image_header_containing_address" (run 37464567354, job
        # ziggy-test-app-zig-unit-tests (ios, macos-latest)). The size build leaves out the stack trace code, so the calls go too.
        # Reproduced with a fake sysroot on Linux: the symbols are undefined for the debug, fast and safe builds and not for this one.
        (cd "$(build_dir_of "$package_dir")" && zig build "test-binary-$step_name" -Dtarget=aarch64-ios.14.0-simulator -Doptimize=ReleaseSmall --sysroot "$sdk_path" -p "$work_dir/$name") || {
            # The build failed with "unable to find libSystem system library" with the sysroot given too (run 37458283805, job
            # ziggy-test-app-zig-unit-tests (ios, macos-latest), log line 526), so what the SDK holds is printed to show why.
            echo "The simulator SDK's libSystem files:" >&2
            ls -la "$sdk_path"/usr/lib/libSystem* >&2 || true
            head -n 12 "$sdk_path/usr/lib/libSystem.tbd" >&2 || true
            echo "FAILED: could not build the unit tests of $package_dir for the simulator." >&2
            exit 1
        }
        test_binary="$(find "$work_dir/$name/test-bin" -type f | head -n 1)"
        echo "Running them on simulator $udid"
        (cd "$package_dir" && xcrun simctl spawn "$udid" "$test_binary") || {
            echo "FAILED: the unit tests of $package_dir failed on the simulator." >&2
            exit 1
        }
    done
fi
