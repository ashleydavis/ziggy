# Building your app

A new app starts as a copy of the Ziggy example (`apps/ziggy-example`), which is a complete app with a UI, a Zig core, a native project for each platform, smoke tests and scripts to build, run and package it. The copy is the app's own code from then on. Ziggy itself is never copied: the app takes it as a dependency (see [Integrating Ziggy](integrating-ziggy.md)).

## Starting a new app from the example

1. Copy the contents of `apps/ziggy-example` into the new app's folder, leaving out what builds write: `node_modules`, `dist`, `out`, `.zig-cache`, `zig-out`, `webview2-sdk`, `wix` and every `build` folder. The example's `.gitignore` comes with it and lists them.
2. Add a `mise.toml` pinning the same Zig, Bun, Node and jq versions as Ziggy's `mise.toml`, and run `mise install`.
3. Point every part at Ziggy (the paths below are for a local checkout of Ziggy beside the app; [Integrating Ziggy](integrating-ziggy.md) has the lines for a version tag):
   - `build.zig.zon`: the `ziggy` dependency's `.path` (`"../ziggy"`). Delete the `.fingerprint` line; `zig build` then prints a new one, which goes back in.
   - `shells/android/settings.gradle`: the path in `includeBuild` (`'../../../ziggy/packages/ziggy/native/android'`).
   - `shells/macos/ZiggyExample.xcodeproj/project.pbxproj` and `shells/ios/ZiggyExample.xcodeproj/project.pbxproj`: the `path` of the `macos` or `ios` package reference (`"../../../ziggy/packages/ziggy/native/macos"`).
   - `package.json`: `"ziggy-bridge": "file:../ziggy/packages/ziggy/bridge"` in place of `workspace:*`.
4. Rename the app. Every one of these names the example, and each must name the new app instead (the test app built from the example used `ziggy-test-app`, `ziggy_test_app`, `dev.ziggy.testapp`, `ZiggyTestApp` and "Ziggy test app"):
   - `ziggy-example`, the app's name: `package.json`'s `name`, the `name` given to `addAppCore` and `IShellApp` in `build.zig` (which names the steps `<name>-core`, `<name>-linux` and `<name>-windows`, and the executables) and every script, smoke test and doc that runs those steps or names the executables and packages.
   - `ziggy_example`, the name of the core library (`libziggy_example.a`, `libziggy_example.so`): the Xcode projects link it, `shells/android` loads it and the sync and package scripts copy it. `addAppCore` makes it from the app's name, with each `-` as `_`.
   - `ziggy-example-core`, the name the core's unit tests import the core under: `build.zig` and `core/src/test`.
   - `dev.ziggy.example`, the app's identifier: the Linux and Windows native apps' `app_id`, the Android `namespace` and `applicationId` in `shells/android/app/build.gradle`, the Java package of `MainActivity` (and its folder, `app/src/main/java/dev/ziggy/example`), the scripts and smoke tests that start or install the app by it and the bundle identifier in both Xcode projects.
   - `ZiggyExample`, the Xcode projects' name: the `.xcodeproj` folders, the source folders beside them, the schemes in `xcshareddata/xcschemes`, the product names and the Apple scripts that open or build them.
   - "Ziggy example", the name a user sees: window titles, the menu, `Info.plist`, `AndroidManifest.xml`, the Windows installer and the docs.
   - The Windows installer's GUIDs in `scripts/package-windows.wxs` (the `UpgradeCode` and each `Component`'s `Guid`): make new ones with `uuidgen`, or Windows treats the new app as an upgrade of the example.
   - The Firebase project in `scripts/distribute-android.sh`, when the app is distributed to testers (see [Distributing your app](distributing-your-app.md)).
5. Run `bun install`, then the unit and smoke tests (below). They pass unchanged in a copy that is renamed and pointed at Ziggy: the test app built from the example passed every one on Linux and Android.

Then change what the app does: its UI, its core's channel and task handlers, its menu, its icon and its native projects.

## The parts of an app

- **The UI** (`ui/`): the user interface, in TypeScript and HTML, built by Vite (`vite.config.ts`) into `dist`. It talks to the core through `window.ziggy`, whose types are in `ziggy-bridge`. `ui/src/lib` holds plain functions with unit tests.
- **The core** (`core/`): the app's Zig library. `core/src/index.zig` gives Ziggy the app's handlers: the channels the UI sends requests on, the task types it queues, the menu, the UI's query and the keep-alive task types. `core/src/lib` holds them. The core embeds the built UI, so `dist` must be built before the core.
- **The handlers**: a channel handler answers a request from the UI on the thread that handles the UI's messages, so it must be quick. Anything slow is a task, which runs on the core's pool of threads, reports progress with task messages and can be cancelled. See the [architecture guide](architecture.md#channels) for both.
- **The native apps** (`shells/<platform>/`): the app's native project for each platform, built on the part Ziggy provides for that platform: its name, window, icon, permissions and anything only the operating system can do. The Linux and Windows native apps are Zig, built by `build.zig`. The MacOS and iOS native apps are Xcode projects, the Android native app a Gradle project, each built by the app's scripts after the core library is built for that platform.
- **The scripts** (`scripts/`): set up, sync, build, run, open, package, distribute and clean, for each platform, each with a markdown file beside it, and the shell libraries they share in `scripts/lib`.
- **The smoke tests** (`smoke-tests/`): scenarios that start the real app, built with the test hooks, and drive it through the test control connection, with a library for each platform.

## Commands

Run from the app's folder. `<platform>` is `linux`, `windows`, `macos`, `android` or `ios`, and each platform's commands run on that platform: Linux on Linux, Windows under Git Bash on Windows, MacOS and iOS on a Mac with Xcode 14.2 or newer, Android on Linux or a Mac.

| Command | What it does |
|---|---|
| `bun run setup` | One time per machine: the Android SDK, NDK and a JDK 17 on Linux and MacOS, the WebView2 SDK and WiX Toolset on Windows and a check of Xcode on MacOS. |
| `bun run build:<platform>` | Builds the UI and the app. |
| `bun run run:<platform>` | Builds the app and runs it (on an attached emulator or device for Android, on a simulator for iOS). |
| `bun run open:<platform>` | Syncs, then opens the native project in its editor (Xcode, Android Studio). |
| `bun run package:<platform>` | Packages the app for release (see [Distributing your app](distributing-your-app.md)). |
| `bun run clean:<platform>` | Removes the platform's build output. |
| `bun run compile` | Type-checks the UI. |
| `bun run test` | The UI's unit tests. |
| `bun run test:zig` | The core's unit tests (`zig build test`). |
| `bun run test:zig:android` | The core's unit tests on an attached Android emulator or device. |
| `bun run test:zig:ios` | The core's unit tests on a booted iOS simulator. |
| `bun run test:smoke` | The smoke tests on this machine's desktop platform. |
| `bun run test:smoke:and` | The smoke tests on an attached Android emulator or device (the ones `ZIGGY_ANDROID_DEVICES` names, when it is set). |
| `bun run test:smoke:ios` | The smoke tests on the iOS simulator. |

What each platform needs installed is in the example's [README](../apps/ziggy-example/README.md#what-each-platform-needs).
