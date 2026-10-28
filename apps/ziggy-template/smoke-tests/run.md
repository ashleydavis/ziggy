# run.sh

Runs the app's smoke tests for one platform: each directory here that holds a `test.sh` starts the real app and checks what it shows. Invoked by the `package.json` scripts `test:smoke`, `test:smoke:android` and `test:smoke:ios`, never directly. Terms are defined in [Ziggy's glossary](https://github.com/ashleydavis/ziggy/blob/main/docs/glossary.md).

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios` (a connected iPhone or iPad when there is one, see `lib/ios-device.sh`, otherwise a simulator). Each has a library in `lib/<platform>.sh` that puts the app in place, starts it and stops it.
- `[scenario]`: optional directory name, to run one smoke test.

## Behaviour

Puts the built app in place once for the platform, then runs each `test.sh`, one after another, giving each its own temporary directory and a timeout. `ZIGGY_SMOKE_BUILD` names a directory the platform's build script already built the app into, as CI's `app-build` job does: `bin/ziggy-template` (Linux, `--prefix`), `bin/ziggy-template.exe` (Windows, `--prefix`), `xcode/Build/Products/Release/ZiggyTemplate.app` (macOS, `--build-dir <dir>/xcode`), `xcode/Build/Products/Release-iphonesimulator/ZiggyTemplate.app` (iOS simulator) or `ziggy-template.apk` (Android, `--output-dir`). When it is not set, the build script builds into the run directory. A connected iPhone or iPad always gets a device build of its own.

`start_test_app` starts the [remote control server](https://github.com/ashleydavis/ziggy/blob/main/tools/remote-control-server/README.md) on ports the system chooses, reads the ports from the line it prints when it listens and starts the app with `--remote-control` and the server's app port (the `ziggy.remoteControl` extra on Android). The app connects out to the server. The smoke test talks to the server's script port. On Android, `adb reverse` carries the app port from the device to the host. A smoke test drives the running app with the helpers in `lib/common.sh`: `start_test_app`, `click`, `text_of` and `wait_for_text` find the page's elements by their `data-id`.

## Smoke tests

- `hello-world-app`: hello world example. Pressing each button logs the backend's message response to the hello-world message, and the hello-world task's output and how it ended. Change it into your own smoke test, or delete it.
- `desktop-only/hello-menu`: hello world example, run only on Linux, Windows and macOS because a phone has no menu. Choosing Say Hello From Zig and Say Hello From the UI each writes its line to the log. Change it into your own smoke test, or delete it.

To add one, make a directory here with a `test.sh` that sources `../lib/common.sh`.

## Building on Android

The Android library builds the APKs with the package script through the one Gradle project and synced library directory of the checkout. Two runs building at the same time would swap the library under each other, so `ziggy_platform_prepare` in `lib/android.sh` holds a lock file inside that build directory for the whole build. A second run waits for the first to finish building, then builds its own.
