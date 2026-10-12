# test-android-shell.sh

Runs the JUnit tests of Ziggy's Android shell (`packages/ziggy/native/android/src/test`) on this machine's JVM, through the example's Gradle project, which includes the shell's Gradle build. No emulator or device is needed. The tests run every time, never skipped as up to date.

Invoked as `bun run --filter=ziggy-example test:android-shell`, or `bun run test:android-shell` from the root of the repository. No arguments.

Needs a JDK 17 and the Android SDK, which [android-common.sh](android-common.md) finds.
