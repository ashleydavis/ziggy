# Ziggy example

A small complete app built on Ziggy, kept as the reference for building an app on it and as the template a new app is copied from. It has a page (TypeScript and HTML), a Zig core with its own channel handlers and task handlers, a native shell for each platform and smoke tests. It takes Ziggy as a dependency exactly as an app in another repository does, and nothing in Ziggy knows about it. See [Ziggy architecture](../../docs/architecture.md) for how the parts fit, and [Building your app](../../docs/building-your-app.md) for starting a new app from it.

## What it shows

- The page asks the Zig core a question (`ping`) and shows the answer.
- Tasks: a short task, a long task that queues child tasks and waits for them, several long tasks at once, cancelling by source, and a task that fails. Output text, `job-progress` messages and every `task-message` and `task-completed` event appear in the page.
- The edges of the bridge: a multi-megabyte payload, text with quotes, newlines and non-ASCII characters, an error reply, and a file written and read in the app's private data directory.
- A native host callback: the page asks for the operating system's version, a task calls the shell's callback and the answer comes back to the page.
- File and folder pickers: three buttons ask the core for the native dialogs (`pick-files`, `pick-folder`, `pick-file`), and the page shows the paths chosen. A phone has no save dialog, so that button gives an error on iOS.
- A loopback HTTP server in the core (the example's own code, not Ziggy's) that serves an example image and video to the page, which loads them and asks for a range of bytes.
- Keep-alive tasks: a background task type registered as keep-alive that goes on running when the app is sent to the background (a phone), and a normal one that does not.
- Page storage: `localStorage` and IndexedDB values the page writes and reads back after the app is started again.
- Dropped files: a drop zone that shows the real path of a dropped file, from `window.ziggy.getPathForFile`.
- A desktop menu defined once in Zig and drawn natively, with keyboard shortcuts that work anywhere in the window, and developer tools (Ctrl+Shift+I, or Cmd+Shift+I on a Mac) that open from it. A phone shows no menu.

## Where things are

Everything here is the example's own. Ziggy, the package it is built on, is in `packages/ziggy` at the root of this repository.

- `build.zig` and `build.zig.zon`: the example's Zig build. It takes Ziggy as the dependency `ziggy` by the path `../..`, and builds the core (`ziggy-example-core`), the Linux and Windows shells (`ziggy-example-linux`, `ziggy-example-windows`) and the core's unit tests (`test`) with Ziggy's build functions.
- `page/`: the page. `page/index.html` is the page and `page/src/lib` holds the plain functions that have unit tests. `vite.config.ts` is its build, which writes `dist` with relative paths and a classic script so it loads from an address of the app's own in every web view. `dist` is embedded in the app's own code on every platform (the Linux and Windows executables, and the core library that the MacOS, iOS and Android apps contain), so no platform has a folder of page files (see the [architecture guide](../../docs/architecture.md#the-bundled-page)).
- `core/`: the example's Zig library, which adds its channel handlers and task handlers to Ziggy's core.
- `shells/<platform>/`: the example's native project for each platform: its name, window, icon and the app's core and page packaged together. Each one builds on Ziggy's framework half for that platform in `packages/ziggy/native/<platform>`: the Linux and Windows shells through the Zig build, the Xcode projects through a local Swift package, and the Android project through an included Gradle build.
- `scripts`: the build, run, packaging and setup scripts, and the shell libraries the scripts and smoke tests share (`scripts/lib`), each with a markdown file beside it.
- `smoke-tests`: the smoke test scenarios and a library for each platform. See `smoke-tests/run.md`.

## Commands

From the root of this repository, `<platform>` being `linux`, `windows`, `macos`, `android` or `ios`. Each platform's commands run on that platform (MacOS and iOS need a Mac with Xcode 14.2, and Windows runs them under Git Bash). The same commands without the `ziggy-example` part (`bun run build:<platform>`, `bun run test:smoke`) run from this folder.

| Command | What it does |
|---|---|
| `bun run build:ziggy-example:<platform>` | Builds the page and the app. |
| `bun run run:ziggy-example:<platform>` | Builds the app and launches it (an emulator, simulator or device for a phone). |
| `bun run open:ziggy-example:<platform>` | Syncs, then opens the native project in its editor. |
| `bun run package:ziggy-example:<platform>` | Packages the app for distribution, without the test hooks, into `out/<platform>`. |
| `bun run distribute:ziggy-example:android` | Builds the Android app and uploads it to Firebase App Distribution for the tester group. See `scripts/distribute-android.md`. |
| `bun run clean:ziggy-example:<platform>` | Removes the platform's build output. |
| `bun run test:ziggy-example` | The smoke tests on the host operating system. |
| `bun run test:ziggy-example:and` | The smoke tests on an attached Android emulator or device. |
| `bun run test:ziggy-example:ios` | The smoke tests on the iOS simulator. |

`bun run --filter=ziggy-example test` runs the page's unit tests, `bun run --filter=ziggy-example test:zig` the core's, and `bun run --filter=ziggy-example test:zig:android` (or `:ios`) the core's on an emulator or simulator.

`bun run package:ziggy-example:<platform>` builds the release app, without the test hooks, and writes unsigned packages. Each platform's script doc says where they go and what they need:

| Platform | Packages | Script doc |
|---|---|---|
| `linux` | zip, `.deb` | `scripts/package-linux.md` |
| `windows` | zip, `.msi` installer | `scripts/package-windows.md` |
| `macos` | `.dmg`, zip | `scripts/package-macos.md` |
| `ios` | `.xcarchive`, `.ipa` | `scripts/package-ios.md` |
| `android` | `.apk` per architecture | `scripts/package-android.md` |

## What each platform needs

- **Linux:** the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0`, `libwebkit2gtk-4.1-0`) and the GStreamer plugins WebKitGTK plays video with (`gstreamer1.0-plugins-good`, `gstreamer1.0-libav`) to build and run, with no development packages, `xvfb`, `xwininfo` and `jq` for the smoke tests, and `zip` and `dpkg-deb` to package. If the web view's sandbox cannot start on your system the app says so and runs without it. See `scripts/run-linux.md`.
- **Windows:** the scripts are bash scripts and run under Git Bash. The tools `mise install` puts in place (`bun`, `zig`, `jq`) must be on PATH: add `%LOCALAPPDATA%\mise\shims` to PATH, or activate mise in your shell. Then run `bun run --filter=ziggy-example setup` once. Building needs Microsoft's C++ toolchain and the Windows SDK (Visual Studio or its Build Tools, the "Desktop development with C++" workload), because the WebView2 loader is linked into the exe from the SDK's static library and that library is built with it, and packaging needs the WiX Toolset. Setup downloads the pinned WebView2 SDK and a pinned WiX Toolset, which need no administrator approval, and installs the C++ toolchain and the Windows SDK through `winget` when they are missing, which does. See `scripts/setup-windows.md`.
- **MacOS and iOS:** a Mac with macOS 12.7.6 or newer and Xcode 14.2 or newer.
- **Android:** `bun run --filter=ziggy-example setup`, which installs the Android SDK, the NDK `shells/android/variables.gradle` pins and a JDK 17 where they are missing (`scripts/install-android-sdk.md`). The smoke tests use any attached emulator or device.

## Test hooks

The smoke tests drive the real app through the test hooks listed in "Test hooks" in the architecture guide. They are compiled in only by the `test-hooks` build option, which the smoke test runner sets and the `package` commands never do. Scenario `8-release-has-no-hooks` checks the release build has none.

## CI

The repository's release workflow (`.github/workflows/release.yml`) builds, tests and packages the example on Linux, Windows, MacOS, iOS and Android on every push, and publishes the packages when every job passed on the default branch. See [Releasing Ziggy](../../docs/releasing-ziggy.md).
