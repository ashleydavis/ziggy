#!/usr/bin/env bash

# Builds, cross-builds or tests the Zig packages the Ziggy test app is made of. See zig-packages.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The test app's backend embeds the built UI, so the UI is built before anything here.
(cd "$EXAMPLE_DIR" && bun run bundle:ui)

ACTION="${1:-}"
case "$ACTION" in
    build)
        (cd "$EXAMPLE_DIR" && zig build ziggy-test-app-backend)
        ;;
    cross)
        # The test app's backend library for every platform that is not this one, with and without the test hooks. The
        # Apple targets carry the oldest OS version each is meant to run on.
        for target in aarch64-macos.11.0 x86_64-macos.11.0 aarch64-ios.14.0 aarch64-ios.14.0-simulator x86_64-ios.14.0-simulator x86_64-windows-gnu aarch64-windows-gnu x86_64-linux-gnu aarch64-linux-gnu; do
            for hooks in false true; do
                echo "Cross-building the test app core for $target (test hooks: $hooks)"
                (cd "$EXAMPLE_DIR" && zig build ziggy-test-app-backend -Dtarget="$target" -Dtest-hooks="$hooks" -p "backend/zig-out/cross/$target-$hooks")
            done
        done
        # The Windows shell, which needs the WebView2 SDK, fetched once and then reused. It is only compiled here, not linked: the
        # link needs Microsoft's toolchain, which is on a Windows machine, and Zig has no Windows headers for that toolchain, so
        # the check uses the MinGW target, which has them.
        bash "$SCRIPT_DIR/fetch-webview2.sh"
        for target in x86_64-windows-gnu aarch64-windows-gnu; do
            echo "Checking the Windows shell for $target"
            (cd "$EXAMPLE_DIR" && zig build ziggy-test-app-windows-check -Dtarget="$target" -Dcompile-only=true)
        done
        ;;
    test)
        (cd "$EXAMPLE_DIR" && zig build test --summary all --test-timeout 20m)
        ;;
    *)
        echo "Usage: zig-packages.sh <build|cross|test>" >&2
        exit 2
        ;;
esac
