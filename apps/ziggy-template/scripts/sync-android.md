# sync-android.sh

Builds what the Android app packages and puts it where Gradle expects it, under `native/android/app/build/ziggy`. Gradle never runs `zig`: this script does, and the Gradle build fails with a message naming this script when its output is missing.

Invoke: `bash apps/ziggy-template/scripts/sync-android.sh [options]`

- `--arch "<list>"`: the architectures to build, `x86_64` and `arm64`, space separated, or `all`. The default is both.
- `--optimize <mode>`: the Zig optimize mode, `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`. The default is `ReleaseSafe`.
- `--test-hooks`: compile in the test hooks (the test control connection). Never for a release.
- `--skip-ui`: do not rebuild the frontend. `dist/index.html` must already exist.

What it does:

1. Writes a libc file per architecture from the NDK's sysroot. Zig has no C library for Android, so `zig build --libc <file>` is given the NDK's headers and libraries (the ones for the app's minimum SDK level). The JNI code of Ziggy's core library is translated from the NDK's own `jni.h` with the include directories read from the same file.
2. Builds `libziggy_template.so` per architecture with the `ziggy-template-backend` step of the template's `build.zig` (`zig build ziggy-template-backend -Dtarget=<arch>-linux-android`) and copies it to `jniLibs/<abi>/`. Every library an earlier sync left there is removed first, so an architecture `--arch` does not name, or a library under an app's earlier name, does not reach the APK.
3. Builds the frontend (`bun run bundle:ui`) before the library, because the library embeds it. The library is where the native app finds the frontend, so nothing of the frontend goes into the assets.
