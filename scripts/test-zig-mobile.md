# test-zig-mobile.sh

Runs the unit tests of the test app's backend (`backend`) on a mobile platform, and of Ziggy's core library too when `--ziggy-dir` names a checkout of Ziggy. Each test program is built for the platform with a `test-binary-*` step (`test-binary-ziggy-test-app-backend` of the test app's `build.zig`, `test-binary-ziggy-core` of Ziggy's), which installs it under `test-bin` of the prefix without running it, and is then run on the emulator or simulator, because this machine cannot run it. The script exits non-zero when any program fails.

## Usage

From the root of the Ziggy repository, `bun run test:zig:android` and `bun run test:zig:ios` run `bash scripts/test-zig-mobile.sh <android|ios> --ziggy-dir .`, which runs Ziggy's core library's tests as well as the test app's.

## Arguments

- `android`: claims a device the way Ziggy's Android smoke tests do (the devices named in `ZIGGY_ANDROID_DEVICES`, else any attached emulator or device), builds the programs for that device's architecture against the NDK's libc, pushes each to `/data/local/tmp` and runs it there. The NDK comes from `ANDROID_HOME`, the version `native/android/variables.gradle` pins. A run on a CI emulator names it with `ZIGGY_ANDROID_DEVICES=emulator-5554`.
- `ios`: builds the programs for the iOS simulator (`aarch64-ios.14.0-simulator`) and runs each with `xcrun simctl spawn` on the booted simulator. A simulator must already be booted, and the script fails when none is. It needs a Mac.
- `--ziggy-dir <dir>`: a checkout of Ziggy, whose core library's tests run as well.

Both start by building the UI (`bun run bundle:ui`), because the test app's backend embeds it.
