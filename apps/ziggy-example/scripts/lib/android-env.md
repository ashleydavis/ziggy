# android-env.sh

Puts the Android toolchain into the environment: a JDK 17 as `JAVA_HOME` (and on the `PATH`), and the Android SDK as `ANDROID_HOME` and `ANDROID_SDK_ROOT`. The example's Android scripts source it through `scripts/android-common.sh`.

Sourced, never run: `source "<app>/scripts/lib/android-env.sh"`. It exits with a message saying what to install when either piece is missing.

- The JDK: an existing `JAVA_HOME` when it is a JDK 17, else `ZIGGY_JDK17_HOME`, else the usual install locations on Linux and macOS. A JDK 17 specifically, because the Android Gradle plugin fails on JDK 21.
- The SDK: `ANDROID_HOME`, else `ANDROID_SDK_ROOT`, else `$HOME/Android/Sdk` (Linux) or `$HOME/Library/Android/sdk` (macOS).

[install-android-sdk.sh](../install-android-sdk.md) installs both.
