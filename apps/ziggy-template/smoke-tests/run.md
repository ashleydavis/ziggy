# run.sh

Runs the app's smoke tests for one platform: each folder here that holds a `test.sh` starts the real app and checks what it shows. Invoked by the `package.json` scripts `test:smoke`, `test:smoke:and` and `test:smoke:ios`, never directly. Terms are defined in [Ziggy's glossary](https://github.com/ashleydavis/ziggy/blob/main/docs/glossary.md).

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios` (a connected iPhone or iPad when there is one, see `lib/ios-device.sh`, otherwise a simulator). Each has a library in `lib/<platform>.sh` that builds the app, starts it and stops it.
- `[scenario]`: optional folder name, to run one smoke test.

## Behaviour

Builds the app for the platform with the test hooks, then runs each `test.sh`, one after another, giving each its own temporary directory and a timeout. A smoke test drives the running app through the test control connection, with the helpers in `lib/common.sh`: `start_test_app`, `click`, `text_of` and `wait_for_text` find the page's elements by their `data-id`.

## Smoke tests

- `hello-world-app`: hello world example. The backend's answer to the hello-world message appears, and the hello-world task's output appears once its button is pressed. Change it into your own smoke test, or delete it.

To add one, make a folder here with a `test.sh` that sources `../lib/common.sh`.

## Building on Android

The Android library builds the test APK and the release APK one after the other through the one Gradle project and synced library directory of the checkout. Two runs building at the same time would swap the library under each other, so `ziggy_platform_prepare` in `lib/android.sh` holds a lock file inside that build directory for the whole build. A second run waits for the first to finish building, then builds its own.
