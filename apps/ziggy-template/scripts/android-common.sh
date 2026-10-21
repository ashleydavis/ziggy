#!/usr/bin/env bash

# Shared by the *-android.sh scripts. Source it, do not run it. See android-common.md.

ZIGGY_ANDROID_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIGGY_EXAMPLE_DIR="$(cd "$ZIGGY_ANDROID_SCRIPTS_DIR/.." && pwd)"
ZIGGY_ANDROID_PROJECT_DIR="$ZIGGY_EXAMPLE_DIR/native/android"
ZIGGY_ANDROID_APP_ID="dev.ziggy.template"

# Resolves JAVA_HOME (a JDK 17) and ANDROID_HOME. It exits with a message
# when either is missing.
source "$ZIGGY_ANDROID_SCRIPTS_DIR/lib/android-env.sh"

#
# Fails with a message unless every named command is on the PATH. Usage: ziggy_android_require_commands <command...>
#
ziggy_android_require_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "ERROR: $command_name is not on the PATH. Install the tools the repository pins in mise.toml (mise install) and run the script with them on the PATH." >&2
            return 1
        fi
    done
}

#
# Prints the NDK version the template's Android project pins in variables.gradle.
#
ziggy_android_ndk_version() {
    local version
    version="$(sed -n 's/^ *ndkVersion = "\(.*\)".*$/\1/p' "$ZIGGY_ANDROID_PROJECT_DIR/variables.gradle")"
    if [ -z "$version" ]; then
        echo "ERROR: no ndkVersion found in $ZIGGY_ANDROID_PROJECT_DIR/variables.gradle" >&2
        return 1
    fi
    printf '%s\n' "$version"
}

#
# Prints the minimum SDK level, from the template's Android project's variables.gradle.
#
ziggy_android_min_sdk() {
    sed -n 's/^ *minSdkVersion = \([0-9]*\).*$/\1/p' "$ZIGGY_ANDROID_PROJECT_DIR/variables.gradle"
}

#
# Runs Gradle in the template's Android project. Usage: ziggy_android_gradle <gradle arguments...>
#
ziggy_android_gradle() {
    (cd "$ZIGGY_ANDROID_PROJECT_DIR" && ./gradlew "$@")
}

#
# Prints the template's version, from its package.json.
#
ziggy_android_version() {
    jq -r '.version' "$ZIGGY_EXAMPLE_DIR/package.json"
}

#
# Prints the Android ABI directory name for an architecture name: x86_64 or arm64. Usage: ziggy_android_abi <arch>
#
ziggy_android_abi() {
    case "$1" in
        x86_64)
            echo "x86_64"
            ;;
        arm64)
            echo "arm64-v8a"
            ;;
        *)
            echo "ERROR: unknown architecture '$1' (expected x86_64 or arm64)" >&2
            return 1
            ;;
    esac
}

#
# Writes the libc file Zig is given for an Android target, because Zig has no C library for Android and uses the NDK's. One file
# per architecture, because the headers and the libraries differ. The libraries are the ones for the given SDK level, so
# the program links only against what that level has. Usage: ziggy_android_write_libc_file <x86_64|arm64> <file> <sdk level>
#
ziggy_android_write_libc_file() {
    local arch="$1"
    local file="$2"
    local sdk_level="$3"
    local sysroot triple
    sysroot="$ANDROID_HOME/ndk/$(ziggy_android_ndk_version)/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    if [ "$(uname -s)" = "Darwin" ]; then
        sysroot="$ANDROID_HOME/ndk/$(ziggy_android_ndk_version)/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
    fi
    if [ ! -d "$sysroot" ]; then
        echo "ERROR: the NDK sysroot is not at $sysroot. Run setup-android.sh." >&2
        return 1
    fi
    case "$arch" in
        x86_64)
            triple="x86_64-linux-android"
            ;;
        arm64)
            triple="aarch64-linux-android"
            ;;
        *)
            echo "ERROR: unknown architecture '$arch' (expected x86_64 or arm64)" >&2
            return 1
            ;;
    esac
    {
        echo "include_dir=$sysroot/usr/include"
        echo "sys_include_dir=$sysroot/usr/include/$triple"
        echo "crt_dir=$sysroot/usr/lib/$triple/$sdk_level"
        echo "msvc_lib_dir="
        echo "kernel32_lib_dir="
        echo "gcc_dir="
    } > "$file"
}

#
# Prints the lock file that a run holds while it uses an Android emulator or device, so two Ziggy runs never install over each other on
# one device. It is Ziggy's own lock, and knows nothing of the locks another project's runs take on the same device.
# Usage: ziggy_android_device_lock_path <adb serial>
#
ziggy_android_device_lock_path() {
    printf '%s\n' "${TMPDIR:-/tmp}/ziggy-android-device-$1.lock"
}

#
# Prints the serial of every emulator and device adb sees that is ready to use, one per line, whichever project started it.
#
ziggy_android_attached_devices() {
    "$ANDROID_HOME/platform-tools/adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'
}
