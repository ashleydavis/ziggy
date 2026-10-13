# Building your app

A new app starts as a copy of the Ziggy template (`apps/ziggy-template`), which is a complete app with a UI, a Zig core, a native project for each platform, smoke tests and scripts to build, run and package it. The copy is the app's own code from then on. Ziggy itself is never copied: the app takes it as a dependency (see [Integrating Ziggy](integrating-ziggy.md)).

## Starting a new app from the template

The `/ziggy:new` Claude Code command does these steps for you, asking for the app's names as it goes (see [Claude Code commands](claude-code-commands.md)). By hand:

1. Copy the contents of `apps/ziggy-template` into the new app's folder, leaving out what builds write: `node_modules`, `dist`, `out`, `.zig-cache`, `zig-out`, `webview2-sdk`, `wix` and every `build` folder. The template's `.gitignore` comes with it and lists them.
2. Add a `mise.toml` pinning the same Zig, Bun, Node and jq versions as Ziggy's `mise.toml`, and run `mise install`.
3. Point every part at Ziggy (the paths below are for a local checkout of Ziggy beside the app; [Integrating Ziggy](integrating-ziggy.md) has the lines for a version tag):
   - `build.zig.zon`: the `ziggy` dependency's `.path` (`"../ziggy"`). Delete the `.fingerprint` line; `zig build` then prints a new one, which goes back in.
   - `shells/android/settings.gradle`: the path in `includeBuild` (`'../../../ziggy/packages/ziggy/native/android'`).
   - `shells/macos/ZiggyTemplate.xcodeproj/project.pbxproj` and `shells/ios/ZiggyTemplate.xcodeproj/project.pbxproj`: the `path` of the `macos` or `ios` package reference (`"../../../ziggy/packages/ziggy/native/macos"`).
   - `package.json`: `"ziggy-ui": "file:../ziggy/packages/ziggy/ui"` in place of `workspace:*`.
4. Rename the app. Every one of these names the template, and each must name the new app instead (the test app built from the template used `ziggy-test-app`, `ziggy_test_app`, `dev.ziggy.testapp`, `ZiggyTestApp` and "Ziggy test app"):
   - `ziggy-template`, the app's name: `package.json`'s `name`, the `name` given to `addAppCore` and `IShellApp` in `build.zig` (which names the steps `<name>-core`, `<name>-linux`, `<name>-windows`, `<name>-dev` and `<name>-dev-host`, and the executables) and every script, smoke test and doc that runs those steps or names the executables and packages.
   - `ziggy_template`, the name of the core library (`libziggy_template.a`, `libziggy_template.so`): the Xcode projects link it, `shells/android` loads it and the sync and package scripts copy it. `addAppCore` makes it from the app's name, with each `-` as `_`.
   - `ziggy-template-core`, the name the core's unit tests import the core under: `build.zig` and `core/src/test`.
   - `dev.ziggy.template`, the app's identifier: the Linux and Windows native apps' `app_id`, the Android `namespace` and `applicationId` in `shells/android/app/build.gradle`, the Java package of `MainActivity` (and its folder, `app/src/main/java/dev/ziggy/example`), the scripts and smoke tests that start or install the app by it and the bundle identifier in both Xcode projects.
   - `ZiggyTemplate`, the Xcode projects' name: the `.xcodeproj` folders, the source folders beside them, the schemes in `xcshareddata/xcschemes`, the product names and the Apple scripts that open or build them.
   - "Ziggy template", the name a user sees: window titles, the menu, `Info.plist`, `AndroidManifest.xml`, the Windows installer and the docs.
   - The Windows installer's GUIDs in `scripts/package-windows.wxs` (the `UpgradeCode` and each `Component`'s `Guid`): make new ones with `uuidgen`, or Windows treats the new app as an upgrade of the template.
   - The Firebase project in `scripts/distribute-android.sh`, when the app is distributed to testers (see [Distributing your app](distributing-your-app.md)).
5. Run `bun install`, then the unit and smoke tests (below). They pass unchanged in a copy that is renamed and pointed at Ziggy: the test app built from the template passed every one on Linux and Android.

Then change what the app does: its UI, its core's channel and task handlers, its menu, its icon and its native projects.

## The parts of an app

- **The UI** (`ui/`): the user interface, in TypeScript and HTML, built by Vite (`vite.config.ts`) into `dist`. It talks to the core through `window.ziggy`, whose types are in `ziggy-ui`. `ui/src/lib` holds plain functions with unit tests.
- **The core** (`core/`): the app's Zig library. `core/src/index.zig` gives Ziggy the app's handlers: the channels the UI sends requests on, the task types it queues, the menu, the UI's query and the keep-alive task types. `core/src/lib` holds them. The core embeds the built UI, so `dist` must be built before the core.
- **The handlers**: a channel handler answers a request from the UI on the thread that handles the UI's messages, so it must be quick. Anything slow is a task, which runs on the core's pool of threads, reports progress with task messages and can be cancelled. See the [architecture guide](architecture.md#channels) for both.
- **The native apps** (`shells/<platform>/`): the app's native project for each platform, built on the part Ziggy provides for that platform: its name, window, icon, permissions and anything only the operating system can do. The Linux and Windows native apps are Zig, built by `build.zig`. The MacOS and iOS native apps are Xcode projects, the Android native app a Gradle project, each built by the app's scripts after the core library is built for that platform.
- **The scripts** (`scripts/`): set up, sync, build, run, open, package, distribute and clean, for each platform, each with a markdown file beside it, and the shell libraries they share in `scripts/lib`.
- **The smoke tests** (`smoke-tests/`): scenarios that start the real app, built with the test hooks, and drive it through the test control connection, with a library for each platform.

## Commands

The `/ziggy:check` Claude Code command runs every check below that the machine can run and fixes what fails (see [Claude Code commands](claude-code-commands.md)).

Run from the app's folder. `<platform>` is `linux`, `windows`, `macos`, `android` or `ios`, and each platform's commands run on that platform: Linux on Linux, Windows under Git Bash on Windows, MacOS and iOS on a Mac with Xcode 14.2 or newer, Android on Linux or a Mac.

| Command | What it does |
|---|---|
| `bun run setup` | One time per machine: the Android SDK, NDK and a JDK 17 on Linux and MacOS, the WebView2 SDK and WiX Toolset on Windows and a check of Xcode on MacOS. |
| `bun run dev` | Runs the app in dev mode: the app's dev server (the `dev:ui` script) serves the UI, the dev host runs the core in front of it, rebuilt as its Zig files change, and the default browser opens the dev host, with live reload (see [Dev mode](#dev-mode)). |
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
| `bun run test:smoke:dev` | The smoke tests in dev mode, in a headless Chrome or Chromium. |

What each platform needs installed is in the template's [README](../apps/ziggy-template/README.md#what-each-platform-needs).

## Dev mode

Dev mode is the quickest way to work on an app. `bun run dev` starts the app's own dev server (its `dev:ui` script, Vite in the template), builds the dev host, which runs the app's core in front of the dev server, and opens the UI in the default browser once both are up, saying what it is doing while it builds. The bundler's config has nothing of Ziggy's in it, so any bundler works the same way (see [Integrating Ziggy](integrating-ziggy.md#dev-mode-packagejson)). From then on:

- Saving a file under `ui/` reaches the page through the dev server's own live reload. Nothing of Ziggy's is rebuilt.
- Saving a Zig file of the app or of Ziggy rebuilds the dev host and restarts it, and the page reloads once it is back. The core starts again, so tasks that were running are gone.
- A Zig build that fails is reported in the terminal, and the dev host that was running keeps running until the next save.

The UI is the same code as in the native app and talks to the core through the same `window.ziggy`. What only the native app can do (menus, screenshots and the app's own host requests) answers with the error `HostCallbackMissing`. File and folder dialogs work on Linux, where the dev host shows them with zenity, and answer `HostCallbackMissing` on Windows and macOS. A dropped file's path is the path of a copy the dev host saves, because a browser gives a page no file's path. The page renders in the browser's engine, so check the native app on each platform as well. The [dev host's README](../packages/ziggy/dev/README.md) has the details.

Dev mode is for development only: no native app and no release build includes it.
