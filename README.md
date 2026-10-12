# Ziggy

Ziggy is a framework for building cross-platform apps with JavaScript/TypeScript, HTML and CSS for the user interface and Zig for everything else. One app runs on Linux, Windows, macOS, Android and iOS, using each platform's system web view.

## Why Ziggy

Electron was great, but it's had it's day. Ziggy aims for small standalone executables, with small bundle sizes and a high performance native code for background tasks.

## What is in this repository

This repository holds:

- **Ziggy**, the package an app is built on, in `packages/ziggy`: the Zig core, the task queue, the native shell for each platform and the TypeScript bridge that gives the page `window.ziggy`.
- **The Ziggy example**, in `apps/ziggy-example`: a small complete app that shows how to use the package, with smoke tests on every platform. A new app starts as a copy of it.

Nothing is published to npm or any other registry. An app uses Ziggy either from a checkout of this repository, by a local path, or from a version tag of this repository, by its git URL.

## What is in the package

- `packages/ziggy/core`: the core library every app links. It has the C interface (`ziggy.h`), the message dispatcher, the task runner, the origin check, the host callback plumbing and the test control connection. It is the same code on every platform and never touches a window. An app's Zig code imports it as `@import("ziggy")`.
- `packages/ziggy/task-queue`: the task queue the core runs tasks through, and the helpers it is written with (logging, errors, IDs, timestamps, the process environment, running tools). An app imports it as `@import("task-queue")`, for code that queues tasks without the app shell.
- `packages/ziggy/bridge`: `inject/ziggy-inject.js`, the script every shell injects to create `window.ziggy` (it is embedded in the core, so an app supplies nothing for it), and its TypeScript types, the `ziggy-bridge` package.
- `packages/ziggy/native/<platform>`: the framework half of each shell, which hosts the system web view, draws the menu, handles shortcuts and developer tools, shows the file and folder dialogs, and moves messages between the page and the core.
  - `linux`: Zig, GTK 3 and WebKitGTK 4.1.
  - `windows`: Zig and WebView2.
  - `macos` and `ios`: Swift and WKWebView, each a Swift package.
  - `android`: Java and the Android WebView, a Gradle build of its own, with the native methods implemented in the core.
- `build.zig`: builds Ziggy and runs its tests, and holds the functions an app's own `build.zig` calls to build its core and its Linux and Windows shells.
- `Package.swift`: the MacOS and iOS shells as one Swift package, for an app that takes Ziggy from a version tag.

## Guides

- [Integrating Ziggy](docs/integrating-ziggy.md): the lines an app adds to use Ziggy, from a local path or from a version tag, and how to move to a newer tag.
- [Building your app](docs/building-your-app.md): starting a new app from the example, the parts of an app, and the commands to set up, build, run and test it on each platform.
- [Distributing your app](docs/distributing-your-app.md): packaging, signing, and getting a build to testers and stores, on each platform.
- [Releasing Ziggy](docs/releasing-ziggy.md): what the release workflow does on each push, and how a version of the package is released.
- [Architecture](docs/architecture.md): how the parts fit, the message protocol, tasks, channels, host callbacks, menus and test hooks.

## Getting started

The tools are pinned in `mise.toml`. Install them with `mise install`, then the dependencies with `bun install`, then the platform toolchains with `bun run setup` (the Android SDK and NDK on Linux and MacOS, a check of Xcode on MacOS, and the WebView2 SDK and WiX Toolset on Windows).

| Command | What it does |
|---|---|
| `bun run test` | The TypeScript unit tests: the bridge and the example's page. |
| `bun run test:zig` | Every Zig test (`zig build test`): Ziggy's core, the task queue, the parts of the Linux and Windows shells that need no platform, and the example's core. It builds the example's page first. |
| `bun run test:android-shell` | The JUnit tests of the Android shell, on this machine's JVM. |
| `bun run compile` | Type-checks the TypeScript. |
| `bun run compile:zig` | Builds the example's core and cross-builds it for every platform, and compiles the Windows shell. |
| `bun run test:ziggy-example` | The example's smoke tests on this machine's desktop platform. |
| `bun run test:ziggy-example:and` | The example's smoke tests on an attached Android emulator or device. |
| `bun run test:ziggy-example:ios` | The example's smoke tests on the iOS simulator (MacOS only). |
| `bun run run:ziggy-example:<platform>` | Builds the example and runs it. |

The example's [README](apps/ziggy-example/README.md) has the rest of its commands.

## Licence

MIT. See [LICENSE](LICENSE).
