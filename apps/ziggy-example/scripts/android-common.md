# android-common.sh

Shared by the `*-android.sh` scripts and by the smoke test platform library (`smoke-tests/lib/android.sh`). It is sourced, never run and has no arguments.

It resolves a JDK 17 and the Android SDK by sourcing [lib/android-env.sh](lib/android-env.md) (which exits with a message when either is missing), and defines:

- `ziggy_android_require_commands <command...>`: fails unless each command is on the PATH.
- `ziggy_android_ndk_version`: the NDK version the app's Android project pins in `shells/android/variables.gradle`, so the Zig library is linked against the NDK Gradle builds with.
- `ziggy_android_min_sdk`: the minimum SDK level, from the same `variables.gradle`.
- `ziggy_android_gradle <arguments...>`: runs the app's Android project's Gradle wrapper.
- `ziggy_android_version`: the version in the app's `package.json`.
- `ziggy_android_abi <x86_64|arm64>`: the Android ABI directory name.
- `ziggy_android_write_libc_file <x86_64|arm64> <file> <sdk level>`: writes the libc file Zig is given for an Android target, from the NDK's sysroot.
- `ziggy_android_device_lock_path <serial>`: the lock file a run holds while it uses an emulator or device, Ziggy's own, so two runs never install over each other on one device.
- `ziggy_android_attached_devices`: every emulator and device adb sees that is ready, whichever project started it.
