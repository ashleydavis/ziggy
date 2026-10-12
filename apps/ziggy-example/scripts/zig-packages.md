# zig-packages.sh

Builds the UI first (`bun run bundle:ui`), because the example's core embeds it, then builds, cross-builds or tests the Zig parts of the example with the steps of the example's own `build.zig`, which takes Ziggy as a dependency: the example's core (`core`, with Ziggy's core built into it) and the native apps.

## Usage

`bash apps/ziggy-example/scripts/zig-packages.sh <build|cross|test>`

The example's `compile:zig` script runs `build` and then `cross`, and the repository's `compile:zig` script runs that.

## Arguments

- `build`: builds the example's core library for this machine (`ziggy-example-core`).
- `cross`: builds the example's core library for every other platform's target, with and without the test hooks: MacOS and the iOS device and simulators with their oldest supported OS versions, Windows and Linux on both architectures. Then fetches the pinned WebView2 SDK if it is not there and compiles the Windows native app without linking it (the `ziggy-example-windows-check` step, for the MinGW targets), which catches type errors in the native app on a machine that cannot link a Windows executable. The Android libraries are built, with the NDK, by the Android build and smoke tests, because they need the Android SDK. The Swift and Xcode parts are only built on a Mac.
- `test`: runs the unit tests of the example's core (`zig build test` in the example's folder). The tests of Ziggy itself run from the root of the repository (`bun run test:zig`), which runs these too.
