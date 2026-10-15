# Ziggy test app, Android native app

The test app's Android project: one activity (`MainActivity`) that hosts a web view run by Ziggy's Android native app (`packages/ziggy/native/android`). Package `dev.ziggy.testapp`. The SDK levels and the NDK are in `variables.gradle`, which the scripts read too. Ziggy's Android native app is a Gradle build of its own, which `settings.gradle` includes, and the app depends on it as `dev.ziggy:ziggy-native-android`.

What is packaged:

- The Zig core library `libziggy_test_app.so` per architecture (`arm64-v8a` and `x86_64`), with the JNI entry points in Zig.
- The built UI and the script that exposes `window.ziggy`, both embedded in `libziggy_test_app.so`. The native app serves every request to `ziggy-app://app/` from the UI, so the APK has no UI files and no assets of its own.

All of it is generated into `app/build/ziggy` by `scripts/sync-android.sh`; see `scripts/*-android.md` for the setup, sync, build, run, open, package and clean scripts.

The debug build has the INTERNET permission (in `app/src/debug`), because a test hooks build opens its control connection on the loopback address and Android refuses an app any socket without it. The release build has no such permission.

Ziggy's smoke tests run the test app on Android with `bun run test:smoke:and` from the root of Ziggy's repository, on any attached emulator or device, claimed under Ziggy's per-device lock.

The test app's file and directory pickers (`pick-files`, `pick-folder`, `pick-file`) use the system document pickers through Ziggy's Android native app, which describes them: opened files are copied into the app's cache directory and returned as file system paths, while a chosen directory or a save location is returned as a `content://` Uri, which is not a file system path. `MainActivity` forwards `onActivityResult` to the native app.
