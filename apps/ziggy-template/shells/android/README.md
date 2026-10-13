# Ziggy template, Android native app

The template's Android project: one activity (`MainActivity`) that hosts a web view run by Ziggy's Android native app (`packages/ziggy/native/android`). Package `dev.ziggy.template`. The SDK levels and the NDK are in `variables.gradle`, which the scripts read too. Ziggy's Android native app is a Gradle build of its own, which `settings.gradle` includes, and the app depends on it as `dev.ziggy:ziggy-native-android`.

What is packaged:

- The Zig core library `libziggy_template.so` per architecture (`arm64-v8a` and `x86_64`), with the JNI entry points in Zig.
- The built UI and the script that exposes `window.ziggy`, both embedded in `libziggy_template.so`. The native app answers every request to `https://ziggy-app.invalid/` from the UI, so the APK has no UI files and no assets of its own.

All of it is generated into `app/build/ziggy` by `scripts/sync-android.sh`; see `scripts/*-android.md` for the setup, sync, build, run, open, package and clean scripts.

The debug build has the INTERNET permission (in `app/src/debug`), because a test hooks build opens its control connection on the loopback address and Android refuses an app any socket without it. The release build has no such permission.

Smoke tests: `bash apps/ziggy-template/smoke-tests/run.sh android`, on any attached emulator or device, claimed under Ziggy's per-device lock.

The template's file and folder pickers (`pick-files`, `pick-folder`, `pick-file`) use the system document pickers through Ziggy's Android native app, which describes them: opened files are copied into the app's cache directory and answered as file system paths, while a chosen folder or a save location is answered as a `content://` Uri, which is not a file system path. `MainActivity` forwards `onActivityResult` to the native app.
