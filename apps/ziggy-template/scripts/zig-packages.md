# zig-packages.sh

Builds the UI first (`bun run bundle:ui`), because the template's backend embeds it, then builds, cross-builds or tests the Zig parts of the template with the steps of the template's own `build.zig`, which takes Ziggy as a dependency: the template's backend (`backend`, with Ziggy's core library built into it) and the native apps.

## Usage

`bash apps/ziggy-template/scripts/zig-packages.sh <build|cross|test>`

The template's `compile:zig` script runs `build` and then `cross`, and the repository's `compile:zig` script runs that.

## Arguments

- `build`: builds the template's backend library for this machine (`ziggy-template-backend`).
- `cross`: builds the template's backend library for every other platform's target, with and without the test hooks: MacOS and the iOS device and simulators with their oldest supported OS versions, Windows and Linux on both architectures. Then fetches the pinned WebView2 SDK if it is not there and compiles the Windows native app without linking it (the `ziggy-template-windows-check` step, for the MinGW targets), which catches type errors in the native app on a machine that cannot link a Windows executable. The Android libraries are built, with the NDK, by the Android build and smoke tests, because they need the Android SDK. The Swift and Xcode parts are only built on a Mac.
- `test`: runs the unit tests of the template's backend (`zig build test` in the template's folder). The tests of Ziggy itself run from the root of the repository (`bun run test:zig`), which runs these too.
