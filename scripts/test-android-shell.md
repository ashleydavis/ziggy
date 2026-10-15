# test-android-shell.sh

Runs the JUnit tests of Ziggy's Android native app (`packages/ziggy/native/android/src/test`) on this machine's JVM, through the test app's Gradle project, which includes the native app's Gradle build. No emulator or device is needed. The tests run every time, never skipped as up to date.

Invoked as `bun run --filter=ziggy-test-app test:android-shell`, or `bun run test:android-shell` from the root of the repository. No arguments.

Needs a JDK 17 and the Android SDK, which `android-common.sh` finds.

## See also

- [android-common.sh](../apps/ziggy-test-app/scripts/android-common.md): how the JDK 17 and the Android SDK are found.
